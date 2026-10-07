import SwiftUI

struct CameraTile: View {
    @Environment(AppModel.self) private var model
    let camera: CameraInfo
    let index: Int

    @State private var isRenaming = false
    @State private var draftName = ""

    private var isActive: Bool { model.activeCameraID == camera.id }
    private var isPending: Bool { model.pendingCameraID == camera.id }
    private var score: CameraScore? { model.scores[camera.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SampleBufferView(layer: model.previewLayer(for: camera.id), mirrored: model.mirrorPreview)
                .overlay {
                    if let reading = score?.reading {
                        FaceOverlay(reading: reading, eyeWeight: model.eyeGazeWeight, mirrored: model.mirrorPreview, isActive: isActive)
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: isActive || isPending ? 4 : 1)
                )
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 6) {
                        Text("\(index + 1)")
                            .font(.caption.monospacedDigit().bold())
                            .frame(width: 20, height: 20)
                            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
                        if isActive {
                            Pill(text: "LIVE", color: .red)
                        }
                    }
                    .padding(8)
                }
                .overlay(alignment: .bottom) {
                    if isPending {
                        GeometryReader { proxy in
                            Capsule()
                                .fill(Color.yellow)
                                .frame(width: proxy.size.width * model.pendingProgress, height: 4)
                        }
                        .frame(height: 4)
                        .padding(8)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: isActive)

            HStack {
                Text(camera.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                AttentionMeter(value: score?.attention ?? 0, highlighted: isActive)
            }
            Text(statusText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { model.select(camera.id) }
        .help("Click to take this camera live (switches to Manual)")
        .contextMenu {
            Button("Take Live") { model.select(camera.id) }
            Button("Rename…") {
                draftName = camera.name
                isRenaming = true
            }
            Divider()
            Button("Move Left") { model.move(camera.id, by: -1) }
            Button("Move Right") { model.move(camera.id, by: 1) }
            Divider()
            Button("Disable Camera") { model.setEnabled(false, for: camera.id) }
        }
        .alert("Rename Camera", isPresented: $isRenaming) {
            TextField("Name", text: $draftName)
            Button("Save") { model.rename(camera.id, to: draftName) }
            Button("Reset to Default") { model.rename(camera.id, to: "") }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Give this camera a name like Left, Center or Right.")
        }
    }

    private var borderColor: Color {
        if isActive { return .red }
        if isPending { return .yellow }
        return .white.opacity(0.15)
    }

    private var statusText: String {
        guard let score, let reading = score.reading else { return "No face detected" }
        var parts = ["Facing \(Int((score.attention * 100).rounded()))%"]
        parts.append(String(format: "head %+.2f", reading.headTurn * reading.axisSign))
        if let eye = reading.eyeTurn {
            parts.append(String(format: "eyes %+.2f", eye * reading.axisSign))
        }
        if let yaw = reading.yawDegrees {
            parts.append(String(format: "yaw %+.0f°", yaw))
        }
        return parts.joined(separator: " · ")
    }
}

/// Face box plus a line showing which way you're looking relative to this camera.
private struct FaceOverlay: View {
    let reading: FaceReading
    let eyeWeight: Double
    let mirrored: Bool
    let isActive: Bool

    var body: some View {
        GeometryReader { proxy in
            let rect = viewRect(in: proxy.size)
            let gaze = reading.gaze(eyeWeight: eyeWeight) * (mirrored ? -1 : 1)
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let tip = CGPoint(x: center.x + CGFloat(gaze) * rect.width * 2, y: center.y)

            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isActive ? Color.red : Color.white.opacity(0.8), lineWidth: 2)
                    .frame(width: rect.width, height: rect.height)
                    .position(center)
                Path { path in
                    path.move(to: center)
                    path.addLine(to: tip)
                }
                .stroke(Color.yellow, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                Circle()
                    .fill(Color.yellow)
                    .frame(width: 8, height: 8)
                    .position(tip)
            }
            .animation(.linear(duration: 0.08), value: rect)
        }
        .allowsHitTesting(false)
    }

    /// Maps Vision's normalized rect into the aspect-filled preview.
    private func viewRect(in size: CGSize) -> CGRect {
        let image = reading.imageSize
        guard image.width > 0, image.height > 0 else { return .zero }
        let scale = max(size.width / image.width, size.height / image.height)
        let drawn = CGSize(width: image.width * scale, height: image.height * scale)
        let originX = (size.width - drawn.width) / 2
        let originY = (size.height - drawn.height) / 2
        let box = reading.boundingBox
        let width = box.width * drawn.width
        let height = box.height * drawn.height
        var x = originX + box.minX * drawn.width
        let y = originY + (1 - box.maxY) * drawn.height
        if mirrored { x = size.width - x - width }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

private struct AttentionMeter: View {
    let value: Double
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<10) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Double(i) < value * 10 ? barColor : Color.white.opacity(0.12))
                    .frame(width: 5, height: 12)
            }
        }
        .animation(.easeOut(duration: 0.1), value: value)
    }

    private var barColor: Color { highlighted ? .red : .green }
}
