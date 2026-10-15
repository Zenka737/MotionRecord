import Carbon.HIToolbox
import AppKit

nonisolated(unsafe) private var hotKeyAction: (@Sendable () -> Void)?

/// Global hotkey via Carbon (works while the app is in the background, needs no Accessibility permission).
@MainActor
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// Registers ⌘⇧R by default. keyCode is a kVK_* virtual key code.
    func register(keyCode: Int = kVK_ANSI_R,
                  modifiers: Int = cmdKey | shiftKey,
                  action: @escaping @Sendable () -> Void) {
        unregister()
        hotKeyAction = action

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { hotKeyAction?() }
            return noErr
        }, 1, &spec, nil, &handlerRef)

        let id = EventHotKeyID(signature: OSType(0x4D52434B) /* 'MRCK' */, id: 1)
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
    }
}
