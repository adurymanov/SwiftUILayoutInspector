#if LayoutInspectorEngine && !LAYOUT_INSPECTOR_DISABLED && os(iOS)
import SwiftUI

/// The mode's info card (lint issues, the measure hint, the re-render summary) on glass at the bottom of the screen.
/// A tap folds it into a small pill so it doesn't cover the content; folded or not is kept between launches.
struct InspectorPanel: View {
    @ObservedObject var session: InspectorSession
    @AppStorage("LayoutInspector.panelCollapsed") private var isCollapsed = false

    var body: some View {
        if session.configuration.toolbar != .hidden, let panel = session.panel {
            Button { withAnimation(.snappy(duration: 0.25)) { isCollapsed.toggle() } } label: {
                if isCollapsed { collapsed(panel) } else { expanded(panel) }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(panel.title)
            .accessibilityValue(isCollapsed ? "Collapsed" : panel.lines.joined(separator: ", "))
            .accessibilityHint(isCollapsed ? "Shows the details" : "Folds the panel")
        }
    }

    private func collapsed(_ panel: InspectorCard.Content) -> some View {
        HStack(spacing: 6) {
            Text(panel.title).font(.caption.weight(.semibold))
            if let first = panel.lines.first {
                Text(first).font(.caption2.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            Image(systemName: "chevron.up").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .contentShape(Capsule())
        .inspectorGlass(in: Capsule())
    }

    private func expanded(_ panel: InspectorCard.Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(panel.title).font(.footnote.weight(.bold))
                Spacer(minLength: 12)
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
            ForEach(Array(panel.lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(line.contains("✕") ? Color.red : line.contains("⚠︎") ? Color.orange : Color.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .inspectorGlass(in: RoundedRectangle(cornerRadius: 18))
    }
}

#endif
