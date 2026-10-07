import AVFoundation
import CoreAudio
import Observation
import QuartzCore

enum SwitchMode: String, CaseIterable, Identifiable {
    case auto, manual
    var id: Self { self }
    var title: String { self == .auto ? "Auto" : "Manual" }
}

enum TransitionStyle: String, CaseIterable, Identifiable {
    case cut, crossfade
    var id: Self { self }
    var title: String { self == .cut ? "Cut" : "Crossfade" }
}

struct CameraInfo: Identifiable, Equatable {
    let id: String
    var name: String
    let deviceName: String
    var isEnabled: Bool
}

struct CameraScore {
    var reading: FaceReading?
    /// Smoothed off-axis value; lower means you're looking more directly at this camera.
    var smoothed: Double = 1
    var lastFaceTime: CFTimeInterval = 0

    func hasFace(at now: CFTimeInterval) -> Bool {
        lastFaceTime > 0 && now - lastFaceTime < AppModel.faceTimeout
    }

    /// 0...1 for display: how directly you're facing this camera.
    var attention: Double {
        guard reading != nil else { return 0 }
        return min(1, max(0, 1 - smoothed / 0.4))
    }
}

@Observable
final class AppModel {
    static let shared = AppModel()
    static let faceTimeout: CFTimeInterval = 0.6
    private static let smoothing = 0.45

    // MARK: Observable state

    /// Every connected camera, in display order.
    private(set) var cameras: [CameraInfo] = []
    private(set) var scores: [String: CameraScore] = [:]
    private(set) var activeCameraID: String?
    private(set) var pendingCameraID: String?
    private(set) var pendingProgress: Double = 0
    private(set) var authorization = AVCaptureDevice.authorizationStatus(for: .video)
    private(set) var virtualCameraConnected = false
    private(set) var switchCount = 0

    var mode: SwitchMode {
        didSet {
            defaults.set(mode.rawValue, forKey: Keys.mode)
            pendingCameraID = nil
        }
    }

    var transition: TransitionStyle {
        didSet { defaults.set(transition.rawValue, forKey: Keys.transition) }
    }

    var crossfadeDuration: Double {
        didSet { defaults.set(crossfadeDuration, forKey: Keys.crossfadeDuration) }
    }

    /// How long a new camera has to win before we switch to it.
    var switchDelay: Double {
        didSet { defaults.set(switchDelay, forKey: Keys.switchDelay) }
    }

    /// How much better a new camera has to be than the active one.
    var stickiness: Double {
        didSet { defaults.set(stickiness, forKey: Keys.stickiness) }
    }

    var eyeGazeWeight: Double {
        didSet { defaults.set(eyeGazeWeight, forKey: Keys.eyeGazeWeight) }
    }

    var mirrorPreview: Bool {
        didSet { defaults.set(mirrorPreview, forKey: Keys.mirrorPreview) }
    }

    var centerStageEnabled: Bool {
        didSet {
            AVCaptureDevice.centerStageControlMode = .cooperative
            AVCaptureDevice.isCenterStageEnabled = centerStageEnabled
        }
    }

    var enabledCameras: [CameraInfo] { cameras.filter(\.isEnabled) }

    var activeCamera: CameraInfo? { cameras.first { $0.id == activeCameraID } }

    // MARK: Internals

    @ObservationIgnored let compositor = Compositor()
    @ObservationIgnored let extensionManager = ExtensionManager()
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var feeds: [String: CameraFeed] = [:]
    @ObservationIgnored private let discovery = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.external, .builtInWideAngleCamera, .continuityCamera, .deskViewCamera],
        mediaType: .video,
        position: .unspecified
    )
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var pendingSince: CFTimeInterval = 0
    @ObservationIgnored private var started = false
    @ObservationIgnored private var customNames: [String: String]
    @ObservationIgnored private var enabledOverrides: [String: Bool]
    @ObservationIgnored private var order: [String]

    private enum Keys {
        static let mode = "mode"
        static let transition = "transition"
        static let crossfadeDuration = "crossfadeDuration"
        static let switchDelay = "switchDelay"
        static let stickiness = "stickiness"
        static let eyeGazeWeight = "eyeGazeWeight"
        static let mirrorPreview = "mirrorPreview"
        static let customNames = "customNames"
        static let enabledOverrides = "enabledOverrides"
        static let order = "cameraOrder"
    }

    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            Keys.mode: SwitchMode.auto.rawValue,
            Keys.transition: TransitionStyle.crossfade.rawValue,
            Keys.crossfadeDuration: 0.4,
            Keys.switchDelay: 0.35,
            Keys.stickiness: 0.05,
            Keys.eyeGazeWeight: 0.5,
            Keys.mirrorPreview: true,
        ])
        mode = SwitchMode(rawValue: defaults.string(forKey: Keys.mode) ?? "") ?? .auto
        transition = TransitionStyle(rawValue: defaults.string(forKey: Keys.transition) ?? "") ?? .crossfade
        crossfadeDuration = defaults.double(forKey: Keys.crossfadeDuration)
        switchDelay = defaults.double(forKey: Keys.switchDelay)
        stickiness = defaults.double(forKey: Keys.stickiness)
        eyeGazeWeight = defaults.double(forKey: Keys.eyeGazeWeight)
        mirrorPreview = defaults.bool(forKey: Keys.mirrorPreview)
        centerStageEnabled = AVCaptureDevice.isCenterStageEnabled
        customNames = defaults.dictionary(forKey: Keys.customNames) as? [String: String] ?? [:]
        enabledOverrides = defaults.dictionary(forKey: Keys.enabledOverrides) as? [String: Bool] ?? [:]
        order = defaults.stringArray(forKey: Keys.order) ?? []
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true

        // Keep frames flowing at full rate while the window is hidden.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Live camera switching")

        compositor.output.onConnectionChange = { [weak self] connected in
            DispatchQueue.main.async { self?.virtualCameraConnected = connected }
        }
        compositor.start()
        extensionManager.activate()

        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshCameras()
            })
        }

        AVCaptureDevice.requestAccess(for: .video) { _ in
            DispatchQueue.main.async {
                self.authorization = AVCaptureDevice.authorizationStatus(for: .video)
                self.refreshCameras()
            }
        }
    }

    func shutdown() {
        feeds.values.forEach { $0.stop() }
        compositor.stop()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
    }

    // MARK: Cameras

    func refreshCameras() {
        guard authorization == .authorized else { return }
        let devices = discovery.devices.filter {
            $0.uniqueID != CaptainShared.virtualDeviceUID && $0.localizedName != CaptainShared.virtualDeviceName
        }
        let hasExternal = devices.contains { $0.deviceType == .external && !isVirtual($0) }

        // Number duplicate names ("Studio Display Camera 1/2/3") in a stable order.
        let sortedByID = devices.sorted { $0.uniqueID < $1.uniqueID }
        var nameCounts: [String: Int] = [:]
        for device in devices { nameCounts[device.localizedName, default: 0] += 1 }
        var nameIndex: [String: Int] = [:]
        var defaultNames: [String: String] = [:]
        for device in sortedByID {
            if nameCounts[device.localizedName, default: 0] > 1 {
                nameIndex[device.localizedName, default: 0] += 1
                defaultNames[device.uniqueID] = "\(device.localizedName) \(nameIndex[device.localizedName]!)"
            } else {
                defaultNames[device.uniqueID] = device.localizedName
            }
        }

        var infos = devices.map { device in
            let defaultEnabled = hasExternal ? (device.deviceType == .external && !isVirtual(device)) : !isVirtual(device)
            return CameraInfo(
                id: device.uniqueID,
                name: customNames[device.uniqueID] ?? defaultNames[device.uniqueID] ?? device.localizedName,
                deviceName: device.localizedName,
                isEnabled: enabledOverrides[device.uniqueID] ?? defaultEnabled
            )
        }
        infos.sort { lhs, rhs in
            let l = order.firstIndex(of: lhs.id) ?? Int.max
            let r = order.firstIndex(of: rhs.id) ?? Int.max
            return l != r ? l < r : lhs.id < rhs.id
        }

        // Start feeds for enabled cameras, stop the rest.
        let wanted = Set(infos.filter(\.isEnabled).map(\.id))
        for id in feeds.keys where !wanted.contains(id) {
            feeds[id]?.stop()
            feeds[id] = nil
            scores[id] = nil
        }
        for id in wanted where feeds[id] == nil {
            guard let device = devices.first(where: { $0.uniqueID == id }) else { continue }
            do {
                let feed = try CameraFeed(device: device)
                feed.onReading = { [weak self] reading in
                    DispatchQueue.main.async { self?.ingest(reading, from: id) }
                }
                feed.start()
                feeds[id] = feed
            } catch {
                print("Could not start camera \(device.localizedName): \(error)")
            }
        }
        compositor.setFeeds(feeds)
        cameras = infos
        ensureActiveCamera()
    }

    func previewLayer(for id: String) -> AVSampleBufferDisplayLayer? {
        feeds[id]?.displayLayer
    }

    func setEnabled(_ enabled: Bool, for id: String) {
        enabledOverrides[id] = enabled
        defaults.set(enabledOverrides, forKey: Keys.enabledOverrides)
        refreshCameras()
    }

    func rename(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        customNames[id] = trimmed.isEmpty ? nil : trimmed
        defaults.set(customNames, forKey: Keys.customNames)
        refreshCameras()
    }

    func move(_ id: String, by offset: Int) {
        var ids = cameras.map(\.id)
        guard let index = ids.firstIndex(of: id) else { return }
        let target = min(max(index + offset, 0), ids.count - 1)
        ids.swapAt(index, target)
        order = ids
        defaults.set(order, forKey: Keys.order)
        refreshCameras()
    }

    private func isVirtual(_ device: AVCaptureDevice) -> Bool {
        UInt32(bitPattern: device.transportType) == kAudioDeviceTransportTypeVirtual
    }

    private func ensureActiveCamera() {
        if let activeCameraID, feeds[activeCameraID] != nil { return }
        if let first = enabledCameras.first(where: { feeds[$0.id] != nil }) {
            switchTo(first.id, animated: false)
        } else {
            activeCameraID = nil
        }
    }

    // MARK: Switching

    /// Manually take a camera live. Switches to manual mode so auto doesn't override it.
    func select(_ id: String) {
        mode = .manual
        switchTo(id)
    }

    func selectCamera(at index: Int) {
        let enabled = enabledCameras
        guard enabled.indices.contains(index) else { return }
        select(enabled[index].id)
    }

    private func switchTo(_ id: String, animated: Bool = true) {
        guard id != activeCameraID else { return }
        let hadActive = activeCameraID != nil
        activeCameraID = id
        pendingCameraID = nil
        pendingProgress = 0
        switchCount += 1
        if animated, hadActive, transition == .crossfade {
            compositor.crossfade(to: id, duration: crossfadeDuration)
        } else {
            compositor.cut(to: id)
        }
    }

    private func ingest(_ reading: FaceReading?, from id: String) {
        guard feeds[id] != nil else { return }
        let now = CACurrentMediaTime()
        var score = scores[id] ?? CameraScore()
        score.reading = reading
        if let reading {
            let raw = reading.offAxis(eyeWeight: eyeGazeWeight)
            score.smoothed = score.hasFace(at: now) ? score.smoothed + Self.smoothing * (raw - score.smoothed) : raw
            score.lastFaceTime = now
        }
        scores[id] = score
        evaluate(at: now)
    }

    /// Picks the camera you're facing most directly, with hysteresis and a dwell delay
    /// so glances and noise don't cause flicker.
    private func evaluate(at now: CFTimeInterval) {
        guard mode == .auto else { return }
        let candidates = enabledCameras.compactMap { camera -> (String, Double)? in
            guard let score = scores[camera.id], score.hasFace(at: now) else { return nil }
            return (camera.id, score.smoothed)
        }
        guard let best = candidates.min(by: { $0.1 < $1.1 }), best.0 != activeCameraID else {
            clearPending()
            return
        }
        let activeScore = activeCameraID.flatMap { scores[$0] }.flatMap { $0.hasFace(at: now) ? $0.smoothed : nil } ?? .infinity
        guard best.1 + stickiness < activeScore else {
            clearPending()
            return
        }
        if pendingCameraID != best.0 {
            pendingCameraID = best.0
            pendingSince = now
        }
        let elapsed = now - pendingSince
        if elapsed >= switchDelay {
            switchTo(best.0)
        } else {
            pendingProgress = switchDelay > 0 ? elapsed / switchDelay : 1
        }
    }

    private func clearPending() {
        if pendingCameraID != nil {
            pendingCameraID = nil
            pendingProgress = 0
        }
    }
}
