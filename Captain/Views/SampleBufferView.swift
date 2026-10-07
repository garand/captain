import AVFoundation
import SwiftUI

/// Hosts an existing AVSampleBufferDisplayLayer (camera or program feed) in SwiftUI.
struct SampleBufferView: NSViewRepresentable {
    let layer: AVSampleBufferDisplayLayer?
    var mirrored = false

    func makeNSView(context: Context) -> HostView {
        HostView()
    }

    func updateNSView(_ view: HostView, context: Context) {
        view.host(layer, mirrored: mirrored)
    }

    final class HostView: NSView {
        private var hosted: CALayer?
        private var mirrored = false

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
        }

        required init?(coder: NSCoder) { fatalError() }

        func host(_ newLayer: CALayer?, mirrored: Bool) {
            if hosted !== newLayer {
                hosted?.removeFromSuperlayer()
                hosted = newLayer
                if let newLayer { layer?.addSublayer(newLayer) }
            }
            self.mirrored = mirrored
            needsLayout = true
        }

        override func layout() {
            super.layout()
            guard let hosted else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hosted.setAffineTransform(.identity)
            hosted.bounds = CGRect(origin: .zero, size: bounds.size)
            hosted.position = CGPoint(x: bounds.midX, y: bounds.midY)
            hosted.setAffineTransform(mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity)
            CATransaction.commit()
        }
    }
}
