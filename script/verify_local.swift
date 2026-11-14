// Run with: swift script/verify_local.swift
// Exercises the installed app through AX and real mouse/keyboard events.
// It temporarily mutes audio, changes the output level, and restores both.
// Add --summary-only to verify the visible summary without changing audio.
// Add --keyboard-only to verify Tab and Space with macOS Keyboard navigation enabled.
import AppKit
import ApplicationServices
import CoreAudio
import Foundation

struct VerificationError: Error, CustomStringConvertible {
    let description: String
}

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw VerificationError(description: message) }
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    return result == .success ? value : nil
}

func descendants(_ element: AXUIElement) -> [AXUIElement] {
    var result: [AXUIElement] = []
    func visit(_ node: AXUIElement) {
        guard !result.contains(where: { CFEqual($0, node) }) else { return }
        result.append(node)
        for key in ["AXChildren", "AXWindows", "AXExtrasMenuBar"] {
            guard let value = attribute(node, key) else { continue }
            if CFGetTypeID(value) == AXUIElementGetTypeID() {
                visit(value as! AXUIElement)
            } else if let children = value as? [AXUIElement] {
                children.forEach(visit)
            }
        }
    }
    visit(element)
    return result
}

func find(_ identifier: String, in root: AXUIElement) throws -> AXUIElement {
    guard let element = descendants(root).first(where: {
        attribute($0, "AXIdentifier") as? String == identifier
    }) else { throw VerificationError(description: "Missing control: " + identifier) }
    return element
}

func frame(of element: AXUIElement) throws -> CGRect {
    guard let origin = attribute(element, "AXPosition"),
          let dimensions = attribute(element, "AXSize") else {
        throw VerificationError(description: "Control has no screen bounds")
    }
    var point = CGPoint.zero
    var size = CGSize.zero
    AXValueGetValue(origin as! AXValue, .cgPoint, &point)
    AXValueGetValue(dimensions as! AXValue, .cgSize, &size)
    return CGRect(origin: point, size: size)
}

func center(of element: AXUIElement) throws -> CGPoint {
    let bounds = try frame(of: element)
    return CGPoint(x: bounds.midX, y: bounds.midY)
}

func click(_ element: AXUIElement) throws {
    clickPoint(try center(of: element))
}

func clickPoint(_ point: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.02)
    for type: CGEventType in [.leftMouseDown, .leftMouseUp] {
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)!
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.025)
    }
}

func dragSlider(_ slider: AXUIElement, to fraction: Double) throws {
    guard let handle = descendants(slider).first(where: { attribute($0, "AXRole") as? String == "AXValueIndicator" }) else {
        throw VerificationError(description: "Slider has no thumb")
    }
    var origin = CGPoint.zero
    var size = CGSize.zero
    var thumbOrigin = CGPoint.zero
    var thumbSize = CGSize.zero
    AXValueGetValue(attribute(slider, "AXPosition") as! AXValue, .cgPoint, &origin)
    AXValueGetValue(attribute(slider, "AXSize") as! AXValue, .cgSize, &size)
    AXValueGetValue(attribute(handle, "AXPosition") as! AXValue, .cgPoint, &thumbOrigin)
    AXValueGetValue(attribute(handle, "AXSize") as! AXValue, .cgSize, &thumbSize)
    let start = CGPoint(x: thumbOrigin.x + thumbSize.width / 2, y: thumbOrigin.y + thumbSize.height / 2)
    let end = CGPoint(x: origin.x + thumbSize.width / 2 + (size.width - thumbSize.width) * fraction, y: start.y)
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: start, mouseButton: .left)?.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.03)
    let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left)
    down?.setIntegerValueField(.mouseEventClickState, value: 1)
    down?.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.03)
    for step in 1...10 {
        let point = CGPoint(x: start.x + (end.x - start.x) * Double(step) / 10, y: start.y)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.03)
    }
    let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left)
    up?.setIntegerValueField(.mouseEventClickState, value: 1)
    up?.post(tap: .cghidEventTap)
}

func panelVisible(_ root: AXUIElement) -> Bool {
    descendants(root).contains {
        attribute($0, "AXIdentifier") as? String == "RingABar.panel"
            || attribute($0, "AXRole") as? String == "AXPopover"
    }
}

func summaryControlsVisible(_ root: AXUIElement, controls: [String]) -> Bool {
    guard let panel = try? find("RingABar.panel", in: root),
          let scrollArea = descendants(panel).first(where: { attribute($0, "AXRole") as? String == "AXScrollArea" }),
          let viewport = try? frame(of: scrollArea) else { return false }
    return controls.allSatisfy { id in
        guard let control = try? find(id, in: scrollArea),
              let bounds = try? frame(of: control) else { return false }
        return bounds.height > 0 && bounds.minY >= viewport.minY - 1 && bounds.maxY <= viewport.maxY + 1
    }
}

func key(_ code: CGKeyCode, modifiers: CGEventFlags = []) {
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
        event?.flags = modifiers
        event?.post(tap: .cghidEventTap)
    }
}

func closeSettings(_ root: AXUIElement) throws {
    let settings = try find("RingABar.settingsWindow", in: root)
    guard let close = attribute(settings, "AXCloseButton") else {
        throw VerificationError(description: "Settings has no close button")
    }
    try require(AXUIElementPerformAction(close as! AXUIElement, kAXPressAction as CFString) == .success, "Could not close settings")
    try waitFor("settings window closes") { (try? find("RingABar.settingsWindow", in: root)) == nil }
}

func waitFor(_ message: String, _ condition: () -> Bool) throws {
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
        if condition() { return }
        Thread.sleep(forTimeInterval: 0.05)
    }
    throw VerificationError(description: "Timed out: " + message)
}

func verifyKeyboard(_ root: AXUIElement, controls: [String]) throws {
    func focusedIdentifier() -> String? {
        guard let value = attribute(root, "AXFocusedUIElement"), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return attribute(value as! AXUIElement, "AXIdentifier") as? String
    }

    func focus(_ identifier: String) throws {
        for _ in 0..<64 {
            if focusedIdentifier() == identifier { return }
            key(48)
            Thread.sleep(forTimeInterval: 0.08)
        }
        throw VerificationError(description: "Could not tab to \(identifier). Check macOS Keyboard navigation.")
    }

    try click(find("RingABar.statusItem", in: root))
    try waitFor("panel opens for keyboard navigation") { panelVisible(root) }
    defer { if panelVisible(root) { key(53) } }

    let battery = "RingABar.batteryDetails"
    let back = "RingABar.management.back"
    if controls.contains(battery) {
        try focus(battery)
        key(48)
        try waitFor("Tab advances past Battery") { focusedIdentifier() != battery }
        key(48, modifiers: .maskShift)
        try waitFor("Shift-Tab restores Battery focus") { focusedIdentifier() == battery }
        key(49)
        try waitFor("Space opens Battery and focuses Back") { focusedIdentifier() == back }
        key(49)
        try waitFor("Space on Back restores Battery focus") { focusedIdentifier() == battery }
        key(49)
        try waitFor("Battery detail again") { focusedIdentifier() == back }
        key(33, modifiers: .maskCommand)
        try waitFor("Command-[ restores Battery focus") { focusedIdentifier() == battery }
        print("PASS Tab, Shift-Tab, Space, and focus restoration on Battery")
    }

    let audio = "RingABar.audio.toggleDevices"
    if controls.contains(audio) {
        try focus(audio)
        let disclosure = try find(audio, in: root)
        if attribute(disclosure, "AXValue") as? String != "Expanded" {
            key(49)
            try waitFor("Space expands Audio") { attribute(disclosure, "AXValue") as? String == "Expanded" }
        }
        let details = "RingABar.audioDetails"
        try focus(details)
        key(49)
        try waitFor("Space opens Output and focuses Back") { focusedIdentifier() == back }
        try require((try? find("RingABar.audio.inputDisclosure", in: root)) == nil,
                    "Audio details opened on Input")
        let selector = try frame(of: find("RingABar.audio.direction", in: root))
        clickPoint(CGPoint(x: selector.minX + selector.width * 0.75, y: selector.midY))
        try waitFor("Output detail switches to Input") { (try? find("RingABar.audio.inputDisclosure", in: root)) != nil }
        key(33, modifiers: .maskCommand)
        try waitFor("Command-[ restores the Audio details icon") { focusedIdentifier() == details }
        try require((try? find("RingABar.audio.outputDevices", in: root)) == nil
                    && (try? find("RingABar.audio.inputDevices", in: root)) == nil,
                    "Audio shortcuts still occupy a separate row")

        key(49)
        try waitFor("Space reopens Audio details on Output") {
            focusedIdentifier() == back && (try? find("RingABar.audio.inputDisclosure", in: root)) == nil
        }
        key(49)
        try waitFor("Back restores the Audio details icon and keeps audio expanded") {
            guard let button = try? find(audio, in: root) else { return false }
            return focusedIdentifier() == details && attribute(button, "AXValue") as? String == "Expanded"
        }
        print("PASS compact Audio entry, Input and Output, and keyboard return focus")
    }

    try focus("RingABar.openSettings")
    key(53)
    try waitFor("Escape closes the panel") { !panelVisible(root) }
    try click(find("RingABar.statusItem", in: root))
    try waitFor("panel reopens with no leftover focus") {
        panelVisible(root) && [nil, "RingABar.panel"].contains(focusedIdentifier())
    }
    key(49)
    Thread.sleep(forTimeInterval: 0.15)
    try require(panelVisible(root) && [nil, "RingABar.panel"].contains(focusedIdentifier()),
                "Space activated a control before any focus was chosen")
    try focus("RingABar.openSettings")
    key(49)
    try waitFor("Space opens Settings") { (try? find("RingABar.settingsWindow", in: root)) != nil }
    try closeSettings(root)
    print("PASS focus resets on close and Settings opens with Space")
}

func audioAddress(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func audioRead<T>(_ initial: T, _ selector: AudioObjectPropertySelector, _ object: AudioObjectID, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput) -> T? {
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    var address = audioAddress(selector, scope: scope)
    let status = withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
    }
    return status == noErr ? value : nil
}

func defaultOutput() -> AudioDeviceID? {
    audioRead(AudioDeviceID(0), kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(kAudioObjectSystemObject), scope: kAudioObjectPropertyScopeGlobal)
}

func restoreAudio(device: AudioDeviceID, volume: Float32, mute: UInt32) -> Bool {
    guard defaultOutput() == device else { return false }
    func write<T>(_ value: T, _ selector: AudioObjectPropertySelector) {
        var value = value
        var address = audioAddress(selector, scope: kAudioObjectPropertyScopeOutput)
        _ = withUnsafePointer(to: &value) {
            AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<T>.size), $0)
        }
    }
    write(volume, kAudioDevicePropertyVolumeScalar)
    write(mute, kAudioDevicePropertyMute)
    let actual = audioRead(Float32(0), kAudioDevicePropertyVolumeScalar, device)
    return actual.map { abs($0 - volume) < 0.001 } == true
        && audioRead(UInt32(0), kAudioDevicePropertyMute, device) == mute
}

var baseline: (device: AudioDeviceID, volume: Float32, mute: UInt32)?

do {
    try require(AXIsProcessTrusted(), "The invoking terminal needs Accessibility authorization.")
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.willhsu.ring-a-bar").first,
          app.bundleURL?.path == "/Applications/TrioRing.app" else {
        throw VerificationError(description: "Launch /Applications/TrioRing.app first.")
    }
    let root = AXUIElementCreateApplication(app.processIdentifier)
    if panelVisible(root) {
        try click(find("RingABar.statusItem", in: root))
        try waitFor("initial close") { !panelVisible(root) }
    }

    let defaults = UserDefaults(suiteName: "com.willhsu.ring-a-bar")
    let hidden = Set(defaults?.stringArray(forKey: "panel.hiddenSections") ?? [])
    let controls: [String] = [
        ("battery", "RingABar.batteryDetails"),
        ("network", "RingABar.networkDetails"),
        ("audio", "RingABar.audio.toggleDevices")
    ].compactMap { section, id in hidden.contains(section) ? nil : id }
    if CommandLine.arguments.contains("--keyboard-only") {
        try verifyKeyboard(root, controls: controls)
        exit(0)
    }
    let summaryOnly = CommandLine.arguments.contains("--summary-only")
    try click(find("RingABar.statusItem", in: root))
    try waitFor("summary rows fit above the footer") { summaryControlsVisible(root, controls: controls) }
    try click(find("RingABar.statusItem", in: root))
    try waitFor("summary closes") { !panelVisible(root) }
    print("PASS enabled summary rows fit in the visible viewport")

    for _ in 0..<20 {
        try click(find("RingABar.statusItem", in: root))
        try waitFor("reopened summary rows fit above the footer") { summaryControlsVisible(root, controls: controls) }
        try click(find("RingABar.statusItem", in: root))
        try waitFor("same icon closes panel") { !panelVisible(root) }
    }
    print("PASS 20 real single-click open/close cycles with visible summary rows")
    if summaryOnly { exit(0) }

    try click(find("RingABar.statusItem", in: root))
    try waitFor("open for Escape") { panelVisible(root) }
    key(53)
    try waitFor("Escape closes panel") { !panelVisible(root) }
    print("PASS Escape closes panel")

    try click(find("RingABar.statusItem", in: root))
    try waitFor("open for outside click") { panelVisible(root) }
    let item = try find("RingABar.statusItem", in: root)
    var itemOrigin = CGPoint.zero
    AXValueGetValue(attribute(item, "AXPosition") as! AXValue, .cgPoint, &itemOrigin)
    clickPoint(CGPoint(x: itemOrigin.x - 200, y: itemOrigin.y + 12))
    try waitFor("outside click closes panel") { !panelVisible(root) }
    print("PASS outside click closes panel")

    try click(find("RingABar.statusItem", in: root))
    try waitFor("open for audio controls") { panelVisible(root) }
    guard let device = defaultOutput(),
          let volume = audioRead(Float32(0), kAudioDevicePropertyVolumeScalar, device),
          let mute = audioRead(UInt32(0), kAudioDevicePropertyMute, device) else {
        throw VerificationError(description: "Default output needs main volume and mute controls for this hardware test.")
    }
    baseline = (device, volume, mute)
    if mute == 0 {
        try click(find("RingABar.mute", in: root))
        try waitFor("mute before volume test") { audioRead(UInt32(0), kAudioDevicePropertyMute, device) == 1 }
    }

    let testLevel = volume < 0.05 ? 0.05 : Double(volume) - 0.05
    let slider = try find("RingABar.volume", in: root)
    try require(AXUIElementSetAttributeValue(slider, kAXValueAttribute as CFString, testLevel as CFNumber) == .success, "Slider rejected value")
    try waitFor("system volume follows slider") {
        audioRead(Float32(0), kAudioDevicePropertyVolumeScalar, device).map { abs(Double($0) - testLevel) < 0.002 } == true
    }
    print("PASS slider changes real CoreAudio volume")

    try waitFor("slider displays the requested volume before dragging") {
        (attribute(slider, "AXValue") as? Double).map { abs($0 - testLevel) < 0.002 } == true
    }
    try dragSlider(find("RingABar.volume", in: root), to: 0.10)
    try waitFor("drag writes system volume") {
        audioRead(Float32(0), kAudioDevicePropertyVolumeScalar, device).map { abs($0 - 0.10) < 0.015 } == true
    }
    print("PASS real mouse drag changes CoreAudio volume")

    if UserDefaults(suiteName: "com.willhsu.ring-a-bar")?.object(forKey: "panel.scrollToAdjustVolume") as? Bool != false {
        let point = try center(of: find("RingABar.volume", in: root))
        guard let prior = audioRead(Float32(0), kAudioDevicePropertyVolumeScalar, device),
              let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0) else {
            throw VerificationError(description: "Could not prepare scroll-wheel test")
        }
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.03)
        event.location = point
        event.post(tap: .cghidEventTap)
        try waitFor("scroll wheel changes system volume") {
            audioRead(Float32(0), kAudioDevicePropertyVolumeScalar, device).map { abs($0 - prior - 1.0 / 16) < 0.003 } == true
        }
        print("PASS panel scroll wheel changes real CoreAudio volume")
    }

    let zero = 0 as CFNumber
    try require(AXUIElementSetAttributeValue(try find("RingABar.volume", in: root), kAXValueAttribute as CFString, zero) == .success, "Slider rejected zero")
    try waitFor("zero volume before unmute test") { audioRead(Float32(1), kAudioDevicePropertyVolumeScalar, device) == 0 }
    try click(find("RingABar.mute", in: root))
    try waitFor("unmute button") { audioRead(UInt32(1), kAudioDevicePropertyMute, device) == 0 }
    try click(find("RingABar.mute", in: root))
    try waitFor("mute button") { audioRead(UInt32(0), kAudioDevicePropertyMute, device) == 1 }
    print("PASS mute and unmute buttons change real CoreAudio mute")

    try require(restoreAudio(device: device, volume: volume, mute: mute), "Audio restoration failed")
    baseline = nil
    try waitFor("panel receives external volume update") {
        let slider = try? find("RingABar.volume", in: root)
        return slider.flatMap { attribute($0, "AXValue") as? Double }.map { abs($0 - Double(volume)) < 0.002 } == true
    }
    print("PASS original volume/mute restored and panel synchronized")
    try click(find("RingABar.statusItem", in: root))
    try waitFor("final close") { !panelVisible(root) }

    try click(find("RingABar.statusItem", in: root))
    try waitFor("open for settings entry") { panelVisible(root) }
    // AppKit exposes a nonactivating panel before its initial hit regions settle.
    Thread.sleep(forTimeInterval: 0.15)
    try click(find("RingABar.openSettings", in: root))
    try waitFor("settings opens from gear") { (try? find("RingABar.settingsWindow", in: root)) != nil }
    try require(!panelVisible(root), "Status panel should close when settings opens")
    print("PASS footer settings opens a separate window")

    if (try? find("RingABar.settings.icon.page.top", in: root)) == nil {
        try click(find("RingABar.settings.section.icon", in: root))
    }
    try click(find("RingABar.settings.icon.page.top", in: root))
    try waitFor("top arc settings visible") { (try? find("RingABar.settings.batteryColors", in: root)) != nil }
    let toggle = try find("RingABar.settings.batteryColors", in: root)
    guard let colorValue = attribute(toggle, "AXValue") as? NSNumber else {
        throw VerificationError(description: "Could not read battery colors switch")
    }
    let startingColorValue = colorValue.intValue
    guard AXUIElementPerformAction(toggle, kAXPressAction as CFString) == .success else {
        throw VerificationError(description: "Could not press battery colors switch")
    }
    try waitFor("battery colors preference changes") {
        (attribute(toggle, "AXValue") as? NSNumber)?.intValue == 1 - startingColorValue
    }
    guard AXUIElementPerformAction(toggle, kAXPressAction as CFString) == .success else {
        throw VerificationError(description: "Could not press battery colors switch")
    }
    try waitFor("battery colors preference restored") {
        (attribute(toggle, "AXValue") as? NSNumber)?.intValue == startingColorValue
    }
    print("PASS battery colors preference changes and restores")
    try closeSettings(root)

    try click(find("RingABar.statusItem", in: root))
    try waitFor("open for settings shortcut") { panelVisible(root) }
    key(43, modifiers: .maskCommand)
    try waitFor("Command-comma opens settings") { (try? find("RingABar.settingsWindow", in: root)) != nil }
    print("PASS Command-comma opens settings")
    try closeSettings(root)
} catch {
    if let baseline {
        let restored = restoreAudio(device: baseline.device, volume: baseline.volume, mute: baseline.mute)
        print(restored ? "Restored original audio after failure" : "ATTENTION: output device changed or original audio could not be restored")
    }
    fputs("FAIL \(error)\n", stderr)
    exit(1)
}
