#if LayoutInspectorEngine && !LAYOUT_INSPECTOR_DISABLED && os(iOS)
import SwiftUI
import UIKit

/// What the components list shows: the list of the current capture, the viewer's filters and a point picked on screen.
final class ComponentListModel: ObservableObject {
    @Published var filter: ComponentList.Filter {
        didSet {
            Self.save(filter)
            if filter.statefulOnly, !oldValue.statefulOnly { readStateful() }
        }
    }
    @Published var query = ""
    @Published var point: CGPoint?
    @Published var isPicking = false
    /// Opened details.
    var pages: [DetailPage: DetailSnapshot] = [:]

    private weak var capture: InspectorCapture?
    private(set) var list = ComponentList(nil)
    private var stateful: Set<Int>?

    /// How long building the list of the last capture took (folding needs the graph to tell modifiers).
    private(set) var buildDuration: TimeInterval = 0

    init() { filter = Self.load() }

    /// Called when the session publishes a capture, never from a view's body: building reads the graph.
    func update(_ capture: InspectorCapture?) {
        guard capture !== self.capture || capture == nil else { return }
        let start = CACurrentMediaTime()
        self.capture = capture
        stateful = nil
        if point != nil { point = nil }
        list = ComponentList(capture, modifierTypes: capture.map(ComponentGraph.modifierTypes(in:)) ?? [])
        if let module = filter.module, !list.modules.contains(module) { filter.module = nil }
        if filter.statefulOnly { readStateful() }
        buildDuration = CACurrentMediaTime() - start
        objectWillChange.send()
    }

    private func readStateful() {
        guard stateful == nil, let capture else { return }
        stateful = Self.statefulComponents(in: capture)
    }

    func context(bounds: CGRect, counts: RenderCounts?) -> ComponentList.Context {
        ComponentList.Context(bounds: bounds, counts: counts, stateful: stateful, query: query, point: point)
    }

    /// Components whose view has `@State` or `@Binding`, read from the graph once per capture.
    static func statefulComponents(in capture: InspectorCapture) -> Set<Int> {
        var result = Set<Int>()
        for (id, match) in ComponentGraph.match(capture) where match.isExact {
            guard let view = match.views.first, let value = ComponentGraph.value(of: view) else { continue }
            if ComponentDetails.properties(of: value).contains(where: { $0.kind == .state || $0.kind == .binding }) { result.insert(id) }
        }
        return result
    }

    private static let key = "LayoutInspector.componentListFilter"

    private static func load() -> ComponentList.Filter {
        guard let data = UserDefaults.standard.data(forKey: key),
              let filter = try? JSONDecoder().decode(ComponentList.Filter.self, from: data) else { return ComponentList.Filter() }
        return filter
    }

    private static func save(_ filter: ComponentList.Filter) {
        UserDefaults.standard.set(try? JSONEncoder().encode(filter), forKey: key)
    }
}

/// The sheet opened from Dev → Components list: one compact row per component, filters, and a point picked on screen.
/// A tap on a row outlines the component and lowers the sheet; the info button opens its details, where the tree is
/// walked through its parents and children.
struct ComponentListView: View {
    @ObservedObject var session: InspectorSession
    /// Owned by the sheet's controller: the navigation destination reads it from another place in the view tree, where
    /// the list's own `@State` and `@StateObject` showed up empty.
    @ObservedObject var model: ComponentListModel
    /// Lowers the sheet to show the selection.
    let reveal: () -> Void
    /// Lowers the sheet to its smallest height and lets a tap on the screen pick a point (`nil` – cancelled).
    let pick: (@escaping (CGPoint?) -> Void) -> Void
    let close: () -> Void
    @State private var path: [DetailPage] = []

    var body: some View {
        NavigationStack(path: $path) {
            let counts = session.renderCounts
            let items = model.list.items(folded: model.filter.hidesWrappers)
            let rows = model.list.rows(model.filter, model.context(bounds: session.overlay.bounds, counts: counts))
            List {
                Section {
                    ForEach(rows) { item in
                        ComponentRowView(item: item, parent: item.parent.map { items[$0].node.title },
                                         renders: counts?.byNode[item.node.id],
                                         isSelected: session.selectedID == item.node.id,
                                         select: { session.select(item.target); reveal() },
                                         info: { open(item, in: items) })
                    }
                } header: {
                    FilterBar(model: model, modules: model.list.modules, hasCounts: counts != nil, rowCount: rows.count,
                              shared: Self.sharedCounts(counts, items: model.list.all))
                }
            }
            .listStyle(.plain)
            .overlay {
                if model.isPicking {
                    ContentUnavailableView("Tap the screen", systemImage: "scope",
                                           description: Text("The list will show the components under the point."))
                } else if rows.isEmpty {
                    ContentUnavailableView("No components", systemImage: "square.on.square.dashed",
                                           description: Text(model.list.all.isEmpty
                                                             ? "Pick a mode to capture the screen. Only views declared in the app are listed."
                                                             : "Nothing matches the filters."))
                }
            }
            .searchable(text: $model.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Name, type or module")
            .navigationTitle("Components")
            .navigationBarTitleDisplayMode(.inline)
            // Never inside this view's update: building the list reads the graph.
            .onReceive(session.$capture) { capture in DispatchQueue.main.async { model.update(capture) } }
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button { startPicking() } label: { Image(systemName: "scope") }
                        .accessibilityLabel("Pick on screen")
                    ShareLink(item: model.list.text(rows, in: items, counts: counts)) { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("Share as text")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: close)
                }
            }
            .navigationDestination(for: DetailPage.self) { page in
                if let snapshot = model.pages[page] {
                    ComponentDetailView(snapshot: snapshot,
                                        renders: session.capture === snapshot.capture ? counts?.byNode[snapshot.node.id] : snapshot.renders,
                                        select: { session.select(sameAs: snapshot.item.target); reveal() },
                                        open: { open($0, in: snapshot.items) })
                }
            }
        }
    }

    /// Types whose views share one count, once each: "BrandLabel Σ12 across 74 views".
    static func sharedCounts(_ counts: RenderCounts?, items: [ComponentList.Item]) -> [String] {
        guard let counts else { return [] }
        var shared: [String: RenderCounts.Entry] = [:]
        for item in items {
            if let entry = counts.byNode[item.node.id], entry.instances > 1 { shared[item.node.title] = entry }
        }
        return shared.sorted { $0.key < $1.key }.map { "\($0.key) Σ\($0.value.count) across \($0.value.instances) views it can't tell apart" }
    }

    private func startPicking() {
        model.isPicking = true
        pick { point in
            model.isPicking = false
            guard let point else { return }
            model.point = point
            if let smallest = model.list.rows(model.filter, model.context(bounds: session.overlay.bounds, counts: session.renderCounts)).first {
                session.select(smallest.target)
            }
        }
    }

    /// Details are read here, in the button's action: reading the graph during a SwiftUI update of the inspector
    /// itself would tie the two graphs together.
    private func open(_ item: ComponentList.Item, in items: [ComponentList.Item]) {
        guard let capture = session.capture else { return }
        let node = item.node
        let page = DetailPage()
        model.pages[page] = DetailSnapshot(node: node, item: item, items: items, capture: capture,
                                     details: ComponentDetails.read(node, match: ComponentGraph.match(capture)[node.id]),
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
    let item: ComponentList.Item
    let items: [ComponentList.Item]
    weak var capture: InspectorCapture?
    let details: ComponentDetails
    let renders: RenderCounts.Entry?
}

// MARK: - Filters

private struct FilterBar: View {
    @ObservedObject var model: ComponentListModel
    let modules: [String]
    let hasCounts: Bool
    let rowCount: Int
    let shared: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if let point = model.point {
                        Chip(title: "At \(point.x.pt),\(point.y.pt)", systemImage: "xmark", isOn: true) { model.point = nil }
                    }
                    Chip(title: "Visible", isOn: model.filter.visibleOnly) { model.filter.visibleOnly.toggle() }
                    Chip(title: "Hide wrappers", isOn: model.filter.hidesWrappers) { model.filter.hidesWrappers.toggle() }
                    Chip(title: "App types", isOn: model.filter.appTypesOnly) { model.filter.appTypesOnly.toggle() }
                    Chip(title: "Re-rendered", isOn: model.filter.rerenderedOnly) { model.filter.rerenderedOnly.toggle() }
                        .disabled(!hasCounts)
                    Chip(title: "Has state", isOn: model.filter.statefulOnly) { model.filter.statefulOnly.toggle() }
                    Menu {
                        Picker("Module", selection: $model.filter.module) {
                            Text("All modules").tag(String?.none)
                            ForEach(modules, id: \.self) { Text($0).tag(Optional($0)) }
                        }
                    } label: {
                        ChipLabel(title: model.filter.module ?? "Module", systemImage: "chevron.down", isOn: model.filter.module != nil)
                    }
                    Menu {
                        Picker("Sort", selection: $model.filter.sort) {
                            ForEach(ComponentList.Filter.Sort.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                    } label: {
                        ChipLabel(title: model.filter.sort.title, systemImage: "arrow.up.arrow.down", isOn: false)
                    }
                }
                .padding(.horizontal, 16)
            }
            Text(model.point == nil ? "\(rowCount) components" : "\(rowCount) under the point, smallest first")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
            ForEach(shared, id: \.self) { line in
                Text(line).font(.caption2).foregroundStyle(.secondary).lineLimit(2).padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 4)
        .listRowInsets(EdgeInsets())
        .textCase(nil)
    }
}

private struct Chip: View {
    let title: String
    var systemImage: String?
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) { ChipLabel(title: title, systemImage: systemImage, isOn: isOn) }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

private struct ChipLabel: View {
    let title: String
    let systemImage: String?
    let isOn: Bool

    var body: some View {
        HStack(spacing: 3) {
            Text(title).lineLimit(1)
            if let systemImage { Image(systemName: systemImage).imageScale(.small) }
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .foregroundStyle(isOn ? Color.white : Color.primary)
        .background(isOn ? Color.accentColor : Color.secondary.opacity(0.15), in: Capsule())
        .fixedSize()
    }
}

// MARK: - Rows

private struct ComponentRowView: View {
    let item: ComponentList.Item
    let parent: String?
    let renders: RenderCounts.Entry?
    let isSelected: Bool
    let select: () -> Void
    let info: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: select) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.node.title)
                            .font(.subheadline.weight(isSelected ? .semibold : .regular))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .layoutPriority(1)
                        Spacer(minLength: 0)
                        if let renders, renders.count > 0, renders.instances == 1 {
                            Text(renders.label)
                                .font(.caption2.monospacedDigit().weight(.semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color(InspectorRenderer.heatColor(1)).opacity(0.2), in: Capsule())
                                .fixedSize()
                                .accessibilityLabel("\(renders.label) renders")
                        }
                    }
                    HStack(spacing: 6) {
                        Text(caption)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                        if !item.wrappers.isEmpty {
                            Text("+\(item.wrappers.count) wrappers")
                                .padding(.horizontal, 5)
                                .background(Color.secondary.opacity(0.15), in: Capsule())
                                .fixedSize()
                        }
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(action: info) { Image(systemName: "info.circle") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Details of \(item.node.title)")
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 12))
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.12) : nil)
    }

    private var caption: String {
        item.frame.frameLabel + (parent.map { " · in \($0)" } ?? "")
    }
}

// MARK: - Details

private struct ComponentDetailView: View {
    let snapshot: DetailSnapshot
    let renders: RenderCounts.Entry?
    let select: () -> Void
    let open: (ComponentList.Item) -> Void

    private var node: InspectorNode { snapshot.node }
    private var details: ComponentDetails { snapshot.details }

    var body: some View {
        List {
            Section {
                LabeledContent("Type") { Text(AttributeGraphTree.readable(node.typeName)).lineLimit(3).truncationMode(.middle) }
                LabeledContent("Frame", value: snapshot.item.frame.frameLabel)
                if let renders { LabeledContent("Re-renders", value: renders.label) }
            }
            let parents = parents
            if !parents.isEmpty {
                Section("Parents") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(Array(parents.enumerated()), id: \.offset) { index, parent in
                                if index > 0 { Image(systemName: "chevron.right").imageScale(.small).foregroundStyle(.tertiary) }
                                Button(parent.node.title) { open(parent) }
                                    .font(.footnote)
                                    .lineLimit(1)
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }
            let children = snapshot.item.children.map { snapshot.items[$0] }
            if !children.isEmpty {
                Section("Children – \(children.count)") {
                    ForEach(children) { child in
                        Button { open(child) } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(child.node.title).font(.subheadline).lineLimit(1).truncationMode(.middle)
                                Text(child.frame.frameLabel + (child.wrappers.isEmpty ? "" : " · +\(child.wrappers.count) wrappers"))
                                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !snapshot.item.wrappers.isEmpty {
                Section {
                    ForEach(snapshot.item.wrappers + [node], id: \.id) { wrapper in
                        HStack {
                            Text(wrapper.title).font(.footnote.weight(wrapper === node ? .semibold : .regular))
                                .lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(wrapper.frame.frameLabel).font(.caption2.monospacedDigit()).foregroundStyle(.secondary).fixedSize()
                        }
                    }
                } header: {
                    Text("Wrapped in – \(snapshot.item.wrappers.count)")
                } footer: {
                    Text("Views and modifiers of the same size around it, outermost first.")
                }
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
                            Text(property.name).font(.subheadline.monospaced()).lineLimit(1)
                            Text(property.type).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
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

    private var parents: [ComponentList.Item] {
        var result: [ComponentList.Item] = []
        var current = snapshot.item.parent
        while let index = current { result.insert(snapshot.items[index], at: 0); current = snapshot.items[index].parent }
        return result
    }
}

#endif
