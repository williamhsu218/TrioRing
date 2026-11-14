import SwiftUI

/// The same label is used by device buttons and off-screen layout fixtures.
struct AudioDeviceRowLabel<Trailing: View>: View {
    let route: AudioRoute
    let selected: Bool
    let showsSummaryChips: Bool
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: showsSummaryChips ? 10 : 8) {
            if showsSummaryChips {
                Image(systemName: route.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selected ? Color.white : .primary)
                    .frame(width: 24, height: 24)
                    .background(selected ? Color.accentColor : Color.primary.opacity(0.08), in: Circle())
                    .accessibilityHidden(true)
            } else {
                Image(systemName: route.symbol)
                    .frame(width: 20)
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .accessibilityHidden(true)
            }
            Text(route.name)
                .fontWeight(showsSummaryChips && selected ? .semibold : .regular)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(Text(verbatim: route.name))
            Spacer(minLength: 0)
            trailing()
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, showsSummaryChips ? 0 : 7)
        .frame(height: AudioDeviceRows.rowHeight)
        .background(selected && !showsSummaryChips ? Color.accentColor.opacity(0.10) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
    }
}
