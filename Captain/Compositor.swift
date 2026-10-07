import AVFoundation
import CoreImage
import Metal
import QuartzCore

/// Renders the program output at a fixed frame rate: the active camera, or a dissolve
/// between two cameras while a crossfade is running. Frames go to the virtual camera
/// and to the in-app program monitor.
final class Compositor {
    let programLayer = AVSampleBufferDisplayLayer()
    let output = VirtualCameraOutput()

    private let queue = DispatchQueue(label: "captain.compositor", qos: .userInteractive)
    private let context: CIContext
    private let outputSize = CGSize(width: Int(CaptainShared.width), height: Int(CaptainShared.height))
    private let colorSpace = CGColorSpace(name: CGColorSpace.itur_709)!
    private var pool: CVPixelBufferPool?
    private var timer: DispatchSourceTimer?
    private var lastOutput: CVPixelBuffer?

    private let lock = NSLock()
    private var feeds: [String: CameraFeed] = [:]
    private var currentID: String?
    private var previousID: String?
    private var transitionStart: CFTimeInterval = 0
    private var transitionDuration: CFTimeInterval = 0

    init() {
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false, .name: "Captain"])
        } else {
            context = CIContext()
        }
        programLayer.videoGravity = .resizeAspect

        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: Int(CaptainShared.width),
            kCVPixelBufferHeightKey: Int(CaptainShared.height),
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, [kCVPixelBufferPoolMinimumBufferCountKey: 6] as CFDictionary, attributes as CFDictionary, &pool)
    }

    func start() {
        output.start()
        queue.async { [weak self] in
            guard let self else { return }
            guard self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 1.0 / Double(CaptainShared.frameRate), leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in self?.renderFrame() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
        output.stop()
    }

    func setFeeds(_ feeds: [String: CameraFeed]) {
        lock.withLock { self.feeds = feeds }
    }

    func cut(to id: String) {
        lock.withLock {
            currentID = id
            previousID = nil
        }
    }

    func crossfade(to id: String, duration: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard id != currentID else { return }
        guard currentID != nil else {
            currentID = id
            return
        }
        let now = CACurrentMediaTime()
        let progress = transitionProgress(at: now)

        if let progress, previousID == id {
            // Reversing mid-fade: continue smoothly from where we are.
            previousID = currentID
            currentID = id
            transitionDuration = duration
            transitionStart = now - (1 - progress) * duration
            return
        }
        // If the outgoing camera is still mostly on screen, fade from it instead.
        if progress == nil || progress! >= 0.5 {
            previousID = currentID
        }
        currentID = id
        transitionStart = now
        transitionDuration = max(duration, 0.01)
    }

    /// Must be called with `lock` held.
    private func transitionProgress(at now: CFTimeInterval) -> Double? {
        guard previousID != nil, transitionDuration > 0 else { return nil }
        let progress = (now - transitionStart) / transitionDuration
        return progress < 1 ? max(0, progress) : nil
    }

    private func renderFrame() {
        lock.lock()
        let now = CACurrentMediaTime()
        let currentFeed = currentID.flatMap { feeds[$0] }
        var previousFeed: CameraFeed?
        var progress = 1.0
        if let p = transitionProgress(at: now), let previousID {
            previousFeed = feeds[previousID]
            progress = p
        } else {
            previousID = nil
        }
        lock.unlock()

        guard let currentBuffer = currentFeed?.latestPixelBuffer else {
            // Camera warming up: hold the last frame so the virtual camera doesn't drop out.
            if let lastOutput { deliver(lastOutput) }
            return
        }

        var image = aspectFill(CIImage(cvPixelBuffer: currentBuffer))
        if let previousBuffer = previousFeed?.latestPixelBuffer, progress < 1 {
            let eased = progress * progress * (3 - 2 * progress)
            image = aspectFill(CIImage(cvPixelBuffer: previousBuffer)).applyingFilter(
                "CIDissolveTransition",
                parameters: [kCIInputTargetImageKey: image, kCIInputTimeKey: eased]
            )
        }

        guard let pool else { return }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        guard let pixelBuffer else { return }
        context.render(image, to: pixelBuffer, bounds: CGRect(origin: .zero, size: outputSize), colorSpace: colorSpace)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        lastOutput = pixelBuffer
        deliver(pixelBuffer)
    }

    private func deliver(_ pixelBuffer: CVPixelBuffer) {
        output.send(pixelBuffer)

        var format: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &format)
        guard let format else { return }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CaptainShared.frameRate),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard let sampleBuffer else { return }
        sampleBuffer.markDisplayImmediately()
        programLayer.sampleBufferRenderer.enqueueSafely(sampleBuffer)
    }

    /// Scales and center-crops a camera frame to fill the output size.
    private func aspectFill(_ image: CIImage) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let scale = max(outputSize.width / extent.width, outputSize.height / extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let dx = -scaled.extent.minX - (scaled.extent.width - outputSize.width) / 2
        let dy = -scaled.extent.minY - (scaled.extent.height - outputSize.height) / 2
        return scaled
            .transformed(by: CGAffineTransform(translationX: dx, y: dy))
            .cropped(to: CGRect(origin: .zero, size: outputSize))
    }
}
