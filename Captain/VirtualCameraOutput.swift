import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation
import os.log

private let logger = Logger(subsystem: CaptainShared.appBundleID, category: "VirtualCamera")

/// Pushes composited frames into the Captain Camera extension's sink stream.
///
/// The extension publishes a device with two streams. Video apps read the source stream;
/// we find the sink stream through the CoreMediaIO HAL and enqueue sample buffers into it.
final class VirtualCameraOutput {
    /// Called on a background queue whenever the sink connection comes or goes.
    var onConnectionChange: ((Bool) -> Void)?

    private let queue = DispatchQueue(label: "captain.virtualcamera")
    private let lock = NSLock()
    private var deviceID: CMIODeviceID = 0
    private var streamID: CMIOStreamID = 0
    private var bufferQueue: CMSimpleQueue?
    private var timer: DispatchSourceTimer?

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 2.0)
            timer.setEventHandler { [weak self] in self?.checkConnection() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            disconnect()
        }
    }

    func send(_ pixelBuffer: CVPixelBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let bufferQueue,
              CMSimpleQueueGetCount(bufferQueue) < CMSimpleQueueGetCapacity(bufferQueue) else { return }

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
        let element = Unmanaged.passRetained(sampleBuffer).toOpaque()
        if CMSimpleQueueEnqueue(bufferQueue, element: element) != noErr {
            Unmanaged<CMSampleBuffer>.fromOpaque(element).release()
        }
    }

    // MARK: - Connection (runs on `queue`)

    private func checkConnection() {
        let device = findVirtualDevice()
        let isConnected = lock.withLock { bufferQueue != nil }
        if isConnected {
            // The extension restarts after updates, which hands out a new device ID.
            if device == deviceID { return }
            disconnect()
        }
        guard let device else { return }
        connect(to: device)
    }

    private func connect(to device: CMIODeviceID) {
        let streams = objectIDs(of: device, selector: kCMIODevicePropertyStreams)
        let sink = streams.first { stringProperty(of: $0, selector: kCMIOObjectPropertyName) == CaptainShared.sinkStreamName }
            ?? (streams.count > 1 ? streams[1] : nil)
        guard let sink else {
            logger.error("Virtual camera has no sink stream")
            return
        }

        var queueRef: Unmanaged<CMSimpleQueue>?
        let copyStatus = CMIOStreamCopyBufferQueue(sink, { _, _, _ in }, nil, &queueRef)
        guard copyStatus == noErr, let queue = queueRef?.takeRetainedValue() else {
            logger.error("CMIOStreamCopyBufferQueue failed: \(copyStatus)")
            return
        }
        let startStatus = CMIODeviceStartStream(device, sink)
        guard startStatus == noErr else {
            logger.error("CMIODeviceStartStream failed: \(startStatus)")
            return
        }

        lock.withLock {
            deviceID = device
            streamID = sink
            bufferQueue = queue
        }
        logger.info("Connected to virtual camera sink")
        onConnectionChange?(true)
    }

    private func disconnect() {
        let wasConnected = lock.withLock {
            let connected = bufferQueue != nil
            if connected {
                CMIODeviceStopStream(deviceID, streamID)
            }
            bufferQueue = nil
            deviceID = 0
            streamID = 0
            return connected
        }
        if wasConnected {
            onConnectionChange?(false)
        }
    }

    private func findVirtualDevice() -> CMIODeviceID? {
        objectIDs(of: CMIOObjectID(kCMIOObjectSystemObject), selector: kCMIOHardwarePropertyDevices)
            .first { stringProperty(of: $0, selector: kCMIODevicePropertyDeviceUID) == CaptainShared.virtualDeviceUID }
    }

    // MARK: - CMIO property helpers

    private func address(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(selector),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
    }

    private func objectIDs(of object: CMIOObjectID, selector: Int) -> [CMIOObjectID] {
        var address = address(selector)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &address, 0, nil, size, &used, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size))
    }

    private func stringProperty(of object: CMIOObjectID, selector: Int) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            CMIOObjectGetPropertyData(object, &address, 0, nil, size, &used, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
