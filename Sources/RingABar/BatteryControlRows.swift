import AppKit
import SwiftUI

private struct ChargeActionLabel: View {
    let title: LocalizedStringKey
    let symbol: String
    var emphasized = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.callout.weight(emphasized ? .semibold : .medium))
            .foregroundStyle(Color.primary.opacity(enabled ? 1 : 0.50))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .background(emphasized && enabled ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
    }
}

struct BatteryCalibrationRow: View {
    let status: BatteryCalibration.Status

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("macOS Battery Calibration", systemImage: "bolt.badge.clock")
                Spacer(minLength: 6)
                Text(value).foregroundStyle(.secondary)
            }
            .font(.callout)
            if let description {
                Text(description).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("RingABar.battery.calibration")
    }

    private var value: LocalizedStringKey {
        switch status {
        case .unavailable: "Status unavailable"
        case .inactive: "Not running"
        case .active: "Calibrating"
        case .checking: "Checking limit"
        case let .restored(limit): "\(limit)% limit restored"
        case .changed, .finished: "Calibration ended"
        }
    }

    private var description: LocalizedStringKey? {
        switch status {
        case let .active(limit):
            if let limit { "macOS may charge to 100%. TrioRing will check the original \(limit)% limit when calibration ends." }
            else { "macOS may charge to 100% during calibration." }
        case let .checking(limit):
            "Waiting for macOS to confirm the original \(limit)% charge limit."
        case let .changed(original, current):
            "The current charge limit is \(current)%. Before calibration it was \(original)%."
        case .finished:
            "The original charge limit could not be verified."
        default: nil
        }
    }
}

struct FullChargeRow: View {
    let actions: BatteryActions
    let reading: BatteryReading?
    var showUnavailable = false
    var compact = false
    let onSystemSettings: () -> Void

    private var offer: BatteryActions.Offer { actions.offer(for: reading) }
    private var showsChargingOptions: Bool {
        !actions.calibration.blocksChargingChanges && reading?.isPausedAtLimit == true && actions.chargePause == nil
    }

    var hasContent: Bool {
        if actions.chargeBusy || actions.chargeError != nil { return true }
        switch offer {
        case .charge, .cancel, .waiting, .systemOverride: return true
        case .unavailable: return showUnavailable || showsChargingOptions
        case .none: return showsChargingOptions
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if actions.chargeBusy {
                ProgressView("Updating charging…").controlSize(.small).font(.caption)
            } else {
                switch offer {
                case .charge:
                    chargeButton("Charge to Full Now", symbol: "bolt.fill", writesSetting: true, emphasized: true) {
                        actions.runCharge(for: reading)
                    }
                case let .cancel(limit):
                    chargeButton("Resume \(limit)% Charge Limit", symbol: "arrow.uturn.backward", writesSetting: true) { actions.runCharge(for: reading) }
                    if let reading, reading.pluggedIn, reading.percent < 100, !reading.charging {
                        Text("The override is active. macOS still reports charging paused.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                case .waiting:
                    Text("Waiting for charging to start…").font(.caption).foregroundStyle(.secondary)
                case .systemOverride:
                    Text("System charging override is active").font(.caption).foregroundStyle(.secondary)
                case .unavailable, .none:
                    if showsChargingOptions {
                        chargeButton("Charging Options…", symbol: "bolt.fill", action: onSystemSettings)
                        if showUnavailable {
                            Text("macOS does not offer a temporary override for this charge pause.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else if showUnavailable && offer == .unavailable {
                        Text("Temporary full charging is unavailable on this Mac.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let error = actions.chargeError { Text(error).foregroundStyle(.red).font(.caption) }
        }
    }

    private func chargeButton(_ title: LocalizedStringKey, symbol: String, writesSetting: Bool = false, emphasized: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if compact {
                Label(title, systemImage: symbol)
                    .font(.callout)
                    .panelSecondaryText()
                    .padding(.horizontal, 7)
                    .frame(minHeight: 28, alignment: .leading)
                    .contentShape(Rectangle())
            } else {
                ChargeActionLabel(title: title, symbol: symbol, emphasized: emphasized)
            }
        }
        .buttonStyle(PanelActionStyle(cornerRadius: compact ? 9 : 8))
        .disabled(writesSetting && actions.chargingControlsDisabled)
        .accessibilityIdentifier("RingABar.battery.chargeAction")
    }
}

struct ChargeLimitControls: View {
    let actions: BatteryActions
    let reading: BatteryReading

    var body: some View {
        if !actions.availableChargeLimits.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                if let limit = actions.currentChargeLimit {
                    HStack {
                        Label("Charge limit", systemImage: "battery.75percent")
                        Spacer()
                        Menu {
                            ForEach(actions.availableChargeLimits, id: \.self) { value in
                                Button {
                                    actions.updateChargeLimit(value)
                                } label: {
                                    if value == limit {
                                        Label("\(value)%", systemImage: "checkmark")
                                    } else {
                                        Text("\(value)%")
                                    }
                                }
                            }
                        } label: {
                            Text("\(limit)%")
                                .monospacedDigit()
                        }
                        .accessibilityLabel(Text("Charge limit"))
                        .accessibilityValue(Text("\(limit)%"))
                        .accessibilityIdentifier("RingABar.battery.setChargeLimit")
                    }
                    .disabled(actions.chargingControlsDisabled)

                    if let pause = actions.chargePause, pause.pausedLimit == limit {
                        pauseButton("Restore \(pause.originalLimit)% Charge Limit", symbol: "arrow.uturn.backward",
                                    action: actions.restorePausedChargeLimit)
                            .accessibilityIdentifier("RingABar.battery.restorePause")
                    } else if let pauseLimit = actions.limitForPause(reading) {
                        pauseButton("Pause Charging at \(pauseLimit)%", symbol: "pause.fill") { actions.pauseCharging(reading) }
                            .accessibilityIdentifier("RingABar.battery.pauseCharging")
                    }
                }
                if actions.externalChargeManagerRunning {
                    Text("Quit AlDente before changing charging settings in TrioRing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("RingABar.battery.externalChargeManager")
                }
            }
        }
    }

    private func pauseButton(_ title: LocalizedStringKey, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { ChargeActionLabel(title: title, symbol: symbol) }
            .buttonStyle(PanelActionStyle(cornerRadius: 8))
            .disabled(actions.chargingControlsDisabled)
    }
}

struct PowerModeAccessRow: View {
    let authorization: PowerModeAuthorization

    var body: some View {
        SettingsRow(title: "Power Mode Access", subtitle: description,
                    symbol: authorization.state == .ready ? "checkmark.shield" : "lock.shield",
                    tint: authorization.state == .ready ? .blue : .indigo) {
            switch authorization.state {
            case .notSetUp:
                Button("Set Up…", action: authorization.setUp)
                    .accessibilityIdentifier("RingABar.settings.powerAccess.setUp")
            case .needsApproval:
                Button("Open Login Items…", action: authorization.openSystemSettings)
                    .accessibilityIdentifier("RingABar.settings.powerAccess.loginItems")
            case .ready:
                Button("Manage…", action: authorization.openSystemSettings)
                    .accessibilityIdentifier("RingABar.settings.powerAccess.manage")
            case .failed:
                Button("Try Again", action: authorization.setUp)
                    .accessibilityIdentifier("RingABar.settings.powerAccess.retry")
            case .checking:
                ProgressView().controlSize(.small).accessibilityLabel("Waiting for macOS…")
            case .unavailable:
                Button("Open Battery Settings…") { NSWorkspace.shared.open(SystemSettingsPane.battery.url) }
            }
        }
    }

    private var description: LocalizedStringKey {
        switch authorization.state {
        case .notSetUp: "Approve TrioRing once to switch power modes from the menu bar."
        case .needsApproval: "Allow TrioRing under Allow in the Background in Login Items & Extensions."
        case .ready: "Approved for power mode changes."
        case .failed: "TrioRing could not connect to its power mode helper."
        case .checking: "Waiting for macOS…"
        case .unavailable: "Power mode access needs a signed TrioRing build with its helper."
        }
    }
}

struct PowerModeRow: View {
    let actions: BatteryActions
    let reading: BatteryReading?
    var showsContext = false

    var body: some View {
        if let state = actions.modes, state.supportsLow || state.supportsHigh, let current = state.current,
           let reading {
            let available: [PowerMode] = [.automatic] + (state.supportsLow ? [.low] : []) + (state.supportsHigh ? [.high] : [])
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 2) {
                    ForEach(available, id: \.rawValue) { mode in
                        Button {
                            actions.setMode(mode, pluggedIn: reading.pluggedIn)
                        } label: {
                            Label(mode.title, systemImage: mode.symbol)
                                .font(.caption.weight(.medium))
                                .frame(maxWidth: .infinity, minHeight: 23)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(mode == current ? Color.white : Color.primary)
                        .background(mode == current ? Color.accentColor : Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityAddTraits(mode == current ? .isSelected : [])
                        .accessibilityIdentifier("RingABar.battery.mode.\(mode.rawValue)")
                    }
                }
                .padding(3)
                .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                .disabled(actions.modeBusy || actions.powerAuthorization.state != .ready)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Power Mode")
                .accessibilityValue(Text(current.title))
                .accessibilityIdentifier("RingABar.battery.powerMode")
                if showsContext {
                    Text(reading.pluggedIn ? "Applies to the power adapter profile." : "Applies to the battery profile.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if actions.modeBusy {
                    ProgressView("Waiting for macOS…").controlSize(.small).font(.caption)
                }
                if let error = actions.modeError { Text(error).foregroundStyle(.red).font(.caption) }
            }
        } else if showsContext {
            Text("Power mode controls are unavailable on this Mac.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
