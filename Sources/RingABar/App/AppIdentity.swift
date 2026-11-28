import AppKit
import Foundation
import OSLog

enum AppIdentity {
    static let bundleID = "com.willhsu.ring-a-bar"

    static func logger(category: String) -> Logger {
        Logger(subsystem: bundleID, category: category)
    }
}

enum WiFiSignalStrength {
    static func bars(for signalDBm: Int?) -> Int {
        guard let value = signalDBm, value < 0 else { return 0 }
        if value >= -70 { return 3 }
        if value >= -78 { return 2 }
        if value >= -88 { return 1 }
        return 0
    }

    static func variableValue(for signalDBm: Int?) -> Double {
        let levels = [0.0, 0.33, 0.66, 1.0]
        return levels[bars(for: signalDBm)]
    }
}

@MainActor
enum VolumeHaptics {
    static func step(for level: Double) -> Int {
        Int((min(1, max(0, level)) * 16).rounded())
    }

    @discardableResult
    static func performIfStepChanged(from previousStep: Int, to nextLevel: Double, reduceMotion: Bool) -> Int {
        let nextStep = step(for: nextLevel)
        if !reduceMotion, nextStep != previousStep {
            let pattern: NSHapticFeedbackManager.FeedbackPattern = (nextStep == 0 || nextStep == 16) ? .alignment : .levelChange
            NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .default)
        }
        return nextStep
    }
}
