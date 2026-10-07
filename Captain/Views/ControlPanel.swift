import SwiftUI

struct ControlPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Switching") {
                Picker("Mode", selection: $model.mode) {
                    ForEach(SwitchMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                LabeledSlider(
                    title: "Switch delay",
                    value: $model.switchDelay,
                    range: 0...2,
                    format: { String(format: "%.2fs", $0) },
                    help: "How long you need to look at a display before it goes live."
                )
                LabeledSlider(
                    title: "Stickiness",
                    value: $model.stickiness,
                    range: 0...0.2,
                    format: { String(format: "%.2f", $0) },
                    help: "How much more directly you must face a new camera before switching. Raise it if switching flickers."
                )
                LabeledSlider(
                    title: "Eye gaze influence",
                    value: $model.eyeGazeWeight,
                    range: 0...1.5,
                    format: { String(format: "%.2f", $0) },
                    help: "Blend pupil direction into head direction. 0 uses head direction only."
                )
            }

            Section("Transition") {
                Picker("Style", selection: $model.transition) {
                    ForEach(TransitionStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                LabeledSlider(
                    title: "Crossfade duration",
                    value: $model.crossfadeDuration,
                    range: 0.1...2,
                    format: { String(format: "%.2fs", $0) },
                    help: nil
                )
                .disabled(model.transition == .cut)
            }

            Section("Cameras") {
                ForEach(model.cameras) { camera in
                    Toggle(isOn: Binding(
                        get: { camera.isEnabled },
                        set: { model.setEnabled($0, for: camera.id) }
                    )) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(camera.name)
                            if camera.name != camera.deviceName {
                                Text(camera.deviceName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Toggle("Center Stage", isOn: $model.centerStageEnabled)
                    .help("Apple's auto-framing on Studio Display cameras.")
                Toggle("Mirror previews", isOn: $model.mirrorPreview)
                    .help("Mirrors the previews in this window only. The virtual camera output is never mirrored.")
            }

            Section("Virtual Camera") {
                VirtualCameraStatus()
            }
        }
        .formStyle(.grouped)
    }
}

private struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String
    let help: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
                .labelsHidden()
            if let help {
                Text(help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct VirtualCameraStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let manager = model.extensionManager
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(model.virtualCameraConnected ? Color.green : Color.orange)
                    .frame(width: 9, height: 9)
                Text(model.virtualCameraConnected ? "Captain Camera is live" : statusText(manager.status))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.virtualCameraConnected {
                Text("Choose “Captain Camera” as the camera in Zoom, Meet, FaceTime, OBS, etc.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if manager.status != .notBundled {
                installButtons(manager)
            }
        }
    }

    @ViewBuilder
    private func installButtons(_ manager: ExtensionManager) -> some View {
        HStack {
            Button(manager.status == .active || model.virtualCameraConnected ? "Reinstall" : "Install") {
                    manager.activate()
                }
            if manager.status == .needsApproval {
                Button("Open System Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                }
            }
        }
    }

    private func statusText(_ status: ExtensionManager.Status) -> String {
        switch status {
        case .unknown: return "Checking extension…"
        case .activating: return "Installing extension…"
        case .needsApproval: return "Allow “Captain” under System Settings → General → Login Items & Extensions → Camera Extensions."
        case .active: return "Extension installed. Waiting for the camera to appear…"
        case .needsReboot: return "Restart your Mac to finish installing."
        case .notInApplications: return "Move Captain to /Applications to install the virtual camera."
        case .notBundled: return "Preview build: the virtual camera isn't included. Build with a paid Apple Developer team (CAPTAIN_TEAM_ID) to enable Captain Camera."
        case .failed(let message): return "Install failed: \(message)"
        }
    }
}
