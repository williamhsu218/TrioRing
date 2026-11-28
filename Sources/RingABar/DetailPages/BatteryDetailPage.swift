import SwiftUI

struct BatteryPage: View {
    let store: StatusStore
    let preferences: Preferences
    let actions: BatteryActions
    let height: PanelHeightReporter
    let navigationFocus: FocusState<PanelNavigationFocus?>.Binding
    let onBack: () -> Void
    let onOpenSettings: () -> Void
    let onOpenAppSettings: () -> Void
    let cache: BatteryPageCache
    private var details: BatteryDetails? {
        cache.pluggedIn == store.battery.reading?.pluggedIn ? cache.details : nil
    }
    private var power: BatteryPowerSnapshot? {
        cache.pluggedIn == store.battery.reading?.pluggedIn ? cache.power : nil
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        DetailPanel(height: height) {
            let title = store.battery.percent.map { String(localized: "Battery · \($0)%") } ?? String(localized: "Battery")
            PageHeader(title: LocalizedStringKey(title), navigationFocus: navigationFocus, onBack: onBack) {
                Button(action: onOpenAppSettings) {
                    DetailHeaderAction(symbol: "gearshape")
                }
                .buttonStyle(PanelActionStyle(cornerRadius: StatusPanel.summaryActionWidth / 2))
                .help("Open App Battery Settings")
                .accessibilityLabel("Open App Battery Settings")
                .accessibilityIdentifier("RingABar.battery.appSettingsShortcut")

                Button { store.batteryInfoVisible.toggle() } label: {
                    DetailHeaderAction(symbol: "info.circle")
                }
                .buttonStyle(PanelActionStyle(cornerRadius: StatusPanel.summaryActionWidth / 2))
                .help("About these readings")
                .accessibilityLabel("About these readings")
                .accessibilityIdentifier("RingABar.battery.info")
                .popover(isPresented: Binding(get: { store.batteryInfoVisible },
                                              set: { store.batteryInfoVisible = $0 }), arrowEdge: .bottom) {
                    batteryReadingInfo
                        .padding(12)
                        .frame(width: 282)
                }
            }
        } content: {
            batteryContent
                .animation(PanelMotion.animation(reduceMotion: reduceMotion), value: batteryLayoutReady)
        }
        .onDisappear { store.batteryInfoVisible = false }
        .preference(key: PanelReadyLayoutKey.self, value: batteryLayoutReady ? store.panelLayout : nil)
        .task(id: store.battery.reading?.pluggedIn) {
            guard let reading = store.battery.reading else { return }
            cache.prepare(pluggedIn: reading.pluggedIn)
            let result = await Task.detached(priority: .utility) { BatteryDetails.read() }.value
            if !Task.isCancelled { cache.details = result }
        }
        .task(id: store.battery.reading?.pluggedIn) {
            guard let reading = store.battery.reading else { return }
            cache.prepare(pluggedIn: reading.pluggedIn)
            while !Task.isCancelled {
                let previous = power?.breakdown
                let pluggedIn = reading.pluggedIn
                let result = await Task.detached(priority: .utility) {
                    BatteryPowerSnapshot.read(pluggedIn: pluggedIn, previous: previous)
                }.value
                guard !Task.isCancelled else { return }
                cache.power = result
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private var batteryContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let battery = store.battery.reading {
                if preferences.showsPowerFlow, let flow = power?.flow {
                    BatteryPowerFlowView(state: flow)
                        .accessibilityIdentifier("RingABar.battery.powerFlow")
                }
                DetailGroup {
                    DetailValue(label: "Battery level", value: (Double(battery.percent) / 100).formatted(.percent))
                        .accessibilityIdentifier("RingABar.battery.charge")
                    DetailValue(label: "Power status", value: store.battery.detail)
                    if let minutes = battery.minutesRemaining {
                        let remaining = Duration.seconds(minutes * 60)
                            .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
                        DetailValue(label: battery.charging ? "Estimated time until charged" : "Estimated time remaining", value: remaining)
                    }
                }
                chargingManagement(battery)
                if let modes = actions.modes, modes.supportsLow || modes.supportsHigh, modes.current != nil {
                    Divider()
                    detailPowerMode(battery, modes: modes)
                } else if actions.modes == nil {
                    DetailValue(label: "Low Power Mode", value: battery.lowPower ? String(localized: "On") : String(localized: "Off"))
                }
                Divider()
                batteryReadings(isPluggedIn: battery.pluggedIn)
            } else {
                Text(store.battery.detail).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                DetailSettingsLink("System Battery Settings…", id: "RingABar.battery.systemSettings", action: onOpenSettings)
                DetailSettingsLink("Open App Battery Settings", id: "RingABar.battery.appSettingsLink", action: onOpenAppSettings)
            }
        }
    }

    @ViewBuilder
    private func chargingManagement(_ battery: BatteryReading) -> some View {
        let showsLimitControls = !actions.availableChargeLimits.isEmpty
        let fallbackLimit = actions.currentChargeLimit == nil || !showsLimitControls
            ? actions.temporarilyOverriddenLimit ?? battery.chargeLimit : nil
        let fullCharge = FullChargeRow(actions: actions, reading: battery, showUnavailable: true,
                                       onSystemSettings: onOpenSettings)
        if actions.showsCalibrationStatus || showsLimitControls || fallbackLimit.map({ $0 < 100 }) == true || fullCharge.hasContent {
            VStack(alignment: .leading, spacing: 7) {
                Text("Charging Management")
                    .font(.caption.weight(.semibold))
                    .panelSecondaryText()
                    .accessibilityAddTraits(.isHeader)
                if actions.showsCalibrationStatus {
                    BatteryCalibrationRow(status: actions.calibration.status)
                }
                if let limit = fallbackLimit, limit < 100 {
                    DetailValue(label: actions.temporarilyOverriddenLimit == nil ? "Charge limit" : "Charge limit (temporarily bypassed)",
                                value: (Double(limit) / 100).formatted(.percent))
                        .accessibilityIdentifier("RingABar.battery.chargeLimit")
                }
                if showsLimitControls {
                    ChargeLimitControls(actions: actions, reading: battery)
                }
                if fullCharge.hasContent { fullCharge }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.primary.opacity(0.09), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("RingABar.battery.chargingManagement")
        }
    }

    private func batteryReadings(isPluggedIn: Bool) -> some View {
        let expanded = store.batteryReadingsExpanded
        return VStack(alignment: .leading, spacing: 7) {
            Button {
                store.batteryReadingsExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "waveform.path")
                        .frame(width: 18)
                        .accessibilityHidden(true)
                    Text("Battery Health & Power")
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                        .animation(PanelMotion.animation(reduceMotion: reduceMotion), value: expanded)
                        .accessibilityHidden(true)
                }
                .foregroundStyle(expanded ? Color.accentColor : .primary)
                .padding(.horizontal, 7)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .background(expanded ? Color.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
            }
            .buttonStyle(PanelActionStyle())
            .accessibilityValue(expanded ? Text("Expanded") : Text("Collapsed"))
            .accessibilityIdentifier("RingABar.battery.readings")
            if expanded {
                batteryDiagnosticValues(isPluggedIn: isPluggedIn)
                    .padding(.horizontal, 7)
                    .transition(PanelMotion.disclosureTransition(reduceMotion: reduceMotion))
            }
        }
        .clipped()
        .animation(PanelMotion.animation(reduceMotion: reduceMotion), value: expanded)
    }

    private func batteryDiagnosticValues(isPluggedIn: Bool) -> some View {
        DetailGroup {
            if isPluggedIn, let watts = details?.adapterWatts {
                DetailValue(label: "Adapter rating", value: String(localized: "\(watts) W"))
            }
            if let power {
                if let type = power.inputPortType {
                    DetailValue(label: "Charging port", value: type)
                }
                if let display = power.displayWatts, power.breakdown == nil || !preferences.showsPowerFlow {
                    DetailValue(label: "Built-in display backlight", value: BatteryPowerSnapshot.formatWatts(display))
                }
                ForEach(power.usbPorts, id: \.channel) { port in
                    let label = port.name.map { port.channelLabel + " · " + $0 } ?? port.channelLabel
                    DetailValue(label: LocalizedStringKey(label), value: BatteryPowerSnapshot.formatWatts(port.watts))
                        .help(port.measurementLabel)
                        .accessibilityIdentifier("RingABar.battery.usb.\(port.channel)")
                }
            }
            if let details {
                let unknown = String(localized: "Unavailable")
                DetailValue(label: "Maximum capacity", value: details.maximumCapacity
                    .map { (Double($0) / 100).formatted(.percent) } ?? unknown)
                    .accessibilityIdentifier("RingABar.battery.maximumCapacity")
                DetailValue(label: "Battery status", value: condition(details.condition))
                if let temperature = power?.temperatureCelsius {
                    let value = temperature.formatted(.number.precision(.fractionLength(1)))
                    DetailValue(label: "Battery temperature", value: String(localized: "\(value) °C"))
                }
                DetailValue(label: "Cycle count", value: details.cycleCount?.formatted() ?? unknown)
            } else {
                Text("Reading battery health…").font(.caption).foregroundStyle(.secondary)
            }
            DetailValue(label: "System uptime", value: Duration.seconds(details?.uptime ?? ProcessInfo.processInfo.systemUptime)
                .formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated)))
        }
    }

    private var batteryReadingInfo: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("About these readings").font(.headline)
            Text("The system branch estimates the remainder after display, battery charging and USB output.")
            Text("USB readings are per port. Accessories behind a hub share its reading.")
            if let volts = power?.volts {
                DetailValue(label: "Battery voltage", value: String(localized: "\(decimal(volts)) V"))
            }
            if let amps = power?.amps {
                DetailValue(label: "Battery current", value: String(localized: "\(decimal(amps)) A"))
            }
        }
        .font(.caption)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("RingABar.battery.explanation")
    }

    @ViewBuilder private func detailPowerMode(_ battery: BatteryReading, modes: PowerModeState) -> some View {
        if actions.powerAuthorization.state != .ready {
            DetailValue(label: "Low Power Mode", value: battery.lowPower ? String(localized: "On") : String(localized: "Off"))
            Button(action: onOpenAppSettings) {
                Label("Set up power mode access", systemImage: "lock.shield")
            }
            .accessibilityIdentifier("RingABar.battery.powerAccess")
        } else if modes.supportsHigh {
            PowerModeRow(actions: actions, reading: battery)
        } else {
            Toggle("Low Power Mode", isOn: Binding(
                get: { modes.current == .low },
                set: { actions.setMode($0 ? .low : .automatic, pluggedIn: battery.pluggedIn) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(actions.modeBusy)
            .accessibilityIdentifier("RingABar.battery.powerMode")
            if actions.modeBusy {
                ProgressView("Waiting for macOS…").controlSize(.small).font(.caption)
            }
            if let error = actions.modeError { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }

    private var batteryLayoutReady: Bool {
        guard store.battery.reading != nil else { return true }
        if store.batteryReadingsExpanded { return details != nil && power != nil }
        return !preferences.showsPowerFlow || power != nil
    }

    private func decimal(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1...2)))
    }

    private func condition(_ condition: BatteryDetails.Condition?) -> String {
        switch condition {
        case .normal: String(localized: "Normal")
        case .serviceRecommended: String(localized: "Service Recommended")
        case nil: String(localized: "Unavailable")
        }
    }
}
