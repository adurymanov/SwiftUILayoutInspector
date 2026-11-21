#if LayoutInspectorEngine && !LAYOUT_INSPECTOR_DISABLED && os(iOS)
import SwiftUI
import UIKit
internal import LayoutInspectorAttributeGraph

/// One app view as AttributeGraph holds it.
struct GraphView {
    /// The graph nodes its tree element owns; its `body` is one of them.
    let nodes: [UInt32]
    /// The node that holds the view's value (the struct its parent built).
    let valueNode: UInt32
    let type: Any.Type
}

/// Finds the AttributeGraph views behind the components of a capture.
///
/// The graph often holds more views of a type than the capture shows (rows of a lazy stack off screen, hidden copies),
/// and lists them in an order of its own (rows of a `ForEach` come in another order on iOS 26 than on iOS 27). A
/// component is matched to the view built with the texts it shows: a design-system text component built with
/// "Payment 3" is the one whose `Text` says so. Views no text tells apart pair up with the components left, in screen
/// order, when there are as many of both; otherwise the components share those views' total.
enum ComponentGraph {
    struct Match {
        /// One view when the component was told apart, otherwise the views of its type it couldn't be told from.
        let views: [GraphView]
        var isExact: Bool { views.count == 1 }
    }

    /// Matches for the components of `capture`, by ``InspectorNode/id``. Empty when the graph can't be reached (iOS 18).
    /// Worked out once per capture.
    static func match(_ capture: InspectorCapture) -> [Int: Match] {
        if let cached = matchCache, cached.capture === capture { return cached.result }
        let result = freshMatch(capture)
        matchCache = (capture, result)
        return result
    }

    private static var matchCache: (capture: InspectorCapture, result: [Int: Match])?
    private static var viewsCache: (capture: InspectorCapture, result: [String: [GraphView]])?

    private static func freshMatch(_ capture: InspectorCapture) -> [Int: Match] {
        let views = views(in: capture)
        guard !views.isEmpty else { return [:] }
        var components: [String: [InspectorNode]] = [:]
        for root in capture.swiftUIRoots {
            root.forEach { if $0.kind == .component { components[$0.typeName, default: []].append($0) } }
        }
        var result: [Int: Match] = [:]
        for (type, nodes) in components {
            guard var left = views[type], !left.isEmpty else { continue }
            var unmatched: [InspectorNode] = []
            if left.count == 1, nodes.count == 1 {
                result[nodes[0].id] = Match(views: left)
                continue
            }
            // By text: the view whose own strings cover most of the component's texts, when that view is the only one.
            var strings = left.map(Self.strings(of:))
            for node in nodes.sorted(by: { $0.id < $1.id }) {
                let texts = Self.texts(in: node)
                guard !texts.isEmpty else { unmatched.append(node); continue }
                let overlaps = strings.map { $0.intersection(texts).count }
                let best = overlaps.max() ?? 0
                let tied = overlaps.indices.filter { overlaps[$0] == best }
                if best > 0, tied.count == 1 {
                    result[node.id] = Match(views: [left.remove(at: tied[0])])
                    strings.remove(at: tied[0])
                } else if best > 0 {
                    // Built with the same texts (a hidden copy, two identical labels): one total for those views.
                    result[node.id] = Match(views: tied.map { left[$0] })
                } else {
                    unmatched.append(node)
                }
            }
            guard !unmatched.isEmpty, !left.isEmpty else { continue }
            // Nothing tells the rest apart, and the graph's order isn't the screen's: one total for them, rather than
            // counts that look exact on the wrong view.
            for node in unmatched { result[node.id] = Match(views: left) }
        }
        return result
    }

    /// The strings of the texts inside a component.
    static func texts(in node: InspectorNode) -> Set<String> {
        var result = Set<String>()
        node.forEach { if let string = $0.info.text?.string, !string.isEmpty { result.insert(string) } }
        return result
    }

    /// The strings a view was built with, two levels deep (`title`, `line.title`), and the numbers as text: a text
    /// often shows one (`"$\(amount)"`).
    static func strings(of view: GraphView) -> Set<String> {
        guard let value = value(of: view) else { return [] }
        var result = Set<String>()
        func collect(_ value: Any, depth: Int) {
            for child in Mirror(reflecting: value).children {
                switch child.value {
                case let string as String: if !string.isEmpty { result.insert(string) }
                // Small numbers ("0", "1") are in every badge and index: they would tie a view to the wrong texts.
                case let number as any BinaryInteger where !(-9...9).contains(Int(number)): result.insert("\(number)")
                default: if depth < 2 { collect(child.value, depth: depth + 1) }
                }
            }
        }
        collect(value, depth: 0)
        // Texts that show a number with a prefix or suffix ("$40", "40 %") match by the number.
        return result.union(result.compactMap { Int($0) == nil ? nil : $0 }.flatMap { [$0, "$\($0)", "\($0) %"] })
    }

    /// App views of every hosting view of the capture's window, by type: the view types of a screen can be declared in
    /// the AttributeGraph tree of another host (the root host around a navigation stack).
    static func views(in capture: InspectorCapture) -> [String: [GraphView]] {
        if let cached = viewsCache, cached.capture === capture { return cached.result }
        var hosts: [UIView] = []
        for root in capture.swiftUIRoots {
            guard let host = root.anchor.view else { continue }
            let all = host.window.map { LayoutCapture.visibleHostingViews(in: $0, excluding: []) } ?? [host]
            for candidate in all where !hosts.contains(where: { $0 === candidate }) { hosts.append(candidate) }
        }
        var result: [String: [GraphView]] = [:]
        var seen = Set<UInt32>()
        for host in hosts {
            for (name, views) in views(of: host) {
                // A tree can include a nested host's elements: each view once.
                let fresh = views.filter { seen.insert($0.valueNode).inserted }
                result[name, default: []] += fresh
            }
        }
        viewsCache = (capture, result)
        return result
    }

    /// Types of the capture's app views that are `ViewModifier`s, by full type name.
    static func modifierTypes(in capture: InspectorCapture) -> Set<String> {
        Set(views(in: capture).compactMap { name, views in views.first.map { $0.type is any ViewModifier.Type } == true ? name : nil })
    }

    /// Every app view under `host`, by type.
    static func views(of host: UIView) -> [String: [GraphView]] {
        guard RenderProfiler.isAvailable, let subgraph = AttributeGraphTree.rootSubgraph(of: host),
              let root = LIAGSubgraphGetTreeRoot(subgraph) else { return [:] }
        var result: [String: [GraphView]] = [:]
        var children = [LIAGTreeElement?](repeating: nil, count: 1024)
        // Generous: a view's body node can come after every node of a long modifier chain.
        var nodes = [UInt32](repeating: 0, count: 1024)
        func visit(_ element: LIAGTreeElement, depth: Int) {
            if let meta = LIAGTreeElementGetType(element) {
                let type = unsafeBitCast(meta, to: Any.Type.self)
                let name = TypeNames.qualifiedName(of: type)
                if TypeNames.isAppType(name) {
                    let n = Int(nodes.withUnsafeMutableBufferPointer { LIAGTreeElementGetNodes(element, $0.baseAddress!, Int32($0.count)) })
                    // Modifiers often own no nodes of their own; they are listed all the same.
                    result[name, default: []].append(GraphView(nodes: Array(nodes[0..<max(n, 0)]),
                                                               valueNode: LIAGTreeElementGetValue(element), type: type))
                }
            }
            guard depth < 400 else { return }
            let n = Int(children.withUnsafeMutableBufferPointer { LIAGTreeElementGetChildren(element, $0.baseAddress!, Int32($0.count)) })
            let list = children[0..<n].compactMap { $0 }
            for child in list.reversed() { visit(child, depth: depth + 1) }
        }
        visit(root, depth: 0)
        return result
    }

    /// The view's current value, as its parent built it. `nil` when the graph can't be read.
    static func value(of view: GraphView) -> Any? {
        let meta = unsafeBitCast(view.type, to: UnsafeRawPointer.self)
        guard let pointer = LIAGGraphGetValue(view.valueNode, meta) else { return nil }
        func load<T>(_: T.Type) -> Any { pointer.assumingMemoryBound(to: T.self).pointee }
        return _openExistential(view.type, do: load)
    }
}

#endif
