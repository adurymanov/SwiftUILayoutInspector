#if LayoutInspectorEngine && !LAYOUT_INSPECTOR_DISABLED && os(iOS)
import UIKit
internal import LayoutInspectorAttributeGraph

/// One app view as AttributeGraph holds it.
struct GraphView {
    /// The graph nodes its tree element owns; its `body` is one of them.
    let nodes: [UInt32]
    /// The node that holds the view's value (the struct its parent built).
    let valueNode: UInt32
    let type: Any.Type
    /// Where SwiftUI placed the first view of its body, in the space `_ViewDebug` reports positions in. Only used to
    /// order views of one type.
    let origin: CGPoint?
}

/// Finds the AttributeGraph views behind the components of a capture.
///
/// Views of one type in a host are paired by position: top to bottom, then leading to trailing, in the capture and in
/// the graph. The order of AttributeGraph's children can't be used: rows of a `ForEach` come in a different order on
/// iOS 26 than on iOS 27. When the numbers differ (a view the capture could not place), every component of the type
/// gets all of the type's views.
enum ComponentGraph {
    struct Match {
        /// One view when the component was told apart, otherwise every view of its type in its host.
        let views: [GraphView]
        var isExact: Bool { views.count == 1 }
    }

    /// Matches for the components of `capture`, by ``InspectorNode/id``. Empty when the graph can't be reached (iOS 18).
    static func match(_ capture: InspectorCapture) -> [Int: Match] {
        var result: [Int: Match] = [:]
        for root in capture.swiftUIRoots {
            guard let host = root.anchor.view else { continue }
            let views = views(of: host)
            guard !views.isEmpty else { continue }
            var components: [String: [InspectorNode]] = [:]
            root.forEach { if $0.kind == .component { components[$0.typeName, default: []].append($0) } }
            for (type, nodes) in components {
                guard let instances = views[type], !instances.isEmpty else { continue }
                if nodes.count == instances.count {
                    let placed = nodes.map { ($0, $0.anchor.resolve(in: host) ?? $0.frame) }.sorted { before($0.1.origin, $1.1.origin) }
                    let views = instances.allSatisfy { $0.origin != nil }
                        ? instances.sorted { before($0.origin!, $1.origin!) }
                        : instances.sorted { $0.valueNode < $1.valueNode }
                    for ((node, _), view) in zip(placed, views) { result[node.id] = Match(views: [view]) }
                } else {
                    for node in nodes { result[node.id] = Match(views: instances) }
                }
            }
        }
        return result
    }

    private static func before(_ a: CGPoint, _ b: CGPoint) -> Bool {
        abs(a.y - b.y) > 0.5 ? a.y < b.y : a.x < b.x
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
                    if n > 0 {
                        result[name, default: []].append(GraphView(nodes: Array(nodes[0..<n]), valueNode: LIAGTreeElementGetValue(element),
                                                                   type: type, origin: origin(below: element)))
                    }
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

    /// The recorded position of the first element at or below `element` that has one, depth first.
    private static func origin(below element: LIAGTreeElement) -> CGPoint? {
        var children = [LIAGTreeElement?](repeating: nil, count: 64)
        func find(_ element: LIAGTreeElement, depth: Int) -> CGPoint? {
            var type: UnsafeRawPointer?
            let attribute = LIAGTreeElementGetValueNamed(element, "position", &type)
            if attribute != 0, let type, let value = LIAGGraphGetValue(attribute, type) {
                func size<T>(_: T.Type) -> Int { MemoryLayout<T>.size }
                // `ViewOrigin` and `CGPoint` both start with the point.
                if _openExistential(unsafeBitCast(type, to: Any.Type.self), do: size) >= MemoryLayout<CGPoint>.size {
                    return value.loadUnaligned(as: CGPoint.self)
                }
            }
            guard depth < 12 else { return nil }
            let n = Int(children.withUnsafeMutableBufferPointer { LIAGTreeElementGetChildren(element, $0.baseAddress!, Int32($0.count)) })
            for child in children[0..<n].compactMap({ $0 }).reversed() {
                if let point = find(child, depth: depth + 1) { return point }
            }
            return nil
        }
        return find(element, depth: 0)
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
