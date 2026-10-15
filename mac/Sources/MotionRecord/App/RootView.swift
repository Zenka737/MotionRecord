import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) private var openWindow
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.stroke).frame(height: 1)
            Group {
                switch app.tab {
                case .record: RecordView()
                case .editor: EditorView()
                case .library: LibraryView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 1100, minHeight: 720)
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .background(WindowAccessor { window in
            if app.mainWindow !== window {
                app.mainWindow = window
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                window.isMovableByWindowBackground = false
                window.backgroundColor = NSColor(Theme.bg)
            }
        })
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { AppState.shared.handleDroppedFile(url) }
                }
            }
            return true
        }
        .overlay {
            if dropTargeted {
                ZStack {
                    Color.black.opacity(0.5)
                    VStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.down").font(.system(size: 36))
                        Text("Отпустите, чтобы открыть").font(.system(size: 15, weight: .semibold))
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 3, dash: [10, 6])).padding(10))
                .allowsHitTesting(false)
            }
        }
        .onAppear {
            app.openMainWindow = { openWindow(id: "main") }
        }
        .alert("Ошибка", isPresented: Binding(get: { app.errorMessage != nil },
                                              set: { if !$0 { app.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(app.errorMessage ?? "")
        }
    }

    private var header: some View {
        headerContent.background(WindowDragArea())
    }

    private var headerContent: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.accentGradient)
                    Image(systemName: "record.circle.fill").font(.system(size: 13, weight: .bold)).foregroundColor(.white)
                }
                .frame(width: 26, height: 26)
                Text("MotionRecord").font(.system(size: 14, weight: .semibold))
            }
            .padding(.leading, 76)   // room for the traffic lights

            Spacer()

            HStack(spacing: 4) {
                ForEach(AppTab.allCases) { tab in
                    Button {
                        app.tab = tab
                        if tab == .library { app.refreshLibrary() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: tab.icon)
                            Text(tab.title)
                        }
                        .font(.system(size: 12.5, weight: .medium))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .foregroundColor(app.tab == tab ? .white : Theme.textDim)
                        .background(Capsule().fill(app.tab == tab ? Color.white.opacity(0.12) : .clear))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(Capsule().fill(Color.white.opacity(0.05)))

            Spacer()
            Button { app.chooseVideoToOpen() } label: { Label("Открыть видео…", systemImage: "folder") }
                .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundColor(Theme.textDim)
                .padding(.trailing, 10).help("Открыть видео для редактирования (⌘O)")
            Text("⌘⇧R")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundColor(Theme.textDim)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))
                .padding(.trailing, 16)
        }
        .frame(height: 52)
    }
}


/// Only this area (the header) moves the window; the rest of the UI keeps its own drags (timeline, sliders, overlays).
private struct WindowDragArea: NSViewRepresentable {
    final class V: NSView { override var mouseDownCanMoveWindow: Bool { true } }
    func makeNSView(context: Context) -> NSView { V() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
