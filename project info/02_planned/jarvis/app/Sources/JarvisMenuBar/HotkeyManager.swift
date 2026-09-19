import Carbon.HIToolbox
import Foundation

/// Errors raised by `HotkeyManager` when registering a Carbon hotkey fails.
public enum HotkeyManagerError: Error, Equatable, Sendable {
    case eventHandlerInstallFailed(OSStatus)
    case registerFailed(OSStatus)
}

/// Carbon `RegisterEventHotKey` wrapper.
///
/// Carbon is the only public macOS API that **captures** a global hotkey (so
/// the keypress does not leak to the frontmost app). The newer
/// `NSEvent.addGlobalMonitorForEvents` is observer-only — it cannot swallow
/// the event, and the frontmost app still receives the keystroke.
///
/// The manager owns a single registered hotkey at a time. Calling `register`
/// twice replaces the prior registration. `unregister` is idempotent and
/// safe to call from any thread.
@MainActor
public final class HotkeyManager {
    public typealias Handler = @MainActor () -> Void

    /// Singleton — the app registers at most one global hotkey at startup.
    public static let shared = HotkeyManager()

    private var handler: Handler?
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var hotKeyID: EventHotKeyID = EventHotKeyID(signature: 0x4A525653, id: 1) // 'JRVS'

    private init() {}

    /// Installs the Carbon event handler and registers a hotkey with the
    /// given virtual key code and modifier mask (the `cmdKey | shiftKey`
    /// family of flags from `Carbon.HIToolbox.Events`). The handler is
    /// invoked on the main actor when the hotkey is pressed.
    ///
    /// Registering again replaces the previously registered hotkey without
    /// leaking the Carbon refcount.
    public func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping Handler) throws {
        // Tear down any prior registration so we never leak an EventHotKeyRef
        // or double-register (Carbon returns `eventHotKeyExistsErr` in that case).
        if hotKeyRef != nil || eventHandler != nil {
            unregister()
        }

        self.handler = handler

        // Install a single keyboard event handler for kEventClassKeyboard /
        // kEventHotKeyPressed. The closure is `@convention(c)` so it can be
        // passed to Carbon's C API; it pulls the registered closure out of
        // the manager via `Unmanaged` so it can call back into Swift.
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, eventRef, userData) -> OSStatus in
                guard let eventRef, let userData else { return noErr }
                var hotKeyIDLocal = EventHotKeyID()
                let paramStatus = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyIDLocal
                )
                guard paramStatus == noErr else { return paramStatus }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                manager.dispatchHandler(for: hotKeyIDLocal)
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &eventHandler
        )
        guard installStatus == noErr else {
            self.handler = nil
            self.eventHandler = nil
            throw HotkeyManagerError.eventHandlerInstallFailed(installStatus)
        }

        var localRef: EventHotKeyRef?
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &localRef
        )
        guard registerStatus == noErr, let localRef else {
            if let eventHandler {
                RemoveEventHandler(eventHandler)
            }
            self.eventHandler = nil
            self.handler = nil
            throw HotkeyManagerError.registerFailed(registerStatus)
        }
        self.hotKeyRef = localRef
    }

    /// Removes the registered hotkey and event handler. Safe to call when
    /// nothing is registered (no-op).
    public func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        self.handler = nil
    }

    /// Dispatches the registered closure for a hotkey event whose ID matches
    /// our registered ID. Called from the Carbon event callback; the manager
    /// is main-actor-isolated so we can hop straight into the handler.
    private func dispatchHandler(for eventID: EventHotKeyID) {
        // The manager only ever registers one hotkey at a time; compare both
        // signature and id so a stale Carbon event delivered during teardown
        // (or a system hotkey) is ignored.
        guard eventID.signature == hotKeyID.signature, eventID.id == hotKeyID.id else { return }
        guard let handler else { return }
        handler()
    }
}
