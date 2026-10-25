import AppKit
import Carbon
import MinutesCore

/// Holds the hotkey callback for the Carbon C trampoline (process-wide; one hotkey at a time).
private enum HotKeyTrampoline {
    static let lock = NSLock()
    static var handler: (() -> Void)?
    static let signature = OSType(0x4D4E5453) // 'MNTS'
    static let id: UInt32 = 1
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
    guard status == noErr,
          hotKeyID.signature == HotKeyTrampoline.signature,
          hotKeyID.id == HotKeyTrampoline.id
    else {
        return OSStatus(eventNotHandledErr)
    }
    HotKeyTrampoline.lock.lock()
    let handler = HotKeyTrampoline.handler
    HotKeyTrampoline.lock.unlock()
    DispatchQueue.main.async {
        handler?()
    }
    return noErr
}

/// Registers a global hotkey via Carbon (no Accessibility permission required).
@MainActor
final class HotKeyMonitor {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let settings: () -> HotKeySetting
    private let onHotKey: () -> Void

    init(settings: @escaping () -> HotKeySetting, onHotKey: @escaping () -> Void) {
        self.settings = settings
        self.onHotKey = onHotKey
    }

    func register() {
        unregister()

        HotKeyTrampoline.lock.lock()
        HotKeyTrampoline.handler = onHotKey
        HotKeyTrampoline.lock.unlock()

        let setting = settings()
        var hotKeyID = EventHotKeyID(signature: HotKeyTrampoline.signature, id: HotKeyTrampoline.id)
        let registerStatus = RegisterEventHotKey(
            setting.keyCode,
            setting.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard registerStatus == noErr else {
            print("Minutes: failed to register hotkey (\(registerStatus))")
            return
        }

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
            print("Minutes: failed to install hotkey handler (\(installStatus))")
        }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
        HotKeyTrampoline.lock.lock()
        HotKeyTrampoline.handler = nil
        HotKeyTrampoline.lock.unlock()
    }
}
