import SwiftUI
import AppKit

@MainActor
final class CountdownModel: ObservableObject {
    @Published var number: Int = 3
}

private struct CountdownView: View {
    @ObservedObject var model: CountdownModel
    var body: some View {
        ZStack {
            Circle().fill(Color.black.opacity(0.78))
            Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 2)
            Text("\(model.number)")
                .font(.system(size: 92, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .id(model.number)
                .transition(.scale(scale: 1.4).combined(with: .opacity))
        }
        .padding(8)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: model.number)
    }
}

private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Small floating 3-2-1 overlay. Excluded from screen capture.
@MainActor
final class CountdownOverlay {
    private let model = CountdownModel()
    private var panel: NSPanel?

    func show(number: Int, on screen: NSScreen) {
        model.number = number
        if panel == nil {
            let size: CGFloat = 190
            let f = NSRect(x: screen.frame.midX - size / 2, y: screen.frame.midY - size / 2, width: size, height: size)
            let p = OverlayPanel(contentRect: f, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .screenSaver
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.ignoresMouseEvents = true
            p.sharingType = .none
            p.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: CountdownView(model: model))
            host.sizingOptions = []
            p.contentView = host
            p.orderFrontRegardless()
            panel = p
        }
    }

    func hide() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }
}
