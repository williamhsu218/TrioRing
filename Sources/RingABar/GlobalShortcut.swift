import AppKit
import Carbon
import Observation

// Shortcut validation and Carbon registration adapted from Status Trio (Apache-2.0).
struct StatusPanelShortcut: Codable, Equatable {
    private static let primaryModifiers = UInt32(cmdKey | controlKey | optionKey)
    private static let supportedModifiers = primaryModifiers | UInt32(shiftKey)
    private static let modifierKeys: Set<UInt32> = [
        UInt32(kVK_Command), UInt32(kVK_RightCommand), UInt32(kVK_Shift), UInt32(kVK_RightShift),
        UInt32(kVK_Option), UInt32(kVK_RightOption), UInt32(kVK_Control), UInt32(kVK_RightControl),
        UInt32(kVK_CapsLock), UInt32(kVK_Function)
    ]

    let keyCode: UInt32
    let modifiers: UInt32

    init?(keyCode: UInt32, modifiers: UInt32) {
        guard keyCode <= 127, !Self.modifierKeys.contains(keyCode),
              modifiers & Self.primaryModifiers != 0, modifiers & ~Self.supportedModifiers == 0 else { return nil }
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init?(event: NSEvent) {
        var modifiers: UInt32 = 0
        if event.modifierFlags.contains(.control) { modifiers |= UInt32(controlKey) }
        if event.modifierFlags.contains(.option) { modifiers |= UInt32(optionKey) }
        if event.modifierFlags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if event.modifierFlags.contains(.command) { modifiers |= UInt32(cmdKey) }
        self.init(keyCode: UInt32(event.keyCode), modifiers: modifiers)
    }

    var isInputMethodConflict: Bool {
        keyCode == UInt32(kVK_Space) && modifiers == UInt32(optionKey)
    }

    private enum CodingKeys: String, CodingKey { case version, keyCode, modifiers }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        let keyCode = try container.decode(UInt32.self, forKey: .keyCode)
        let modifiers = try container.decode(UInt32.self, forKey: .modifiers)
        guard version == 1, let shortcut = Self(keyCode: keyCode, modifiers: modifiers),
              !shortcut.isInputMethodConflict else {
            throw DecodingError.dataCorruptedError(forKey: .keyCode, in: container, debugDescription: "Invalid panel shortcut.")
        }
        self = shortcut
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(1, forKey: .version)
        try container.encode(keyCode, forKey: .keyCode)
        try container.encode(modifiers, forKey: .modifiers)
    }
}

enum ShortcutRegistrationError: Error {
    case conflict, failed
}

@MainActor
protocol ShortcutRegistering: AnyObject {
    func register(_ shortcut: StatusPanelShortcut, action: @escaping @MainActor () -> Void) throws -> UUID
    func unregister(_ token: UUID)
    func stop()
}

@MainActor
@Observable
final class GlobalShortcutController {
    enum Feedback: Equatable {
        case invalid, inputMethodConflict, conflict, failed, restorationFailed
    }

    private(set) var isRecording = false
    private(set) var feedback: Feedback?
    private let preferences: Preferences
    private let backend: any ShortcutRegistering
    private let action: @MainActor () -> Void
    private var token: UUID?
    private var generation: UInt64 = 0
    private var started = false

    var shortcut: StatusPanelShortcut? { preferences.panelShortcut }

    init(preferences: Preferences, backend: any ShortcutRegistering, action: @escaping @MainActor () -> Void) {
        self.preferences = preferences
        self.backend = backend
        self.action = action
    }

    func start() {
        guard !started else { return }
        started = true
        restoreSavedShortcut()
    }

    func stop() {
        started = false
        isRecording = false
        unregister()
        backend.stop()
    }

    func beginRecording() {
        guard started, !isRecording else { return }
        isRecording = true
        feedback = nil
        unregister()
    }

    func cancelRecording() {
        guard isRecording else { return }
        isRecording = false
        feedback = nil
        restoreSavedShortcut()
    }

    func record(_ candidate: StatusPanelShortcut?) {
        guard isRecording else { return }
        guard let candidate else {
            feedback = .invalid
            return
        }
        guard !candidate.isInputMethodConflict else {
            feedback = .inputMethodConflict
            return
        }

        isRecording = false
        do {
            try register(candidate)
            preferences.panelShortcut = candidate
            feedback = nil
        } catch {
            feedback = feedback(for: error)
            restoreSavedShortcut()
        }
    }

    func clearShortcut() {
        unregister()
        preferences.panelShortcut = nil
        isRecording = false
        feedback = nil
    }

    private func restoreSavedShortcut() {
        guard started, token == nil, let shortcut else { return }
        do {
            try register(shortcut)
        } catch {
            feedback = .restorationFailed
        }
    }

    private func register(_ shortcut: StatusPanelShortcut) throws {
        let attempt = generation &+ 1
        let registration = try backend.register(shortcut) { [weak self] in
            guard let self, self.started, !self.isRecording, self.token != nil,
                  self.generation == attempt else { return }
            self.action()
        }
        generation = attempt
        token = registration
    }

    private func unregister() {
        generation &+= 1
        if let token {
            self.token = nil
            backend.unregister(token)
        }
    }

    private func feedback(for error: Error) -> Feedback {
        switch error as? ShortcutRegistrationError {
        case .conflict: .conflict
        default: .failed
        }
    }
}

private struct CarbonCallbackEvent: @unchecked Sendable {
    let reference: EventRef
}

@MainActor
final class CarbonShortcutBackend: ShortcutRegistering {
    private struct Registration {
        let token: UUID
        let reference: EventHotKeyRef
        let action: @MainActor () -> Void
    }

    private static let signature: OSType = 0x5452_484B
    private var handler: EventHandlerRef?
    private var registrations: [UInt32: Registration] = [:]
    private var pressed: Set<UInt32> = []
    private var nextID: UInt32 = 0

    private static let callback: EventHandlerUPP = { _, event, context in
        guard let event, let context else { return OSStatus(eventNotHandledErr) }
        let backend = Unmanaged<CarbonShortcutBackend>.fromOpaque(context).takeUnretainedValue()
        let wrapped = CarbonCallbackEvent(reference: event)
        return MainActor.assumeIsolated { backend.handle(wrapped.reference) }
    }

    func register(_ shortcut: StatusPanelShortcut, action: @escaping @MainActor () -> Void) throws -> UUID {
        try installHandler()
        repeat { nextID &+= 1 } while registrations[nextID] != nil
        let id = EventHotKeyID(signature: Self.signature, id: nextID)
        var reference: EventHotKeyRef?
        let result = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id,
                                         GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &reference)
        guard result == noErr, let reference else {
            throw result == OSStatus(eventHotKeyExistsErr) ? ShortcutRegistrationError.conflict : .failed
        }
        let token = UUID()
        registrations[nextID] = Registration(token: token, reference: reference, action: action)
        return token
    }

    func unregister(_ token: UUID) {
        guard let id = registrations.first(where: { $0.value.token == token })?.key,
              let registration = registrations.removeValue(forKey: id) else { return }
        UnregisterEventHotKey(registration.reference)
        pressed.remove(id)
    }

    func stop() {
        for registration in registrations.values { UnregisterEventHotKey(registration.reference) }
        registrations.removeAll()
        pressed.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    private func installHandler() throws {
        guard handler == nil else { return }
        var kinds = [UInt32(kEventHotKeyPressed), UInt32(kEventHotKeyReleased)].map {
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: $0)
        }
        var reference: EventHandlerRef?
        let result = kinds.withUnsafeMutableBufferPointer {
            InstallEventHandler(GetApplicationEventTarget(), Self.callback, $0.count, $0.baseAddress,
                                Unmanaged.passUnretained(self).toOpaque(), &reference)
        }
        guard result == noErr, let reference else { throw ShortcutRegistrationError.failed }
        handler = reference
    }

    private func handle(_ event: EventRef) -> OSStatus {
        var id = EventHotKeyID()
        guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
              id.signature == Self.signature, let registration = registrations[id.id] else {
            return OSStatus(eventNotHandledErr)
        }

        switch GetEventKind(event) {
        case UInt32(kEventHotKeyPressed):
            if pressed.insert(id.id).inserted { registration.action() }
        case UInt32(kEventHotKeyReleased):
            pressed.remove(id.id)
        default:
            return OSStatus(eventNotHandledErr)
        }
        return noErr
    }
}
