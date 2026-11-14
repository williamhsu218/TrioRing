import AudioToolbox
import CoreAudio
import Foundation
import OSLog

final class AudioMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.willhsu.ring-a-bar.audio", qos: .userInitiated)
    private let onChange: @Sendable (AudioStatus) -> Void
    private let logger = Logger(subsystem: "com.willhsu.ring-a-bar", category: "Audio")
    private let systemObject = AudioObjectID(kAudioObjectSystemObject)
    private let outputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private let nameAddress = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private let transportAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyTransportType,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private let modelUIDAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyModelUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private let volumeAddresses = [
        AudioObjectPropertyAddress(output: kAudioDevicePropertyVolumeScalar),
        AudioObjectPropertyAddress(output: kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
    ]
    private let muteAddress = AudioObjectPropertyAddress(output: kAudioDevicePropertyMute)
    // Runtime-only CoreAudio selectors shared with Status Trio.
    private let listeningModeAddress = AudioObjectPropertyAddress(
        mSelector: 0x6C73_746D, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
    )
    private let listeningSupportAddress = AudioObjectPropertyAddress(
        mSelector: 0x6C73_6D73, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
    )
    private let appleAudioAddress = AudioObjectPropertyAddress(
        mSelector: 0x6961_6170, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
    )

    // All listeners and CoreAudio calls are confined to the serial audio queue.
    private var listeningToSystem = false
    private var observedDevice: AudioDeviceID?
    private var observedAddresses: [AudioObjectPropertyAddress] = []
    private var controlFailed = false
    private lazy var listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.publish()
    }

    init(onChange: @escaping @Sendable (AudioStatus) -> Void) {
        self.onChange = onChange
    }

    func start() {
        queue.async {
            self.listeningToSystem = self.addListener(self.outputAddress, on: self.systemObject)
            self.publish()
        }
    }

    func stop() {
        queue.async {
            self.observeDevice(nil)
            if self.listeningToSystem {
                self.removeListener(self.outputAddress, from: self.systemObject)
                self.listeningToSystem = false
            }
        }
    }

    func refresh() {
        queue.async { self.publish() }
    }

    func setVolume(_ value: Double, on device: AudioDeviceID) {
        guard value.isFinite else { return }
        queue.async {
            defer { self.publish() }
            guard self.defaultDevice() == device,
                  let address = self.volumeControl(on: device).writableAddress,
                  self.defaultDevice() == device else { return }
            self.controlFailed = !self.write(Float32(min(max(value, 0), 1)), to: address, on: device)
        }
    }

    func setMuted(_ muted: Bool, on device: AudioDeviceID) {
        queue.async {
            defer { self.publish() }
            guard self.defaultDevice() == device,
                  self.isSettable(self.muteAddress, on: device) else { return }
            self.controlFailed = !self.write(UInt32(muted ? 1 : 0), to: self.muteAddress, on: device)
        }
    }

    private func defaultDevice() -> AudioDeviceID? {
        defaultDevice(for: .output)
    }

    private func defaultAddress(for direction: AudioDirection) -> AudioObjectPropertyAddress {
        if direction == .output { return outputAddress }
        return AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func defaultDevice(for direction: AudioDirection) -> AudioDeviceID? {
        let device = read(AudioDeviceID(kAudioObjectUnknown), at: defaultAddress(for: direction), on: systemObject)
        return device == kAudioObjectUnknown ? nil : device
    }

    func routes() async -> AudioRoutes {
        await withCheckedContinuation { continuation in
            queue.async {
                let devices = self.audioDevices()
                let input = self.defaultDevice(for: .input)
                let output = self.defaultDevice(for: .output)
                continuation.resume(returning: AudioRoutes(
                    outputs: self.routes(from: devices, direction: .output),
                    inputs: self.routes(from: devices, direction: .input),
                    outputID: output,
                    inputID: input,
                    inputGain: self.readInputGain(on: input),
                    inputMute: self.readInputMute(on: input),
                    airPodsOutput: output.flatMap(self.readAirPodsOutput)
                ))
            }
        }
    }

    private func readAirPodsOutput(_ device: AudioDeviceID) -> AirPodsOutput? {
        let transport = read(UInt32(0), at: transportAddress, on: device)
        guard transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE,
              read(UInt32(0), at: appleAudioAddress, on: device) == 1,
              let uid = deviceUID(device),
              let raw = read(UInt32(0), at: listeningModeAddress, on: device),
              let mask = read(UInt32(0), at: listeningSupportAddress, on: device),
              isSettable(listeningModeAddress, on: device) else { return nil }
        let modes = AirPodsListeningMode.allCases.filter { mask & $0.supportBit != 0 }
        guard modes.count >= 2 else { return nil }
        return AirPodsOutput(deviceID: device, uid: uid, currentMode: AirPodsListeningMode(rawValue: raw),
                             supportedModes: modes)
    }

    func setAirPodsListeningMode(_ mode: AirPodsListeningMode, on target: AirPodsOutput) async -> Bool {
        let accepted: Bool = await withCheckedContinuation { continuation in
            queue.async {
                guard self.defaultDevice() == target.deviceID,
                      let output = self.readAirPodsOutput(target.deviceID), output.uid == target.uid,
                      output.supportedModes.contains(mode), self.defaultDevice() == target.deviceID else {
                    continuation.resume(returning: false)
                    return
                }
                continuation.resume(returning: self.write(mode.rawValue, to: self.listeningModeAddress, on: target.deviceID))
            }
        }
        guard accepted else { return false }
        for _ in 0..<16 {
            do { try await Task.sleep(for: .milliseconds(50)) }
            catch { return false }
            let observed: UInt32? = await withCheckedContinuation { continuation in
                queue.async {
                    let matches = self.defaultDevice() == target.deviceID && self.deviceUID(target.deviceID) == target.uid
                    continuation.resume(returning: matches
                        ? self.read(UInt32(0), at: self.listeningModeAddress, on: target.deviceID) : nil)
                }
            }
            guard let observed else { return false }
            if observed == mode.rawValue { return true }
        }
        return false
    }

    func setInputGain(_ value: Double, on target: AudioInputGain) async -> (accepted: Bool, gain: AudioInputGain?) {
        await withCheckedContinuation { continuation in
            queue.async {
                let device = target.deviceID
                let matchesTarget = {
                    self.defaultDevice(for: .input) == device && self.deviceUID(device) == target.uid
                }
                var accepted = false
                if value.isFinite, matchesTarget(), self.supports(device, direction: .input) {
                    let plan = self.inputGainControl(on: device)
                    let scalar = Float32(min(max(value, 0), 1))
                    var updated: [(AudioObjectPropertyAddress, Float32)] = []
                    for (address, old) in plan.writes {
                        guard matchesTarget(), self.write(scalar, to: address, on: device) else { break }
                        updated.append((address, old))
                    }
                    accepted = !plan.writes.isEmpty && updated.count == plan.writes.count
                    if !accepted {
                        for (address, old) in updated.reversed() {
                            guard matchesTarget() else { break }
                            if self.read(Float32(0), at: address, on: device) == scalar {
                                _ = self.write(old, to: address, on: device)
                            }
                        }
                    }
                }
                continuation.resume(returning: (accepted, self.readInputGain(on: self.defaultDevice(for: .input))))
            }
        }
    }

    private func readInputGain(on device: AudioDeviceID?) -> AudioInputGain? {
        guard let device, let uid = deviceUID(device) else { return nil }
        let control = inputGainControl(on: device)
        return AudioInputGain(deviceID: device, uid: uid, value: control.value, canSet: !control.writes.isEmpty)
    }

    func setInputMuted(_ muted: Bool, on target: AudioInputMute) async -> (accepted: Bool, mute: AudioInputMute?) {
        await withCheckedContinuation { continuation in
            queue.async {
                let accepted = self.applyInputMute(muted, on: target)
                continuation.resume(returning: (accepted, self.readInputMute(on: self.defaultDevice(for: .input))))
            }
        }
    }

    private func applyInputMute(_ muted: Bool, on target: AudioInputMute) -> Bool {
        let device = target.deviceID
        let sameDevice = { self.deviceUID(device) == target.uid }
        let isCurrent = { self.defaultDevice(for: .input) == device && sameDevice() }
        guard isCurrent(), supports(device, direction: .input) else { return false }

        let changes = inputMuteControl(on: device).writes
        let value: UInt32 = muted ? 1 : 0
        guard !changes.isEmpty else { return false }
        var updated: [(AudioObjectPropertyAddress, UInt32)] = []
        for (address, original) in changes {
            guard isCurrent(), original == value || write(value, to: address, on: device) else { break }
            updated.append((address, original))
        }
        if updated.count == changes.count,
           changes.allSatisfy({ read(UInt32(0), at: $0.0, on: device) == value }),
           isCurrent() { return true }

        // A failed mute must not reopen channels that were just silenced.
        // A failed unmute restores only the channels this request changed.
        guard !muted else { return false }
        for (address, original) in updated.reversed() where original != value {
            guard sameDevice() else { break }
            if read(UInt32(0), at: address, on: device) == value {
                _ = write(original, to: address, on: device)
            }
        }
        return false
    }

    private func readInputMute(on device: AudioDeviceID?) -> AudioInputMute? {
        guard let device, let uid = deviceUID(device) else { return nil }
        let control = inputMuteControl(on: device)
        return AudioInputMute(deviceID: device, uid: uid, state: control.state, canSet: !control.writes.isEmpty)
    }

    private func inputMuteControl(on device: AudioDeviceID)
        -> (state: AudioInputMuteState?, writes: [(AudioObjectPropertyAddress, UInt32)]) {
        func address(_ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
            .init(mSelector: kAudioDevicePropertyMute, mScope: kAudioObjectPropertyScopeInput, mElement: element)
        }
        func readValue(_ address: AudioObjectPropertyAddress) -> UInt32? {
            guard let value = read(UInt32(0), at: address, on: device), value <= 1 else { return nil }
            return value
        }

        let main = address(kAudioObjectPropertyElementMain)
        let mainValue = readValue(main)
        let mainState: AudioInputMuteState? = mainValue.map { $0 == 1 ? .muted : .unmuted }
        if let mainValue, isSettable(main, on: device) { return (mainState, [(main, mainValue)]) }

        let count = inputChannelCount(on: device)
        guard count > 0 else { return (mainState, []) }
        let channels = (1...count).map { address(AudioObjectPropertyElement($0)) }
        let values = channels.compactMap(readValue)
        guard values.count == count else { return (mainState, []) }
        let mutedChannels = values.reduce(UInt32(0), +)
        let state: AudioInputMuteState = mutedChannels == 0 ? .unmuted : (mutedChannels == UInt32(count) ? .muted : .partial)
        if channels.allSatisfy({ isSettable($0, on: device) }) { return (state, Array(zip(channels, values))) }
        return (mainState ?? state, [])
    }

    private func inputGainControl(on device: AudioDeviceID)
        -> (value: Double?, writes: [(AudioObjectPropertyAddress, Float32)]) {
        func address(_ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
            .init(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioObjectPropertyScopeInput, mElement: element)
        }
        func scalar(at address: AudioObjectPropertyAddress) -> Float32? {
            guard let value = read(Float32(0), at: address, on: device), (0...1).contains(value) else { return nil }
            return value
        }
        let main = address(kAudioObjectPropertyElementMain)
        let mainScalar = scalar(at: main)
        if let mainScalar, isSettable(main, on: device) { return (Double(mainScalar), [(main, mainScalar)]) }

        let count = inputChannelCount(on: device)
        guard count > 0 else { return (mainScalar.map(Double.init), []) }
        let channels = (1...count).map { address(AudioObjectPropertyElement($0)) }
        let values = channels.compactMap { scalar(at: $0) }
        guard values.count == count else { return (mainScalar.map(Double.init), []) }
        let average = values.reduce(0.0) { $0 + Double($1) } / Double(count)
        if channels.allSatisfy({ isSettable($0, on: device) }) {
            return (average, Array(zip(channels, values)))
        }
        return (mainScalar.map(Double.init) ?? average, [])
    }

    private func inputChannelCount(on device: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioBufferList>.size, size < 65_536 else { return 0 }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, storage) == noErr,
              size >= MemoryLayout<AudioBufferList>.size else { return 0 }
        let list = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
        let maxBuffers = 1 + (Int(size) - MemoryLayout<AudioBufferList>.size) / MemoryLayout<AudioBuffer>.stride
        guard list.pointee.mNumberBuffers <= maxBuffers else { return 0 }
        let count = UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + Int($1.mNumberChannels) }
        return count <= 128 ? count : 0
    }

    func select(_ route: AudioRoute, direction: AudioDirection) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                guard self.audioDevices().contains(route.id),
                      self.deviceUID(route.id) == route.uid,
                      self.supports(route.id, direction: direction) else {
                    continuation.resume(returning: false)
                    return
                }
                if self.defaultDevice(for: direction) == route.id {
                    continuation.resume(returning: true)
                    return
                }
                let address = self.defaultAddress(for: direction)
                let accepted = self.isSettable(address, on: self.systemObject)
                    && self.write(route.id, to: address, on: self.systemObject)
                if direction == .output { self.publish() }
                continuation.resume(returning: accepted)
            }
        }
    }

    private func audioDevices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let stride = UInt32(MemoryLayout<AudioDeviceID>.stride)
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr,
              size > 0, size.isMultiple(of: stride) else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size / stride))
        let result = devices.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, bytes.baseAddress!)
        }
        guard result == noErr, size.isMultiple(of: stride) else { return [] }
        return Array(devices.prefix(Int(size / stride)))
    }

    private func routes(from devices: [AudioDeviceID], direction: AudioDirection) -> [AudioRoute] {
        devices.compactMap { device in
            guard supports(device, direction: direction), let uid = deviceUID(device),
                  let name = deviceName(device) else { return nil }
            let transport = read(UInt32(0), at: transportAddress, on: device)
            return AudioRoute(id: device, uid: uid, name: name,
                              symbol: direction == .output ? deviceSymbol(for: device, transport: transport) : "mic")
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func supports(_ device: AudioDeviceID, direction: AudioDirection) -> Bool {
        let scope = direction == .output ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeInput
        var streams = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams, mScope: scope, mElement: kAudioObjectPropertyElementMain
        )
        let eligible = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceCanBeDefaultDevice, mScope: scope, mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &size) == noErr && size > 0
            && read(UInt32(0), at: eligible, on: device) != 0
    }

    private func deviceUID(_ device: AudioDeviceID) -> String? {
        let address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return read(nil as Unmanaged<CFString>?, at: address, on: device)
            .flatMap { $0 }.map { $0.takeRetainedValue() as String }
    }

    private func deviceName(_ device: AudioDeviceID) -> String? {
        read(nil as Unmanaged<CFString>?, at: nameAddress, on: device)
            .flatMap { $0 }.map { $0.takeRetainedValue() as String }
    }

    private func volumeControl(on device: AudioDeviceID) -> (value: Double?, writableAddress: AudioObjectPropertyAddress?) {
        var readableValue: Double?
        var writableAddress: AudioObjectPropertyAddress?
        for address in volumeAddresses {
            let writable = isSettable(address, on: device)
            if writable && writableAddress == nil {
                writableAddress = address
            }
            guard let scalar = read(Float32(0), at: address, on: device),
                  scalar.isFinite, (0...1).contains(scalar) else { continue }
            if writable {
                return (Double(scalar), address)
            }
            if readableValue == nil {
                readableValue = Double(scalar)
            }
        }
        return (readableValue, writableAddress)
    }

    private func publish() {
        let device = defaultDevice()
        observeDevice(device)
        guard let device else {
            onChange(AudioStatus())
            return
        }

        let name = deviceName(device)
        let volume = volumeControl(on: device)
        let muted = read(UInt32(0), at: muteAddress, on: device).map { $0 != 0 }
        guard defaultDevice() == device else { return }

        let transport = read(UInt32(0), at: transportAddress, on: device)
        onChange(AudioStatus(
            deviceID: device,
            deviceName: name,
            volume: volume.value,
            muted: muted,
            canSetVolume: volume.writableAddress != nil,
            canMute: muted != nil && isSettable(muteAddress, on: device),
            controlFailed: controlFailed,
            isBluetooth: transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE,
            deviceSymbol: deviceSymbol(for: device, transport: transport)
        ))
    }

    private func deviceSymbol(for device: AudioDeviceID, transport: UInt32?) -> String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "laptopcomputer"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "display"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            let model = read(nil as Unmanaged<CFString>?, at: modelUIDAddress, on: device)
                .flatMap { $0 }.map { $0.takeRetainedValue() as String }
            return AirPodsOutput.symbol(forModelUID: model) ?? "headphones"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        default: return "speaker.wave.2.fill"
        }
    }

    private func observeDevice(_ device: AudioDeviceID?) {
        guard device != observedDevice else { return }
        if let observedDevice {
            for address in observedAddresses {
                removeListener(address, from: observedDevice)
            }
        }
        observedAddresses.removeAll()
        observedDevice = device
        controlFailed = false
        if let device {
            observedAddresses = (volumeAddresses + [muteAddress, nameAddress]).filter {
                addListener($0, on: device)
            }
        }
    }

    private func read<Value>(_ initial: Value, at address: AudioObjectPropertyAddress, on device: AudioObjectID) -> Value? {
        var address = address
        var value = initial
        var size = UInt32(MemoryLayout<Value>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        return status == noErr && size == MemoryLayout<Value>.size ? value : nil
    }

    private func isSettable(_ address: AudioObjectPropertyAddress, on device: AudioObjectID) -> Bool {
        var address = address
        var settable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    private func write<Value>(_ value: Value, to address: AudioObjectPropertyAddress, on device: AudioObjectID) -> Bool {
        var address = address
        var value = value
        let size = UInt32(MemoryLayout<Value>.size)
        let status = withUnsafePointer(to: &value) {
            AudioObjectSetPropertyData(device, &address, 0, nil, size, $0)
        }
        if status != noErr {
            logger.error("Audio control write failed (OSStatus \(status, privacy: .public))")
        }
        return status == noErr
    }

    private func addListener(_ address: AudioObjectPropertyAddress, on device: AudioObjectID) -> Bool {
        var address = address
        guard AudioObjectHasProperty(device, &address) else { return false }
        return AudioObjectAddPropertyListenerBlock(device, &address, queue, listener) == noErr
    }

    private func removeListener(_ address: AudioObjectPropertyAddress, from device: AudioObjectID) {
        var address = address
        _ = AudioObjectRemovePropertyListenerBlock(device, &address, queue, listener)
    }
}

private extension AudioObjectPropertyAddress {
    init(output selector: AudioObjectPropertySelector) {
        self.init(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
