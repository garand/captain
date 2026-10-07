import AVFoundation
import QuartzCore

/// One physical webcam: runs its own capture session, keeps the latest frame for the
/// compositor, feeds a preview layer, and periodically runs face analysis.
final class CameraFeed: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let id: String
    let device: AVCaptureDevice
    let displayLayer = AVSampleBufferDisplayLayer()

    /// Called on a background queue with each analysis result (nil = no face).
    var onReading: ((FaceReading?) -> Void)?

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue: DispatchQueue
    private let captureQueue: DispatchQueue
    private let analysisQueue: DispatchQueue
    private let analyzer = FaceAnalyzer()
    private let analysisInterval: CFTimeInterval = 1.0 / 12.0

    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    // Only touched on captureQueue.
    private var lastAnalysisTime: CFTimeInterval = 0
    private var isAnalyzing = false

    init(device: AVCaptureDevice) throws {
        self.id = device.uniqueID
        self.device = device
        sessionQueue = DispatchQueue(label: "captain.session.\(device.uniqueID)")
        captureQueue = DispatchQueue(label: "captain.capture.\(device.uniqueID)", qos: .userInteractive)
        analysisQueue = DispatchQueue(label: "captain.analysis.\(device.uniqueID)", qos: .userInitiated)
        super.init()

        session.beginConfiguration()
        session.sessionPreset = session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CameraFeedError.cannotAddInput }
        session.addInput(input)

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: captureQueue)
        guard session.canAddOutput(videoOutput) else { throw CameraFeedError.cannotAddOutput }
        session.addOutput(videoOutput)
        session.commitConfiguration()

        displayLayer.videoGravity = .resizeAspectFill
    }

    var latestPixelBuffer: CVPixelBuffer? {
        lock.withLock { latest }
    }

    func start() {
        sessionQueue.async { self.session.startRunning() }
    }

    func stop() {
        sessionQueue.async { self.session.stopRunning() }
        lock.withLock { latest = nil }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = sampleBuffer.imageBuffer else { return }
        lock.withLock { latest = pixelBuffer }

        sampleBuffer.markDisplayImmediately()
        displayLayer.sampleBufferRenderer.enqueueSafely(sampleBuffer)

        let now = CACurrentMediaTime()
        guard !isAnalyzing, now - lastAnalysisTime >= analysisInterval else { return }
        lastAnalysisTime = now
        isAnalyzing = true
        analysisQueue.async { [weak self] in
            guard let self else { return }
            let reading = self.analyzer.analyze(pixelBuffer)
            self.captureQueue.async { self.isAnalyzing = false }
            self.onReading?(reading)
        }
    }
}

enum CameraFeedError: Error {
    case cannotAddInput
    case cannotAddOutput
}

extension CMSampleBuffer {
    /// Lets an AVSampleBufferDisplayLayer show the frame without a timebase.
    func markDisplayImmediately() {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(self, createIfNecessary: true),
              CFArrayGetCount(attachments) > 0 else { return }
        let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(
            dictionary,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
    }
}

extension AVSampleBufferVideoRenderer {
    func enqueueSafely(_ sampleBuffer: CMSampleBuffer) {
        if status == .failed || requiresFlushToResumeDecoding {
            flush()
        }
        enqueue(sampleBuffer)
    }
}
