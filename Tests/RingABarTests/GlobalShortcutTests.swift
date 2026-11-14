import Carbon
import Foundation
import Testing
@testable import RingABar

@MainActor
struct GlobalShortcutTests {
    private let first = StatusPanelShortcut(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(controlKey | optionKey))!
    private let second = StatusPanelShortcut(keyCode: UInt32(kVK_ANSI_Y), modifiers: UInt32(controlKey | optionKey))!

    @Test func validatesAndLoadsVersionedData() throws {
        #expect(StatusPanelShortcut(keyCode: 128, modifiers: UInt32(cmdKey)) == nil)
        #expect(StatusPanelShortcut(keyCode: UInt32(kVK_Command), modifiers: UInt32(cmdKey)) == nil)
        #expect(StatusPanelShortcut(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(shiftKey)) == nil)
        let data = try JSONEncoder().encode(first)
        #expect(try JSONDecoder().decode(StatusPanelShortcut.self, from: data) == first)

        let suite = "TrioRingTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        Preferences(defaults: defaults).panelShortcut = first
        #expect(Preferences(defaults: defaults).panelShortcut == first)
        defaults.set(Data(#"{"version":2,"keyCode":17,"modifiers":4096}"#.utf8), forKey: "general.panelShortcut")
        #expect(Preferences(defaults: defaults).panelShortcut == nil)
    }

    @Test func cancellationAndReplacementIgnoreOldCallbacks() throws {
        let suite = "TrioRingTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        preferences.panelShortcut = first
        let backend = FakeShortcutBackend()
        var activations = 0
        let controller = GlobalShortcutController(preferences: preferences, backend: backend) { activations += 1 }
        controller.start()
        let staleAction = try #require(backend.lastAction)
        controller.beginRecording()
        staleAction()
        #expect(activations == 0)
        controller.cancelRecording()
        staleAction()
        #expect(activations == 0)
        backend.lastAction?()
        #expect(activations == 1)

        controller.beginRecording()
        controller.record(second)
        #expect(preferences.panelShortcut == second)
        backend.lastAction?()
        #expect(activations == 2)
        controller.clearShortcut()
        #expect(preferences.panelShortcut == nil)
        backend.lastAction?()
        #expect(activations == 2)
    }

    @Test func invalidAndConflictingCandidatesKeepSavedShortcut() throws {
        let suite = "TrioRingTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        preferences.panelShortcut = first
        let backend = FakeShortcutBackend()
        let controller = GlobalShortcutController(preferences: preferences, backend: backend) {}
        controller.start()
        controller.beginRecording()
        controller.record(StatusPanelShortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)))
        #expect(controller.feedback == .inputMethodConflict)
        #expect(controller.isRecording)
        #expect(preferences.panelShortcut == first)
        controller.record(nil)
        #expect(controller.feedback == .invalid)

        backend.blocked = [second]
        controller.record(second)
        #expect(controller.feedback == .conflict)
        #expect(!controller.isRecording)
        #expect(backend.activeShortcut == first)
        #expect(preferences.panelShortcut == first)

        controller.beginRecording()
        backend.blocked = [first]
        controller.cancelRecording()
        #expect(controller.feedback == .restorationFailed)
        #expect(backend.activeShortcut == nil)
        #expect(preferences.panelShortcut == first)
    }
}

@MainActor
private final class FakeShortcutBackend: ShortcutRegistering {
    var blocked: [StatusPanelShortcut] = []
    private(set) var lastAction: (@MainActor () -> Void)?
    private(set) var activeShortcut: StatusPanelShortcut?

    func register(_ shortcut: StatusPanelShortcut, action: @escaping @MainActor () -> Void) throws -> UUID {
        guard !blocked.contains(shortcut) else { throw ShortcutRegistrationError.conflict }
        lastAction = action
        activeShortcut = shortcut
        return UUID()
    }

    func unregister(_ token: UUID) { activeShortcut = nil }
    func stop() { activeShortcut = nil }
}
