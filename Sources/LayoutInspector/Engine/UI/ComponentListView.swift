#if LayoutInspectorEngine && !LAYOUT_INSPECTOR_DISABLED && os(iOS)
import SwiftUI
import UIKit

/// Rows of the components list: the components of a capture in screen order, indented by how many components they
/// are nested in.
struct ComponentList {
    struct Row: Identifiable {
        let node: InspectorNode
        let depth: Int
        var id: Int { node.id }
    }

    let rows: [Row]

    init(_ capture: InspectorCapture?) {
        var rows: [Row] = []
        func visit(_ node: InspectorNode, depth: Int) {
            let isComponent = node.kind == .component
            if isComponent { rows.append(Row(node: node, depth: depth)) }
            for child in node.children { visit(child, depth: depth + (isComponent ? 1 : 0)) }
        }
        capture?.swiftUIRoots.forEach { visit($0, depth: 0) }
        self.rows = rows
    }

    func filtered(_ query: String) -> [Row] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return rows }
        return rows.filter { $0.node.title.localizedCaseInsensitiveContains(query) || $0.node.typeName.localizedCaseInsensitiveContains(query) }
    }

    func text(counts: RenderCounts?) -> String {
        var lines = ["# Components – \(rows.count)"]
        for row in rows {
            var line = String(repeating: "  ", count: row.depth) + "\(row.node.title)  @ \(row.node.frame.frameLabel)"
            if let entry = counts?.byNode[row.node.id] { line += "  renders \(entry.label)" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}

/// The sheet opened from Dev → Components list. A tap on a row selects the component on screen and lowers the sheet
/// so the outline can be seen; the info button opens what the inspector knows about it.
struct ComponentListView: View {
    @ObservedObject var session: InspectorSession
    /// Lowers the sheet to show the selection.
    let reveal: () -> Void
    let close: () -> Void
    @State private var query = ""
    @State private var path: [DetailPage] = []
    @State private var pages: [DetailPage: DetailSnapshot] = [:]
    @State private var cache = ListCache()

    var body: some View {
        NavigationStack(path: $path) {
            let list = cache.list(for: session.capture)
            List(list.filtered(query)) { row in
                ComponentRowView(row: row, renders: session.renderCounts?.byNode[row.node.id],
                                 isSelected: session.selectedID == row.node.id,
                                 select: { session.select(row.node); reveal() },
                                 info: { open(row.node) })
            }
            .listStyle(.plain)
            .overlay {
                if list.rows.isEmpty {
                    ContentUnavailableView("No components", systemImage: "square.on.square.dashed",
                                           description: Text("Pick a mode to capture the screen. Only views declared in the app are listed."))
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Name or type")
            .navigationTitle("Components")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ShareLink(item: list.text(counts: session.renderCounts)) { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("Share as text")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: close)
                }
            }
            .navigationDestination(for: DetailPage.self) { page in
                if let snapshot = pages[page] {
                    ComponentDetailView(snapshot: snapshot,
                                        renders: session.capture === snapshot.capture ? session.renderCounts?.byNode[snapshot.node.id] : snapshot.renders,
                                        select: { session.select(sameAs: snapshot.node); reveal() })
                }
            }
        }
    }

    /// Details are read here, in the button's action: reading the graph during a SwiftUI update of the inspector
    /// itself would tie the two graphs together.
    private func open(_ node: InspectorNode) {
        guard let capture = session.capture else { return }
        let match = ComponentGraph.match(capture)[node.id]
        let page = DetailPage()
        pages[page] = DetailSnapshot(node: node, capture: capture, details: ComponentDetails.read(node, match: match),
                                     renders: session.renderCounts?.byNode[node.id])
        path.append(page)
    }
}

/// One opened details page. Node ids restart with every capture, so a page carries what it shows.
struct DetailPage: Hashable {
    let id = UUID()
}

struct DetailSnapshot {
    let node: InspectorNode
    weak var capture: InspectorCapture?
    let details: ComponentDetails
    let renders: RenderCounts.Entry?
}

/// The rows of the last capture, built once per capture rather than on every count update.
private final class ListCache {
    private weak var capture: InspectorCapture?
    private var list = ComponentList(nil)

    func list(for capture: InspectorCapture?) -> ComponentList {
        if capture !== self.capture || capture == nil {
            self.capture = capture
            list = ComponentList(capture)
        }
        return list
    }
}

private struct ComponentRowView: View {
    let row: ComponentList.Row
    let renders: RenderCounts.Entry?
    let isSelected: Bool
    let select: () -> Void
    let info: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: select) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.node.title).font(.body.weight(isSelected ? .semibold : .regular))
                        Text(row.node.frame.frameLabel).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if let renders {
                        Text(renders.label)
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(InspectorRenderer.heatColor(renders.count == 0 ? 0 : 1)).opacity(0.2), in: Capsule())
                            .accessibilityLabel("\(renders.label) renders")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(action: info) { Image(systemName: "info.circle") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Details of \(row.node.title)")
        }
        .padding(.leading, CGFloat(row.depth) * 14)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.12) : nil)
    }
}

private struct ComponentDetailView: View {
    let snapshot: DetailSnapshot
    let renders: RenderCounts.Entry?
    let select: () -> Void

    private var node: InspectorNode { snapshot.node }
    private var details: ComponentDetails { snapshot.details }

    var body: some View {
        List {
            Section {
                LabeledContent("Type", value: AttributeGraphTree.readable(node.typeName))
                LabeledContent("Frame", value: node.frame.frameLabel)
                if let renders { LabeledContent("Re-renders", value: renders.label) }
                let path = node.path.filter { $0.kind == .component && $0 !== node }.map(\.title)
                if !path.isEmpty { LabeledContent("Inside", value: path.joined(separator: " › ")) }
            }
            Section {
                if let note = details.note {
                    Text(note).font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(details.properties, id: \.name) { property in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            if property.kind != .value {
                                Text("@" + property.kind.label).font(.caption.weight(.semibold)).foregroundStyle(.tint)
                            }
                            Text(property.name).font(.body.monospaced())
                            Text(property.type).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        if let value = property.value {
                            Text(value).font(.caption.monospaced()).textSelection(.enabled)
                        } else if property.kind == .state || property.kind == .environment {
                            Text("value kept by SwiftUI").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
            } header: {
                Text("Properties")
            } footer: {
                Text("As the parent built the view. @State and @Environment values live in SwiftUI's storage and can't be read.")
            }
            if !details.fonts.isEmpty {
                Section("Fonts inside") {
                    ForEach(details.fonts, id: \.font) { LabeledContent($0.font, value: "×\($0.count)") }
                }
            }
            Section {
                ForEach(details.environment, id: \.name) { LabeledContent($0.name, value: $0.value) }
            } header: {
                Text("Environment")
            } footer: {
                Text("From the window's traits. Values set with .environment(…) inside the screen are not shown.")
            }
        }
        .navigationTitle(node.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(action: select) { Image(systemName: "scope") }.accessibilityLabel("Show on screen")
                ShareLink(item: details.text(for: node, renders: renders)) { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel("Share as text")
            }
        }
    }
}

#endif
