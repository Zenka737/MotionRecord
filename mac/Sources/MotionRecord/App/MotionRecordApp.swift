import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        AppState.shared.bootstrap()
        if CommandLine.arguments.contains("--demo-notch") {
            AppState.shared.runNotchDemo()
        }
    }

    @MainActor
    func application(_ application: NSApplication, open urls: [URL]) {
        for u in urls { AppState.shared.handleDroppedFile(u) }
        AppState.shared.showMainWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @MainActor
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AppState.shared.showMainWindow() }
        return true
    }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppState.shared.isRecording else { return .terminateNow }
        Task { @MainActor in
            await AppState.shared.finishForTermination()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct MotionRecordApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var app = AppState.shared

    var body: some Scene {
        Window("MotionRecord", id: "main") {
            RootView()
                .environmentObject(app)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Открыть видео…") { AppState.shared.chooseVideoToOpen() }.keyboardShortcut("o")
            }
        }

        MenuBarExtra {
            MenuBarContent().environmentObject(app)
        } label: {
            MenuBarLabel().environmentObject(app)
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct MenuBarLabel: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        Image(systemName: app.isRecording ? "record.circle.fill" : "record.circle")
    }
}

private struct MenuBarContent: View {
    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(buttonTitle) { app.toggleRecording() }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(app.phase == .stopping)
        Divider()
        Button("Открыть окно MotionRecord") {
            app.openMainWindow = { openWindow(id: "main") }
            app.showMainWindow()
        }
        Divider()
        Button("Выйти") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var buttonTitle: String {
        switch app.phase {
        case .idle: return "Начать запись"
        case .countdown, .starting: return "Отменить"
        case .recording: return "Остановить запись"
        case .stopping: return "Сохранение…"
        }
    }
}
