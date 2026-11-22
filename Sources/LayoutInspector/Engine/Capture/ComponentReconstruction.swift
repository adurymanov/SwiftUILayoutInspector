#if LayoutInspectorEngine && !LAYOUT_INSPECTOR_DISABLED && os(iOS)
import UIKit

/// Restores app-defined views (`ProfileHeader`, `StatsRow`, `TagCloud`…) in the `_ViewDebug` tree.
///
/// Why: on iOS 18+ `_ViewDebug` only serialises *view* tree elements. App views inside stacks are built as
/// *view lists* (flag 1 in AttributeGraph) and are dropped – their content is hoisted into the parent.
/// AttributeGraph still has those list elements, together with the chain of types the view's `body`
/// resolves to (`ProfileHeader` → `HStack<TupleView<(…)>>`). We read that chain, find the same chain of
/// types in the `_ViewDebug` tree and insert a synthetic component node above it.
///
/// Custom `Layout`s are hoisted the same way (their subviews end up in the parent), so for
/// `body = FlowLayout { ForEach … }` we match the ForEach *items* and group them back.
struct ComponentReconstruction {
    struct Component {
        let typeName: String
        let name: String
        let chain: [String]              // body type chain, outermost first (includes nested app views' chains)
        var hoistedLayout: (name: String, typeName: String, itemChains: [[String]])?
        /// Indices of `chain` that may anchor it: generic or app types (see `mayAnchor`), worked out once. Whether
        /// one is only a wrapper (`isUninformative`) is checked for the ones a host's tree has.
        var anchorable: [Int] = []
        /// How many of it AttributeGraph holds, in every host.
        var instances = 1
        /// Its place in `components`.
        var id = 0
    }

    private(set) var components: [Component] = []
    /// The app types among the trees' elements, by full type name: which are `ViewModifier`s is asked off the main
    /// thread (``ModifierTypes``).
    private(set) var appTypeNames: [String] = []
    /// Components by the chain types that may anchor them: a host whose tree has none of a component's anchors skips
    /// it without looking each one up.
    private var byAnchor: [TypeKey: [Int]] = [:]
    /// Chains and names as bytes, for the views that pairs read: built once for the index, which later captures reuse.
    private let texts = Texts()

    private final class Texts {
        var chains: [Int: ASCIIText] = [:]
        var names: [Int: ASCIIText] = [:]
    }
    /// Human-readable matching log (exposed via `LayoutCapture.lastReconstructionLog`).
    static var log: [String] = []

    /// Where building the index went, for `LayoutCapture.lastTimings` (diagnostics).
    static var phases: [(String, Double)] = []
    /// Where applying went in the current capture, summed over its hosts (reset with `log`).
    static var applySpent: [String: Double] = [:]

    private static func timedApply<T>(_ key: String, _ body: () -> T) -> T {
        let start = CACurrentMediaTime()
        defer { applySpent[key, default: 0] += CACurrentMediaTime() - start }
        return body()
    }

    init(trees: [AttributeGraphTree.Element]) {
        var spent: [String: Double] = [:]
        func timed<T>(_ key: String, _ body: () -> T) -> T {
            let start = CACurrentMediaTime()
            defer { spent[key, default: 0] += CACurrentMediaTime() - start }
            return body()
        }
        let started = CACurrentMediaTime()
        var firstByType: [TypeKey: AttributeGraphTree.Element] = [:]
        timed("types") { for tree in trees { index(tree, into: &firstByType) } }

        var seen = Set<String>()
        // Counted by type, then by name: hashing every element's name (kilobytes for a long modifier chain) is slow.
        var countsByType: [UnsafeRawPointer: (name: String, count: Int)] = [:]
        var countsWithoutType: [String: Int] = [:]
        for tree in trees {
            visit(tree) { element in
                if let id = element.typeID {
                    countsByType[id, default: (element.typeName, 0)].count += 1
                } else {
                    countsWithoutType[element.typeName, default: 0] += 1
                }
                guard element.flags == 1, Self.isReconstructable(element.typeName) else { return }
                guard !seen.contains(element.typeName), !element.children.isEmpty else { return }
                seen.insert(element.typeName)
                let chain = timed("chains") { Self.chain(from: element) }
                var component = Component(typeName: element.typeName, name: TypeNames.shortName(of: element.typeName), chain: chain)
                component.anchorable = timed("anchors") { chain.indices.filter { Self.mayAnchor(chain[$0]) } }
                if let last = chain.last, let layout = timed("layouts", { Self.hoistedLayout(last, firstByType: firstByType) }) {
                    component.hoistedLayout = layout
                }
                component.id = components.count
                components.append(component)
            }
        }
        var instances = countsWithoutType
        for entry in countsByType.values { instances[entry.name, default: 0] += entry.count }
        let appTypes = countsByType.compactMap { id, entry in
            TypeNames.isAppType(entry.name) ? (name: entry.name, type: unsafeBitCast(id, to: Any.Type.self)) : nil
        }
        appTypeNames = appTypes.map(\.name)
        ModifierTypes.ask(appTypes)
        for i in components.indices { components[i].instances = instances[components[i].typeName] ?? 1 }
        timed("anchorIndex") {
            for component in components {
                for i in component.anchorable { byAnchor[TypeKey(component.chain[i]), default: []].append(component.id) }
            }
        }
        spent["rest"] = CACurrentMediaTime() - started - spent.values.reduce(0, +)
        Self.phases = spent.sorted { $0.value > $1.value }
    }

    /// SwiftUI views that are built as view lists too (and therefore missing from `_ViewDebug`).
    /// (Toggle/TextField/Picker rows share most internals with `LabeledContent` – too ambiguous to match by type;
    /// they are recognised from their `Switch` / `SystemTextField` leaves instead.)
    static let systemViews = ["Button", "NavigationLink", "Menu", "Link", "ShareLink", "ScrollView", "List", "ProgressView"]

    static func isReconstructable(_ typeName: String) -> Bool {
        if TypeNames.isAppType(typeName) { return true }
        guard typeName.hasPrefix("SwiftUI.") else { return false }
        let base = String(typeName.dropFirst("SwiftUI.".count).prefix { $0 != "<" })
        // `Button<PrimitiveButtonStyleConfiguration.Label>` etc. are SwiftUI re-wrapping its own content.
        return systemViews.contains(base) && !typeName.contains("Configuration")
    }

    private func index(_ e: AttributeGraphTree.Element, into map: inout [TypeKey: AttributeGraphTree.Element]) {
        let key = TypeKey(e.typeName)
        if let known = map[key] {
            if known.children.isEmpty && !e.children.isEmpty { map[key] = e }
        } else {
            map[key] = e
        }
        e.children.forEach { index($0, into: &map) }
    }

    private func visit(_ e: AttributeGraphTree.Element, _ body: (AttributeGraphTree.Element) -> Void) {
        body(e)
        e.children.forEach { visit($0, body) }
    }

    /// Types along the first-child path below `element` (continuing through nested app views).
    static func chain(from element: AttributeGraphTree.Element) -> [String] {
        var result: [String] = []
        var current = element
        var steps = 0
        while let next = current.children.first, steps < 200 {
            if next.typeName != "?" { result.append(next.typeName) }
            current = next
            steps += 1
            if next.flags == 0 && next.typeName != "?" && !TypeNames.isAppType(next.typeName) { break }
        }
        return result
    }

    /// `_VariadicView.Tree<_LayoutRoot<FlowLayout>, ForEach<…>>` – a custom Layout, never present in `_ViewDebug`.
    private static func hoistedLayout(_ type: String, firstByType: [TypeKey: AttributeGraphTree.Element]) -> (String, String, [[String]])? {
        guard type.hasPrefix("SwiftUI._VariadicView.Tree<") else { return nil }
        let fullArgs = TypeNames.genericArguments(of: type)
        guard fullArgs.count == 2, fullArgs[0].contains("_LayoutRoot<") else { return nil }
        let layoutType = String(fullArgs[0].drop { $0 != "<" }.dropFirst().dropLast())
        var contentTypes = [fullArgs[1]]
        if fullArgs[1].hasPrefix("SwiftUI.TupleView<") {
            let tuple = TypeNames.genericArguments(of: fullArgs[1]).first ?? ""
            contentTypes = TypeNames.genericArguments(of: "X<" + tuple.dropFirst().dropLast() + ">")
        }
        let itemChains = contentTypes.compactMap { firstByType[TypeKey($0)].map(chain(from:)) }.filter { !$0.isEmpty }
        return (TypeNames.shortName(of: layoutType), layoutType, itemChains)
    }

    // MARK: - Applying to the `_ViewDebug` tree

    /// A type name as a dictionary key that hashes its length and three 32-byte slices instead of the whole name:
    /// names of long modifier chains run to tens of kilobytes, and every host looks up every chain type. Two keys are
    /// equal when their names are the same bytes. Names of one type always are: AttributeGraph and `_ViewDebug` names
    /// both come from the type's metadata. (A `String` key would also match a differently composed `é`.)
    struct TypeKey: Hashable {
        let name: String
        private let sample: Int

        init(_ name: String) {
            var name = name
            name.makeContiguousUTF8()
            var hasher = Hasher()
            name.utf8.withContiguousStorageIfAvailable { bytes in
                let raw = UnsafeRawBufferPointer(bytes), n = raw.count, width = 32
                hasher.combine(n)
                if n <= 3 * width {
                    hasher.combine(bytes: raw)
                } else {
                    hasher.combine(bytes: UnsafeRawBufferPointer(rebasing: raw[0..<width]))
                    hasher.combine(bytes: UnsafeRawBufferPointer(rebasing: raw[(n / 2 - width / 2)..<(n / 2 + width / 2)]))
                    hasher.combine(bytes: UnsafeRawBufferPointer(rebasing: raw[(n - width)..<n]))
                }
            }
            self.name = name
            sample = hasher.finalize()
        }

        static func == (a: TypeKey, b: TypeKey) -> Bool { a.sample == b.sample && a.name == b.name }
        func hash(into hasher: inout Hasher) { hasher.combine(sample) }
    }

    /// A view that took a node: system views by name (one per node, see `apply`), app views by component.
    private struct Claim: Hashable {
        enum View: Hashable { case system(String), app(Int) }
        let view: View
        let root: ObjectIdentifier
    }

    /// Wrapper types that show up everywhere – useless as anchors.
    private static let genericBases: Set<String> = [
        "EmptyModifier", "HiddenForReuseEffect", "AccessibilityAttachmentModifier", "_ViewList_View",
        "PlaceholderContentView", "OpacityRendererEffect", "_ViewModifier_Content",
    ]

    /// Inserts synthetic component nodes into `roots` (mutates the raw tree in place).
    func apply(to roots: [RawDebugNode]) {
        // "rest" is what no phase covers.
        func counted() -> Double { Self.applySpent.filter { $0.key != "rest" }.values.reduce(0, +) }
        let started = CACurrentMediaTime(), countedBefore = counted()
        defer { Self.applySpent["rest", default: 0] += CACurrentMediaTime() - started - (counted() - countedBefore) }
        var byType: [TypeKey: [RawDebugNode]] = [:]
        var anchored = Set<Int>()
        Self.timedApply("byType") {
            for root in roots { root.forEach { byType[TypeKey($0.typeName), default: []].append($0) } }
            for key in byType.keys { byAnchor[key]?.forEach { anchored.insert($0) } }
        }

        // Outer components first: when two components resolve to the same node, the outer one ends up on top.
        let ordered = components.sorted { $0.chain.count > $1.chain.count }
        var claimed = Set<Claim>()
        // App views wrapped around each node so far, and nodes two unrelated views both claimed.
        var wrappers: [ObjectIdentifier: [(component: Component, node: RawDebugNode)]] = [:]
        var contested: [ObjectIdentifier: [Component]] = [:]
        // Whether one view is built from the other reads both chains, kilobytes of type names: once per pair.
        var nestedPairs: [Int: Bool] = [:]
        func chain(of component: Component) -> ASCIIText {
            if let known = texts.chains[component.id] { return known }
            let text = ASCIIText(lines: component.chain)
            texts.chains[component.id] = text
            return text
        }
        func name(of component: Component) -> ASCIIText {
            if let known = texts.names[component.id] { return known }
            let text = ASCIIText(name: component.typeName)
            texts.names[component.id] = text
            return text
        }
        func isNested(_ a: Component, _ b: Component) -> Bool {
            let key = min(a.id, b.id) << 32 | max(a.id, b.id)
            if let known = nestedPairs[key] { return known }
            let result = Self.timedApply("nested") {
                if let aChain = chain(of: a).bytes, let bChain = chain(of: b).bytes,
                   let aName = name(of: a).bytes, let bName = name(of: b).bytes {
                    return Self.mentions(in: aChain, bName) || Self.mentions(in: bChain, aName)
                }
                return Self.isNested(a, b)
            }
            nestedPairs[key] = result
            return result
        }

        for component in ordered {
            if let layout = component.hoistedLayout {
                Self.timedApply("hoisted") { applyHoisted(component, layout: layout, byType: byType) }
                continue
            }
            let isSystem = !TypeNames.isAppType(component.typeName)
            guard anchored.contains(component.id) else {
                Self.log.append("\(component.name): no anchor")
                continue
            }
            guard let placement = placements(of: component, isSystem: isSystem, byType: byType) else { continue }
            let match = placement.anchor
            var count = 0
            for root in placement.roots {
                // System views erase their content type (Button<A> and Button<B> share internals) – one per root.
                let key = Claim(view: isSystem ? .system(component.name) : .app(component.id), root: ObjectIdentifier(root))
                if claimed.contains(key) { continue }
                claimed.insert(key)
                // Two app views claim the same node and neither is part of the other's body: sibling views built the
                // same way (`HomeTab` and `InboxTab`, both `TabButton(…)`) in hosts that hold one of them
                // each. Which one this is cannot be told, so the node gets neither.
                let id = ObjectIdentifier(root)
                if !isSystem {
                    if contested[id]?.contains(where: { !isNested(component, $0) }) == true { continue }
                    let rivals = wrappers[id, default: []].filter { !isNested(component, $0.component) }
                    if !rivals.isEmpty {
                        Self.timedApply("wrap") { rivals.forEach { unwrap($0.node) } }
                        wrappers[id]?.removeAll { wrapper in rivals.contains { $0.node === wrapper.node } }
                        contested[id, default: []] += rivals.map(\.component) + [component]
                        Self.log.append("\(component.name): same node as \(rivals.map(\.component.name).joined(separator: ", ")), left unnamed")
                        continue
                    }
                }
                let readable = isSystem ? AttributeGraphTree.readable(component.typeName) : component.name
                let synthetic = Self.timedApply("wrap") { wrap([root], typeName: component.typeName, readable: readable) }
                if !isSystem { wrappers[id, default: []].append((component, synthetic)) }
                count += 1
            }
            Self.log.append("\(component.name): anchor \(AttributeGraphTree.readablePrefix(component.chain[match], 70)) → \(count)")
        }
    }

    /// The nodes `component` wraps: the roots its most specific anchor climbs to, without the ones that are a node
    /// of its type already (an app's `GeometryEffect` or `ViewModifier` is in `_ViewDebug` itself). An anchor that
    /// leads to more nodes than the view has instances is not this view's, the name would land on unrelated nodes:
    /// the next anchor is tried, and with none left the view stays unnamed.
    private func placements(of component: Component, isSystem: Bool,
                            byType: [TypeKey: [RawDebugNode]]) -> (anchor: Int, roots: [RawDebugNode])? {
        // Most chain types are not in the tree: the wrapper check, which reads the whole (possibly huge) type, only
        // runs for the ones that are.
        // Node lists and name lengths are looked up once per candidate, not in every comparison of the sort.
        let candidates = Self.timedApply("lookups") {
            component.anchorable.compactMap { i -> (index: Int, nodes: [RawDebugNode], length: Int)? in
                guard let nodes = byType[TypeKey(component.chain[i])], !nodes.isEmpty else { return nil }
                guard !Self.isUninformative(component.chain[i]) else { return nil }
                return (i, nodes, component.chain[i].count)
            }.sorted { a, b in
                if a.nodes.count != b.nodes.count { return a.nodes.count < b.nodes.count }
                if a.length != b.length { return a.length > b.length }
                return a.index < b.index
            }
        }
        guard !candidates.isEmpty else {
            Self.log.append("\(component.name): no anchor")
            return nil
        }
        let limit = max(2 * component.instances, component.instances + 2)
        for candidate in candidates {
            let index = candidate.index
            var roots: [RawDebugNode] = []
            var found = Set<ObjectIdentifier>()
            Self.timedApply("climb") {
                for node in candidate.nodes {
                    let root = climb(from: node, chain: component.chain, anchorIndex: index)
                    if found.contains(ObjectIdentifier(root)) || Self.hasNode(ofType: component.typeName, above: root) { continue }
                    found.insert(ObjectIdentifier(root))
                    roots.append(root)
                }
            }
            if isSystem || roots.count <= limit { return (index, roots) }
            Self.log.append("\(component.name): anchor \(AttributeGraphTree.readablePrefix(component.chain[index], 70)) "
                            + "ambiguous, \(roots.count) nodes for \(component.instances)")
        }
        return nil
    }

    /// Chain types that can anchor a component. Plain `Text`, `_PaddingLayout`, `Spacer`… say nothing about
    /// *which* view this is, nor do the wrappers that show up everywhere.
    private static func anchorableIndices(_ chain: [String]) -> [Int] {
        chain.indices.filter { mayAnchor(chain[$0]) && !isUninformative(chain[$0]) }
    }

    /// A generic or app type: the cheap half of being an anchor, read from the start of the name.
    private static func mayAnchor(_ type: String) -> Bool {
        type.contains("<") || TypeNames.isAppType(type)
    }

    /// A wrapper that shows up everywhere, or one built only of them:
    /// `ModifiedContent<PlaceholderContentView<OpacityTransition>, OpacityRendererEffect>` is in every view with an
    /// opacity transition.
    ///
    /// Only `ModifiedContent` and `_ConditionalContent` are read past their base name, in one pass (`TypeShape`).
    /// Splitting a type into generic arguments level by level, as `TypeNames.genericArguments` does, rescans the
    /// string at every level: a view with a long modifier chain is `ModifiedContent<ModifiedContent<…>, …>` hundreds
    /// of levels deep and tens of kilobytes long, and a large app's screen took seconds.
    static func isUninformative(_ type: String) -> Bool {
        if let cached = uninformative[type] { return cached }
        // The name before the first `<` decides, as in `isUninformativeSlow`, for all but the two wrappers whose
        // arguments are read: no need to read the whole type (`TypeShape` reads it byte by byte).
        let base = TypeNames.base(of: TypeNames.shortName(of: type))
        let result = base == "ModifiedContent" || base == "_ConditionalContent"
            ? TypeShape(type).map { $0.isUninformative($0.whole) } ?? isUninformativeSlow(type)
            : genericBases.contains(base)
        uninformative[type] = result
        return result
    }

    /// Chain types repeat across components and captures (a view's chain includes the chains of the views it is
    /// built from).
    private static var uninformative: [String: Bool] = [:]

    static func resetTypeCache() { uninformative = [:] }

    /// Chain types for which the one-pass reading and the straightforward one disagree (diagnostics; slow).
    func typeShapeMismatches() -> (checked: Int, mismatches: [String]) {
        var seen = Set<String>()
        var mismatches: [String] = []
        for component in components {
            for type in component.chain where seen.insert(type).inserted {
                if isUninformativeFast(type) != Self.isUninformativeSlow(type) { mismatches.append(type) }
            }
        }
        return (seen.count, mismatches)
    }

    private func isUninformativeFast(_ type: String) -> Bool { Self.isUninformative(type) }

    /// The same, the straightforward way: for types `TypeShape` does not take (`->` in a function type).
    static func isUninformativeSlow(_ type: String) -> Bool {
        let base = TypeNames.base(of: TypeNames.shortName(of: type))
        if genericBases.contains(base) { return true }
        guard base == "ModifiedContent" || base == "_ConditionalContent" else { return false }
        let arguments = TypeNames.genericArguments(of: type)
        return !arguments.isEmpty && arguments.allSatisfy(isUninformativeSlow)
    }

    /// A type name with its brackets matched once, so that every nested generic argument is found without scanning
    /// the string again. Reads ranges exactly the way `TypeNames.shortName`, `base` and `genericArguments` read
    /// strings. `nil` for names whose brackets do not pair up (a function type's `->`), which those read differently.
    struct TypeShape {
        let bytes: [UInt8]
        /// For every `<`, `(`, `{`, `[`: the position of its closing bracket (-1 elsewhere).
        private var close: [Int32]
        /// The first `<` at or after each position.
        private var nextOpenAngle: [Int32]

        var whole: Range<Int> { 0..<bytes.count }

        init?(_ type: String) {
            bytes = Array(type.utf8)
            if zip(bytes, bytes.dropFirst()).contains(where: { $0 == UInt8(ascii: "-") && $1 == UInt8(ascii: ">") }) { return nil }
            close = Array(repeating: -1, count: bytes.count)
            nextOpenAngle = Array(repeating: Int32(bytes.count), count: bytes.count + 1)
            var stack: [Int] = []
            for (i, byte) in bytes.enumerated() {
                switch byte {
                case UInt8(ascii: "<"), UInt8(ascii: "("), UInt8(ascii: "{"), UInt8(ascii: "["): stack.append(i)
                case UInt8(ascii: ">"), UInt8(ascii: ")"), UInt8(ascii: "}"), UInt8(ascii: "]"):
                    guard let open = stack.popLast() else { return nil }
                    close[open] = Int32(i)
                default: break
                }
            }
            guard stack.isEmpty else { return nil }
            for i in stride(from: bytes.count - 1, through: 0, by: -1) {
                nextOpenAngle[i] = bytes[i] == UInt8(ascii: "<") ? Int32(i) : nextOpenAngle[i + 1]
            }
        }

        func isUninformative(_ range: Range<Int>) -> Bool {
            let next = Int(nextOpenAngle[range.lowerBound])
            let open = next < range.upperBound ? next : nil
            let base = shortName(range.lowerBound..<(open ?? range.upperBound))
            if genericBases.contains(base) { return true }
            guard base == "ModifiedContent" || base == "_ConditionalContent" else { return false }
            guard let arguments = genericArguments(range, open: open) else {
                return ComponentReconstruction.isUninformativeSlow(String(decoding: bytes[range], as: UTF8.self))
            }
            return !arguments.isEmpty && arguments.allSatisfy(isUninformative)
        }

        /// `TypeNames.shortName` of a name without generic arguments: after the last `).`, else after the last `.`.
        private func shortName(_ range: Range<Int>) -> String {
            var start = range.lowerBound
            var i = range.upperBound - 1
            var lastDot: Int?
            while i > range.lowerBound {
                if bytes[i] == UInt8(ascii: "."), bytes[i - 1] == UInt8(ascii: ")") { start = i + 1; lastDot = nil; break }
                if bytes[i] == UInt8(ascii: "."), lastDot == nil { lastDot = i }
                i -= 1
            }
            if start == range.lowerBound {
                if let lastDot { start = lastDot + 1 }
                else if range.upperBound > range.lowerBound, bytes[range.lowerBound] == UInt8(ascii: ".") { start = range.lowerBound + 1 }
            }
            return String(decoding: bytes[start..<range.upperBound], as: UTF8.self)
        }

        /// `TypeNames.genericArguments`: the arguments between the first `<` and a closing `>` that ends the range,
        /// split at the commas directly inside, trimmed; the last one only when not empty. `nil` when that `<` does
        /// not close at the end of the range, which only the slow way reads like `genericArguments` does.
        private func genericArguments(_ range: Range<Int>, open: Int?) -> [Range<Int>]? {
            guard let open, bytes[range.upperBound - 1] == UInt8(ascii: ">") else { return [] }
            guard Int(close[open]) == range.upperBound - 1 else { return nil }
            // The commas directly inside: nested brackets are jumped over, so every level reads only its own text.
            var result: [Range<Int>] = []
            var start = open + 1
            var i = start
            let end = range.upperBound - 1
            while i < end {
                if close[i] >= 0 {
                    i = Int(close[i]) + 1
                } else {
                    if bytes[i] == UInt8(ascii: ",") {
                        result.append(trimmed(start..<i))
                        start = i + 1
                    }
                    i += 1
                }
            }
            if start < end { result.append(trimmed(start..<end)) }
            return result
        }

        private func trimmed(_ range: Range<Int>) -> Range<Int> {
            var lower = range.lowerBound, upper = range.upperBound
            while lower < upper, bytes[lower] == UInt8(ascii: " ") || bytes[lower] == UInt8(ascii: "\t") { lower += 1 }
            while upper > lower, bytes[upper - 1] == UInt8(ascii: " ") || bytes[upper - 1] == UInt8(ascii: "\t") { upper -= 1 }
            return lower..<upper
        }
    }

    /// One of the two views is built from the other (`InboxTab`'s body is a `TabButton`).
    private static func isNested(_ a: Component, _ b: Component) -> Bool {
        a.chain.contains { mentions($0, b.typeName) } || b.chain.contains { mentions($0, a.typeName) }
    }

    /// Type names as bytes, one per line, for searching them without decoding Characters: `nil` unless every
    /// Character of every name is one byte (ASCII without CR LF; runtime type names are). LF separates the lines; like
    /// the start and end of a name it is not part of a name, so a search for a name without LF reads the lines exactly
    /// as it would read each name on its own.
    struct ASCIIText {
        let bytes: [UInt8]?

        init(lines: [String]) {
            var bytes: [UInt8] = []
            bytes.reserveCapacity(lines.reduce(0) { $0 + $1.utf8.count + 1 })
            for (n, line) in lines.enumerated() {
                guard line.utf8.count == line.count else { self.bytes = nil; return }
                if n > 0 { bytes.append(UInt8(ascii: "\n")) }
                bytes.append(contentsOf: line.utf8)
            }
            self.bytes = bytes
        }

        /// A name to search for: one non-empty line.
        init(name: String) {
            guard !name.isEmpty, let line = ASCIIText(lines: [name]).bytes else { bytes = nil; return }
            let hasLineBreak = line.withUnsafeBufferPointer { memchr($0.baseAddress, Int32(UInt8(ascii: "\n")), $0.count) != nil }
            bytes = hasLineBreak ? nil : line
        }
    }

    /// `mentions` over lines of `ASCIIText`: `name` stands in one of them on its own or as a generic argument.
    static func mentions(in text: [UInt8], _ name: [UInt8]) -> Bool {
        guard !name.isEmpty, text.count >= name.count else { return false }
        func isNamePart(_ byte: UInt8) -> Bool {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "_"), UInt8(ascii: "."): return true
            default: return false
            }
        }
        return text.withUnsafeBufferPointer { haystack in
            name.withUnsafeBufferPointer { needle in
                guard let start = haystack.baseAddress, let nameStart = needle.baseAddress else { return false }
                var from = 0
                while haystack.count - from >= needle.count,
                      let hit = memmem(start + from, haystack.count - from, nameStart, needle.count) {
                    let at = start.distance(to: hit.assumingMemoryBound(to: UInt8.self))
                    let end = at + needle.count
                    if (at == 0 || !isNamePart(haystack[at - 1])) && (end == haystack.count || !isNamePart(haystack[end])) { return true }
                    from = end
                }
                return false
            }
        }
    }

    /// `type` is `name` or has it among its generic arguments (`ModifiedContent<…, Demo.CardStyle>`).
    static func mentions(_ type: String, _ name: String) -> Bool {
        var start = type.startIndex
        while let range = type.range(of: name, range: start..<type.endIndex) {
            let before = range.lowerBound == type.startIndex ? nil : type[type.index(before: range.lowerBound)]
            let after = range.upperBound == type.endIndex ? nil : type[range.upperBound]
            let boundary: (Character?) -> Bool = { c in c.map { !($0.isLetter || $0.isNumber || $0 == "_" || $0 == ".") } ?? true }
            if boundary(before), boundary(after) { return true }
            start = range.upperBound
        }
        return false
    }

    /// Takes a synthetic node out again, its children in its place.
    private func unwrap(_ synthetic: RawDebugNode) {
        guard let parent = synthetic.parent, let index = parent.children.firstIndex(where: { $0 === synthetic }) else { return }
        parent.children.replaceSubrange(index...index, with: synthetic.children)
        synthetic.children.forEach { $0.parent = parent }
        synthetic.children = []
    }

    /// A node of `type` right above `node`, in the chain of single children that leads to it.
    private static func hasNode(ofType type: String, above node: RawDebugNode) -> Bool {
        var current = node.parent
        var below = node
        var steps = 0
        while let p = current, steps < 8 {
            if !p.isSynthetic, p.typeName == type { return true }
            guard p.children.count == 1, p.children[0] === below else { return false }
            below = p
            current = p.parent
            steps += 1
        }
        return false
    }

    /// The most specific chain type present in the `_ViewDebug` tree: fewest occurrences, then the most detailed
    /// type name.
    private func anchor(in chain: [String], anchorable: [Int]? = nil, byType: [TypeKey: [RawDebugNode]]) -> Int? {
        let candidates = (anchorable ?? Self.anchorableIndices(chain)).compactMap { i -> (index: Int, count: Int, length: Int)? in
            guard let nodes = byType[TypeKey(chain[i])], !nodes.isEmpty else { return nil }
            return (i, nodes.count, chain[i].count)
        }
        return candidates.min { a, b in
            if a.count != b.count { return a.count < b.count }
            if a.length != b.length { return a.length > b.length }
            return a.index < b.index
        }?.index
    }

    /// Walks up from the anchor while ancestors are earlier links of the same chain (monotonically).
    private func climb(from node: RawDebugNode, chain: [String], anchorIndex: Int) -> RawDebugNode {
        var root = node
        var index = anchorIndex
        var misses = 0
        var current = node.parent
        while let a = current, misses < 8, index > 0 {
            if !a.isSynthetic, let i = chain[..<index].lastIndex(of: a.typeName) {
                root = a
                index = i
                misses = 0
            } else {
                misses += 1
            }
            current = a.parent
        }
        return root
    }

    private func applyHoisted(_ component: Component, layout: (name: String, typeName: String, itemChains: [[String]]),
                              byType: [TypeKey: [RawDebugNode]]) {
        var items: [RawDebugNode] = []
        for itemChain in layout.itemChains {
            guard let match = anchor(in: itemChain, byType: byType) else { continue }
            for node in byType[TypeKey(itemChain[match])] ?? [] {
                let root = climb(from: node, chain: itemChain, anchorIndex: match)
                if !items.contains(where: { $0 === root }) { items.append(root) }
            }
        }
        Self.log.append("\(component.name): layout \(layout.name) chains \(layout.itemChains.map(\.count)) items \(items.count)")
        // Group by parent: every group is one instance of the custom layout.
        var groups: [ObjectIdentifier: [RawDebugNode]] = [:]
        var order: [ObjectIdentifier] = []
        for var item in items {
            // Lift the item to its slot in the container (top of its single-child chain).
            while let p = item.parent, p.children.count == 1, p.parent != nil { item = p }
            guard let parent = item.parent else { continue }
            let id = ObjectIdentifier(parent)
            if groups[id] == nil { order.append(id) }
            if !(groups[id]?.contains { $0 === item } ?? false) { groups[id, default: []].append(item) }
        }
        for id in order {
            guard let group = groups[id] else { continue }
            let layoutNode = wrap(group, typeName: "SwiftUI._VariadicView.Tree<SwiftUI._LayoutRoot<\(layout.typeName)>, Content>",
                                  readable: "_VariadicView.Tree<_LayoutRoot<\(layout.name)>, Content>")
            wrap([layoutNode], typeName: component.typeName, readable: component.name)
        }
    }

    /// Replaces `nodes` (siblings) with a synthetic node containing them.
    @discardableResult
    private func wrap(_ nodes: [RawDebugNode], typeName: String, readable: String) -> RawDebugNode {
        let parent = nodes.first?.parent
        let boxes = nodes.compactMap(\.firstGeometry)
        let union = boxes.dropFirst().reduce(boxes.first) { $0?.union($1) }
        // A single wrapped node keeps inheriting geometry exactly like the original did.
        let geometry = nodes.count == 1 ? nodes[0].geometry : union
        let synthetic = RawDebugNode(syntheticType: typeName, readable: readable, children: nodes, geometry: geometry)
        if let parent, let index = parent.children.firstIndex(where: { $0 === nodes[0] }) {
            parent.children.removeAll { child in nodes.contains { $0 === child } }
            parent.children.insert(synthetic, at: min(index, parent.children.count))
            synthetic.parent = parent
        }
        return synthetic
    }
}

#endif
