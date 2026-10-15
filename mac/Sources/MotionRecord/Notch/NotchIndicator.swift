import AppKit
import SwiftUI

// Owned by the APP/UI agent.
//
// A black "Dynamic Island"-style pill that grows out of the physical notch (or a plain pill at the
// top-center of screens without a notch). The panel is excluded from screen capture (sharingType = .none).

// MARK: - Layout

struct NotchLayout {
    var hasNotch: Bool
    var collapsedWidth: CGFloat
    var expandedWidth: CGFloat
    var collapsedHeight: CGFloat
    var expandedHeight: CGFloat
    /// Width of the dead zone in the middle (the physical notch) that must stay free of content.
    var gap: CGFloat
    /// Distance from the top of the screen to the top of the shape.
    var topOffset: CGFloat
    var collapsedBottomRadius: CGFloat
    var expandedBottomRadius: CGFloat
    var screen: NSScreen

    @MainActor
    static func current() -> NotchLayout {
        let screens = NSScreen.screens
        let notchScreen = screens.first(where: { $0.safeAreaInsets.top > 0 })
        if let screen = notchScreen {
            let h = screen.safeAreaInsets.top
            var notchW: CGFloat = 200
            if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
                notchW = max(100, r.minX - l.maxX)
            }
            let wing: CGFloat = 84
            return NotchLayout(hasNotch: true,
                               collapsedWidth: notchW, expandedWidth: notchW + wing * 2,
                               collapsedHeight: h, expandedHeight: h + 4,
                               gap: notchW, topOffset: 0,
                               collapsedBottomRadius: 9, expandedBottomRadius: 17,
                               screen: screen)
        }
        let screen = NSScreen.main ?? screens.first!
        return NotchLayout(hasNotch: false,
                           collapsedWidth: 64, expandedWidth: 168,
                           collapsedHeight: 22, expandedHeight: 32,
                           gap: 0, topOffset: 6,
                           collapsedBottomRadius: 11, expandedBottomRadius: 16,
                           screen: screen)
    }
}

// MARK: - SwiftUI

@MainActor
final class NotchModel: ObservableObject {
    @Published var expanded = false
    @Published var elapsed: TimeInterval = 0
    var onTap: (() -> Void)?
}

struct NotchView: View {
    @ObservedObject var model: NotchModel
    let layout: NotchLayout
    @State private var pulse = false

    private var width: CGFloat { model.expanded ? layout.expandedWidth : layout.collapsedWidth }
    private var height: CGFloat { model.expanded ? layout.expandedHeight : layout.collapsedHeight }
    private var bottomRadius: CGFloat { model.expanded ? layout.expandedBottomRadius : layout.collapsedBottomRadius }
    private var topRadius: CGFloat { layout.hasNotch ? 0 : bottomRadius }

    var body: some View {
        ZStack(alignment: .top) {
            UnevenRoundedRectangle(topLeadingRadius: topRadius, bottomLeadingRadius: bottomRadius,
                                   bottomTrailingRadius: bottomRadius, topTrailingRadius: topRadius,
                                   style: .continuous)
                .fill(Color.black)
                .frame(width: width, height: height)
                .overlay(alignment: .top) {
                    content
                        .frame(width: layout.expandedWidth, height: layout.collapsedHeight + (layout.hasNotch ? 0 : 10))
                        .opacity(model.expanded ? 1 : 0)
                        .animation(model.expanded ? .easeOut(duration: 0.22).delay(0.14) : .easeIn(duration: 0.1),
                                   value: model.expanded)
                }
                .contentShape(Rectangle())
                .onTapGesture { model.onTap?() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, layout.topOffset)
        .ignoresSafeArea()
        .animation(.spring(response: 0.46, dampingFraction: 0.74), value: model.expanded)
    }

    private var content: some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                ZStack {
                    Circle().fill(Color.red.opacity(0.35))
                        .frame(width: 16, height: 16)
                        .scaleEffect(pulse ? 1.0 : 0.4)
                        .opacity(pulse ? 0.0 : 0.8)
                    Circle().fill(Color(red: 1, green: 0.22, blue: 0.27))
                        .frame(width: 9, height: 9)
                        .opacity(pulse ? 1 : 0.55)
                }
                .frame(width: 16, height: 16)
            }
            .frame(maxWidth: .infinity, alignment: .center)

            Spacer().frame(width: layout.gap)

            Text(Self.format(model.elapsed))
                .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.horizontal, layout.hasNotch ? 6 : 12)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    static func format(_ t: TimeInterval) -> String {
        let s = Int(max(0, t))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }
}

// MARK: - AppKit plumbing

private final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class NotchIndicator {
    /// Called when the user clicks the pill (stop recording).
    var onStop: (() -> Void)?

    private let model = NotchModel()
    private var panel: NSPanel?
    private var generation = 0

    /// Window number of the indicator panel (lets the capture side exclude it explicitly if needed).
    var windowNumber: Int? { panel?.windowNumber }

    func show() {
        generation += 1
        if let panel {
            // Re-show while the hide animation is running.
            panel.alphaValue = 1
            withAnimation(.spring(response: 0.46, dampingFraction: 0.74)) { model.expanded = true }
            return
        }
        let layout = NotchLayout.current()
        model.elapsed = 0
        model.expanded = false
        model.onTap = { [weak self] in self?.onStop?() }

        let screenFrame = layout.screen.frame
        let height = layout.expandedHeight + layout.topOffset + 6
        let width = layout.expandedWidth + 12
        let frame = NSRect(x: screenFrame.midX - width / 2, y: screenFrame.maxY - height,
                           width: width, height: height)

        let panel = NotchPanel(contentRect: frame,
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        panel.isFloatingPanel = true      // must precede `level` (it resets the level to .floating)
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.isReleasedWhenClosed = false
        // Never captured in the recording (MR_NOTCH_CAPTURABLE=1 is a debug switch for taking screenshots of it).
        panel.sharingType = ProcessInfo.processInfo.environment["MR_NOTCH_CAPTURABLE"] == "1" ? .readOnly : .none
        panel.animationBehavior = .none

        let host = ClickThroughHostingView(rootView: NotchView(model: model, layout: layout))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: frame.size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        self.panel = panel

        let gen = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, gen == self.generation else { return }
            withAnimation(.spring(response: 0.46, dampingFraction: 0.74)) { self.model.expanded = true }
        }
    }

    func update(elapsed: TimeInterval) {
        model.elapsed = elapsed
    }

    func hide() {
        guard let panel else { return }
        generation += 1
        let gen = generation
        withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { model.expanded = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, gen == self.generation else { return }
            panel.orderOut(nil)
            panel.close()
            self.panel = nil
        }
    }
}
