import AVFoundation
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 18) {
                HeaderBar()
                ProgramMonitor()
                CameraStrip()
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            ControlPanel()
                .frame(width: 320)
        }
        .frame(minWidth: 1080, minHeight: 760)
        .overlay {
            if model.authorization == .denied || model.authorization == .restricted {
                PermissionOverlay()
            }
        }
    }
}

// MARK: - Header

private struct HeaderBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Captain")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text("Follows your gaze across displays")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Mode", selection: $model.mode) {
                ForEach(SwitchMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .help("Auto follows your gaze. Clicking a camera switches to Manual. ⌘0 returns to Auto.")

            Picker("Transition", selection: $model.transition) {
                ForEach(TransitionStyle.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
    }
}

// MARK: - Program monitor

private struct ProgramMonitor: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SampleBufferView(layer: model.compositor.programLayer, mirrored: model.mirrorPreview)
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.red.opacity(0.9), lineWidth: 3)
            )
            .overlay(alignment: .topLeading) {
                HStack(spacing: 10) {
                    Pill(text: "PROGRAM", color: .red)
                    if let camera = model.activeCamera {
                        Text(camera.name)
                            .font(.headline)
                            .shadow(radius: 4)
                    }
                }
                .padding(14)
            }
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 8) {
                    Pill(text: model.mode == .auto ? "AUTO" : "MANUAL", color: model.mode == .auto ? .green : .orange)
                    Pill(text: model.transition == .cut ? "CUT" : "FADE", color: .gray)
                }
                .padding(14)
            }
            .overlay(alignment: .bottomLeading) {
                VirtualCameraBadge()
                    .padding(14)
            }
            .overlay {
                if model.activeCameraID == nil {
                    ContentUnavailableView(
                        "No Cameras",
                        systemImage: "video.slash",
                        description: Text("Enable at least one camera in the sidebar.")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct VirtualCameraBadge: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.virtualCameraConnected ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(model.virtualCameraConnected ? "Captain Camera is live" : model.extensionManager.status == .notBundled ? "Preview build: no virtual camera" : "Virtual camera not connected")
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.black.opacity(0.55), in: Capsule())
    }
}

struct Pill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.heavy))
            .tracking(0.6)
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color, in: Capsule())
    }
}

// MARK: - Camera strip

private struct CameraStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let cameras = model.enabledCameras
        if cameras.isEmpty {
            Text("No cameras enabled")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 120)
        } else {
            HStack(alignment: .top, spacing: 14) {
                ForEach(Array(cameras.enumerated()), id: \.element.id) { index, camera in
                    CameraTile(camera: camera, index: index)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Permission

private struct PermissionOverlay: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThickMaterial)
            VStack(spacing: 14) {
                Image(systemName: "video.slash.fill")
                    .font(.system(size: 44))
                Text("Camera access is off")
                    .font(.title2.bold())
                Text("Captain needs camera access to see which display you're looking at.")
                    .foregroundStyle(.secondary)
                Button("Open Privacy Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}
