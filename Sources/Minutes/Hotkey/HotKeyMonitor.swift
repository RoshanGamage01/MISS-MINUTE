import AppKit
import Carbon
import MinutesCore

/// Holds hotkey callbacks for the Carbon C trampoline (process-wide).
private enum HotKeyTrampoline {
    static let lock = NSLock()
    static var handlers: [UInt32: () -> Void] = [:]
    static let signature = OSType(0x4D4E5453) // 'MNTS'
}

private func minutesHotKeyEventHandler(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr, hotKeyID.signature == HotKeyTrampoline.signature else {
        return OSStatus(eventNotHandledErr)
    }
    HotKeyTrampoline.lock.lock()
    let handler = HotKeyTrampoline.handlers[hotKeyID.id]
    HotKeyTrampoline.lock.unlock()
    guard let handler else { return OSStatus(eventNotHandledErr) }
    DispatchQueue.main.async {
        handler()
    }
    return noErr
}

/// Registers global hotkeys via Carbon (no Accessibility permission required).
@MainActor
final class HotKeyMonitor {
    struct Binding {
        var id: UInt32
        var setting: () -> HotKeySetting
        var action: () -> Void
    }

    private var bindings: [Binding] = []
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var handlerRef: EventHandlerRef?

    func add(id: UInt32, setting: @escaping () -> HotKeySetting, action: @escaping () -> Void) {
        bindings.removeAll { $0.id == id }
        bindings.append(Binding(id: id, setting: setting, action: action))
    }

    func register() {
        unregister()

        if handlerRef == nil {
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )
            let installStatus = InstallEventHandler(
                GetApplicationEventTarget(),
                minutesHotKeyEventHandler,
                1,
                &eventType,
                nil,
                &handlerRef
            )
            if installStatus != noErr {
                print("Miss Minute: failed to install hotkey handler (\(installStatus))")
            }
        }

        HotKeyTrampoline.lock.lock()
        HotKeyTrampoline.handlers = Dictionary(uniqueKeysWithValues: bindings.map { ($0.id, $0.action) })
        HotKeyTrampoline.lock.unlock()

        for binding in bindings {
            let setting = binding.setting()
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: HotKeyTrampoline.signature, id: binding.id)
            let status = RegisterEventHotKey(setting.keyCode, setting.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                hotKeyRefs.append(ref)
            } else {
                print("Miss Minute: failed to register hotkey \(setting.displayString) (\(status))")
            }
        }
    }

    func unregister() {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
    }
}
