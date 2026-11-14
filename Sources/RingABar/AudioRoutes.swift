import Foundation

enum AudioDirection: String, CaseIterable, Identifiable, Sendable {
    case output, input
    var id: Self { self }
    var title: String {
        switch self {
        case .output: String(localized: "Output")
        case .input: String(localized: "Input")
        }
    }
}

struct AudioRoute: Identifiable, Equatable, Sendable {
    let id: UInt32
    let uid: String
    let name: String
    let symbol: String
}

struct AudioInputGain: Equatable, Sendable {
    let deviceID: UInt32
    let uid: String
    let value: Double?
    let canSet: Bool
}

enum AudioInputMuteState: Equatable, Sendable {
    case muted, unmuted, partial
}

struct AudioInputMute: Equatable, Sendable {
    let deviceID: UInt32
    let uid: String
    let state: AudioInputMuteState?
    let canSet: Bool
}

struct AudioRoutes: Sendable {
    let outputs: [AudioRoute]
    let inputs: [AudioRoute]
    let outputID: UInt32?
    let inputID: UInt32?
    let inputGain: AudioInputGain?
    let inputMute: AudioInputMute?
    let airPodsOutput: AirPodsOutput?

    func devices(for direction: AudioDirection) -> [AudioRoute] {
        direction == .output ? outputs : inputs
    }

    func selectedID(for direction: AudioDirection) -> UInt32? {
        direction == .output ? outputID : inputID
    }
}
