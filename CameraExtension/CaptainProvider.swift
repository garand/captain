import CoreGraphics
import CoreMediaIO
import CoreText
import CoreVideo
import Foundation
import IOKit.audio
import os.log

private let logger = Logger(subsystem: CaptainShared.extensionBundleID, category: "Extension")

private func hostTimeNanos() -> UInt64 {
    UInt64(CMClockGetTime(CMClockGetHostTimeClock()).seconds * Double(NSEC_PER_SEC))
}

// MARK: - Provider

final class CaptainProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: CaptainDeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = CaptainDeviceSource(localizedName: CaptainShared.virtualDeviceName)
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("Failed to add device: \(error.localizedDescription)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {}

    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let providerProperties = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) {
            providerProperties.manufacturer = "Captain"
        }
        return providerProperties
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}

// MARK: - Device

/// One virtual device with two streams: a source stream that video apps read,
/// and a sink stream that the Captain app writes composited frames into.
final class CaptainDeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private var sourceStream: CaptainSourceStream!
    private var sinkStream: CaptainSinkStream!

    private let queue = DispatchQueue(label: "com.garand.captain.extension.frames", qos: .userInteractive)
    private var placeholderBuffer: CVPixelBuffer?
    private var placeholderFormat: CMFormatDescription?
    private var placeholderTimer: DispatchSourceTimer?

    private var sourceStreamingCount = 0
    private var sinkClient: CMIOExtensionClient?
    private var sinkActive = false
    private var lastSinkFrameTime: UInt64 = 0

    init(localizedName: String) {
        super.init()
        let deviceID = UUID(uuidString: CaptainShared.virtualDeviceUID)!
        device = CMIOExtensionDevice(localizedName: localizedName, deviceID: deviceID, legacyDeviceID: nil, source: self)

        var description: CMFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_32BGRA,
            width: CaptainShared.width,
            height: CaptainShared.height,
            extensions: nil,
            formatDescriptionOut: &description
        )
        let frameDuration = CMTime(value: 1, timescale: CaptainShared.frameRate)
        let format = CMIOExtensionStreamFormat(
            formatDescription: description!,
            maxFrameDuration: frameDuration,
            minFrameDuration: frameDuration,
            validFrameDurations: nil
        )

        sourceStream = CaptainSourceStream(localizedName: CaptainShared.sourceStreamName, streamFormat: format, owner: self)
        sinkStream = CaptainSinkStream(localizedName: CaptainShared.sinkStreamName, streamFormat: format, owner: self)
        do {
            try device.addStream(sourceStream.stream)
            try device.addStream(sinkStream.stream)
        } catch {
            fatalError("Failed to add streams: \(error.localizedDescription)")
        }

        placeholderBuffer = Self.makePlaceholder()
        if let placeholderBuffer {
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: placeholderBuffer, formatDescriptionOut: &placeholderFormat)
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel] }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let deviceProperties = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            deviceProperties.transportType = kIOAudioDeviceTransportTypeVirtual
        }
        if properties.contains(.deviceModel) {
            deviceProperties.model = "Captain Virtual Camera"
        }
        return deviceProperties
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    // MARK: Source stream (video apps)

    func startSourceStreaming() {
        queue.async { [weak self] in
            guard let self else { return }
            self.sourceStreamingCount += 1
            guard self.placeholderTimer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 1.0 / Double(CaptainShared.frameRate), leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in self?.sendPlaceholderIfIdle() }
            timer.resume()
            self.placeholderTimer = timer
        }
    }

    func stopSourceStreaming() {
        queue.async {
            self.sourceStreamingCount = max(0, self.sourceStreamingCount - 1)
            if self.sourceStreamingCount == 0 {
                self.placeholderTimer?.cancel()
                self.placeholderTimer = nil
            }
        }
    }

    /// When the Captain app isn't feeding frames, show a "not running" card instead of freezing.
    private func sendPlaceholderIfIdle() {
        let now = hostTimeNanos()
        guard now - lastSinkFrameTime > 500_000_000,
              let placeholderBuffer, let placeholderFormat else { return }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CaptainShared.frameRate),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: placeholderBuffer,
            formatDescription: placeholderFormat,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        if let sampleBuffer {
            sourceStream.stream.send(sampleBuffer, discontinuity: [], hostTimeInNanoseconds: now)
        }
    }

    // MARK: Sink stream (Captain app)

    func startSinkStreaming(client: CMIOExtensionClient) {
        queue.async {
            self.sinkClient = client
            self.sinkActive = true
            self.consumeNextSinkBuffer()
        }
    }

    func stopSinkStreaming() {
        queue.async {
            self.sinkActive = false
            self.sinkClient = nil
        }
    }

    private func consumeNextSinkBuffer() {
        guard sinkActive, let client = sinkClient else { return }
        sinkStream.stream.consumeSampleBuffer(from: client) { [weak self] sampleBuffer, sequenceNumber, _, _, _ in
            guard let self else { return }
            self.queue.async {
                guard let sampleBuffer else {
                    self.queue.asyncAfter(deadline: .now() + .milliseconds(5)) { self.consumeNextSinkBuffer() }
                    return
                }
                let now = hostTimeNanos()
                self.lastSinkFrameTime = now
                if self.sourceStreamingCount > 0 {
                    self.sourceStream.stream.send(sampleBuffer, discontinuity: [], hostTimeInNanoseconds: now)
                }
                let output = CMIOExtensionScheduledOutput(sequenceNumber: sequenceNumber, hostTimeInNanoseconds: now)
                self.sinkStream.stream.notifyScheduledOutputChanged(output)
                self.consumeNextSinkBuffer()
            }
        }
    }

    // MARK: Placeholder

    private static func makePlaceholder() -> CVPixelBuffer? {
        let width = Int(CaptainShared.width)
        let height = Int(CaptainShared.height)
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &pixelBuffer)
        guard let pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return pixelBuffer }

        context.setFillColor(CGColor(red: 0.07, green: 0.08, blue: 0.10, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        drawCenteredText("Captain", in: context, font: .emphasizedSystem, size: 96, alpha: 1, centerY: CGFloat(height) / 2 + 40, width: CGFloat(width))
        drawCenteredText("Open the Captain app to start the camera", in: context, font: .system, size: 36, alpha: 0.55, centerY: CGFloat(height) / 2 - 60, width: CGFloat(width))
        return pixelBuffer
    }

    private static func drawCenteredText(_ text: String, in context: CGContext, font fontType: CTFontUIFontType, size: CGFloat, alpha: CGFloat, centerY: CGFloat, width: CGFloat) {
        guard let font = CTFontCreateUIFontForLanguage(fontType, size, nil) else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: alpha),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        context.textPosition = CGPoint(x: (width - bounds.width) / 2 - bounds.minX, y: centerY - bounds.height / 2 - bounds.minY)
        CTLineDraw(line, context)
    }
}

// MARK: - Source stream

final class CaptainSourceStream: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let streamFormat: CMIOExtensionStreamFormat
    private weak var owner: CaptainDeviceSource?

    init(localizedName: String, streamFormat: CMIOExtensionStreamFormat, owner: CaptainDeviceSource) {
        self.streamFormat = streamFormat
        self.owner = owner
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: UUID(), direction: .source, clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [streamFormat] }

    var availableProperties: Set<CMIOExtensionProperty> { [.streamActiveFormatIndex, .streamFrameDuration] }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = 0
        }
        if properties.contains(.streamFrameDuration) {
            streamProperties.frameDuration = CMTime(value: 1, timescale: CaptainShared.frameRate)
        }
        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }

    func startStream() throws {
        owner?.startSourceStreaming()
    }

    func stopStream() throws {
        owner?.stopSourceStreaming()
    }
}

// MARK: - Sink stream

final class CaptainSinkStream: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let streamFormat: CMIOExtensionStreamFormat
    private weak var owner: CaptainDeviceSource?
    private var client: CMIOExtensionClient?

    init(localizedName: String, streamFormat: CMIOExtensionStreamFormat, owner: CaptainDeviceSource) {
        self.streamFormat = streamFormat
        self.owner = owner
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: UUID(), direction: .sink, clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [streamFormat] }

    var availableProperties: Set<CMIOExtensionProperty> {
        [
            .streamActiveFormatIndex,
            .streamFrameDuration,
            .streamSinkBufferQueueSize,
            .streamSinkBuffersRequiredForStartup,
            .streamSinkBufferUnderrunCount,
            .streamSinkEndOfData,
        ]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = 0
        }
        if properties.contains(.streamFrameDuration) {
            streamProperties.frameDuration = CMTime(value: 1, timescale: CaptainShared.frameRate)
        }
        if properties.contains(.streamSinkBufferQueueSize) {
            streamProperties.sinkBufferQueueSize = 2
        }
        if properties.contains(.streamSinkBuffersRequiredForStartup) {
            streamProperties.sinkBuffersRequiredForStartup = 1
        }
        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        self.client = client
        return true
    }

    func startStream() throws {
        guard let client else {
            logger.error("Sink started without an authorized client")
            return
        }
        owner?.startSinkStreaming(client: client)
    }

    func stopStream() throws {
        owner?.stopSinkStreaming()
    }
}
