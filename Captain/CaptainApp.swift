import AppKit
import SwiftUI

@main
struct CaptainApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("Captain", id: "main") {
            ContentView()
                .environment(model)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1320, height: 880)
        .commands {
            SwitchingCommands(model: model)
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(model)
        } label: {
            Image(systemName: model.mode == .auto ? "eye.circle.fill" : "video.circle.fill")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.start()
    }

    /// Keep feeding the virtual camera after the window is closed; quit from the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.shutdown()
    }
}

struct SwitchingCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandMenu("Switching") {
            Button("Auto Switching") { model.mode = .auto }
                .keyboardShortcut("0", modifiers: .command)
            ForEach(Array(model.enabledCameras.prefix(9).enumerated()), id: \.element.id) { index, camera in
                Button(camera.name) { model.selectCamera(at: index) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
            Divider()
            Button(model.transition == .cut ? "Use Crossfade" : "Use Cut") {
                model.transition = model.transition == .cut ? .crossfade : .cut
            }
            .keyboardShortcut("t", modifiers: .command)
        }
    }
}

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        Text("Live: \(model.activeCamera?.name ?? "None")")
        Text(model.virtualCameraConnected ? "Virtual camera connected" : "Virtual camera not connected")
        Divider()
        Picker("Mode", selection: $model.mode) {
            ForEach(SwitchMode.allCases) { Text($0.title).tag($0) }
        }
        Picker("Transition", selection: $model.transition) {
            ForEach(TransitionStyle.allCases) { Text($0.title).tag($0) }
        }
        Divider()
        ForEach(Array(model.enabledCameras.enumerated()), id: \.element.id) { index, camera in
            Button {
                model.select(camera.id)
            } label: {
                Text(camera.id == model.activeCameraID ? "● \(camera.name)" : "    \(camera.name)")
            }
        }
        Divider()
        Button("Show Captain") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Quit Captain") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
