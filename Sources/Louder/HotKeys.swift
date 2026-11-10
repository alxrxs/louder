import os
import Carbon.HIToolbox

/// System-wide shortcuts through Carbon's hot key API, which unlike an event tap needs no
/// Accessibility permission.
@MainActor final class HotKeys {
    struct Shortcut {
        let keyCode: Int
        let modifiers: Int
        let display: String
    }

    static let controlOptionCommand = controlKey | optionKey | cmdKey
    static let toggle = Shortcut(keyCode: kVK_ANSI_L, modifiers: controlOptionCommand, display: "⌃⌥⌘L")
    static let louder = Shortcut(keyCode: kVK_UpArrow, modifiers: controlOptionCommand, display: "⌃⌥⌘↑")
    static let quieter = Shortcut(keyCode: kVK_DownArrow, modifiers: controlOptionCommand, display: "⌃⌥⌘↓")

    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, context in
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, let context else { return OSStatus(eventNotHandledErr) }
            // Carbon delivers hot keys on the main thread.
            MainActor.assumeIsolated {
                Unmanaged<HotKeys>.fromOpaque(context).takeUnretainedValue().actions[id.id]?()
            }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    func register(_ shortcut: Shortcut, action: @escaping () -> Void) {
        let id = UInt32(actions.count + 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), UInt32(shortcut.modifiers), EventHotKeyID(signature: OSType(0x4C4F5544), id: id), GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr, let ref else {
            Logger.louder.error("Couldn't register \(shortcut.display, privacy: .public) (\(status)); another app may own it")
            return
        }
        actions[id] = action
        refs.append(ref)
    }
}
