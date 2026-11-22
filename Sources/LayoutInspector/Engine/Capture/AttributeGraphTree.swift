#if LayoutInspectorEngine && !LAYOUT_INSPECTOR_DISABLED && os(iOS)
import UIKit
internal import LayoutInspectorAttributeGraph

/// Approach #1b – walk AttributeGraph's tree elements directly (private C API via dlsym, see LIAttributeGraph.c).
/// Unlike `_ViewDebug` JSON, this keeps *view list* elements – the place where app-defined views live
/// (`ProfileHeader` inside a `VStack` is built as a view list, so `_ViewDebug` hoists its children and drops it).
enum AttributeGraphTree {
    final class Element {
        let typeName: String
        /// The type's metadata, to count elements of a type without hashing its (long) name; `nil` with no type.
        let typeID: UnsafeRawPointer?
        let flags: UInt32
        let children: [Element]

        init(typeName: String, typeID: UnsafeRawPointer? = nil, flags: UInt32, children: [Element]) {
            self.typeName = typeName
            self.typeID = typeID
            self.flags = flags
            self.children = children
        }

        lazy var readable: String = AttributeGraphTree.readable(typeName)
    }

    static var isAvailable: Bool { LIAGIsAvailable() }

    /// `host._base.viewGraph.viewGraph` is a `ViewGraph` (SwiftUICore, no reflection metadata).
    /// Its `GraphHost.Data` starts with `graph, globalSubgraph, rootSubgraph` – three CF objects in a row.
    /// We find the two adjacent CF objects of the same CF type (the subgraphs) and take the last one.
    static func rootSubgraph(of host: UIView) -> UnsafeRawPointer? {
        guard let base = child(of: host, "_base"),
              let graphHost = child(of: base, "viewGraph"),
              let viewGraph = child(of: graphHost, "viewGraph") else { return nil }
        var copy = viewGraph
        guard let object = withUnsafeBytes(of: &copy, { UnsafeRawPointer(bitPattern: $0.load(as: UInt.self)) }),
              malloc_size(object) >= 64 else { return nil }
        // isa of a plain CF object (CFRunLoop is not toll-free bridged -> `__NSCFType`, same as AG objects).
        let isaMask: UInt = 0x0000_000F_FFFF_FFF8
        let cfIsa = Unmanaged.passUnretained(CFRunLoopGetMain()).toOpaque().load(as: UInt.self) & isaMask
        let limit = min(malloc_size(object), 160)

        var cfObjects: [(offset: Int, pointer: UnsafeRawPointer, typeID: CFTypeID)] = []
        for offset in stride(from: 16, to: limit, by: 8) {
            let word = object.load(fromByteOffset: offset, as: UInt.self)
            guard let p = UnsafeRawPointer(bitPattern: word), malloc_size(p) > 0 else { continue }
            let isa = p.load(as: UInt.self)
            guard isa & isaMask == cfIsa else { continue }
            let cf = Unmanaged<CFTypeRef>.fromOpaque(p).takeUnretainedValue()
            cfObjects.append((offset, p, CFGetTypeID(cf)))
        }
        for (a, b) in zip(cfObjects, cfObjects.dropFirst()) where b.offset == a.offset + 8 && a.typeID == b.typeID {
            if LIAGSubgraphGetTreeRoot(b.pointer) != nil { return b.pointer }
            if LIAGSubgraphGetTreeRoot(a.pointer) != nil { return a.pointer }
        }
        return nil
    }

    static func tree(of host: UIView) -> Element? {
        guard isAvailable, let subgraph = rootSubgraph(of: host), let root = LIAGSubgraphGetTreeRoot(subgraph) else { return nil }
        let attachments = subgraphAttachments(of: subgraph)
        let tree = element(root, depth: 0, attachments: attachments)
        if ComponentGraph.checksForest, attachments != nil {
            func names(_ e: Element) -> [String] { [e.typeName] + e.children.flatMap(names) }
            let same = names(tree) == names(element(root, depth: 0, attachments: nil))
            NSLog("%@", "LayoutInspector tree check: \(same ? "same" : "DIFFERENT")")
        }
        return tree
    }

    /// The elements the trees of descendant subgraphs hang from. Only these need the slow child lookup that finds those
    /// trees: it scans the subgraph's children for every element, and a big screen has thousands of both. `nil` when
    /// the functions are missing.
    static func subgraphAttachments(of subgraph: UnsafeRawPointer) -> Set<UnsafeRawPointer>? {
        guard LIAGSubgraphChildrenAreAvailable(), skipsSubgraphLookup != false else { return nil }
        var result = Set<UnsafeRawPointer>()
        var seen: Set<UnsafeRawPointer> = [subgraph]
        var stack = [subgraph]
        while let current = stack.popLast() {
            for index in 0..<LIAGSubgraphGetChildCount(current) {
                guard let child = LIAGSubgraphGetChild(current, index), seen.insert(child).inserted else { continue }
                if let root = LIAGSubgraphGetTreeRoot(child), let parent = LIAGTreeElementGetParent(root) { result.insert(parent) }
                stack.append(child)
            }
        }
        if skipsSubgraphLookup == nil, let root = LIAGSubgraphGetTreeRoot(subgraph) {
            switch childrenAgree(below: root, attachments: result) {
            case false?: skipsSubgraphLookup = false; return nil
            // Settled only on a tree with subgraphs hanging from it and enough elements to tell.
            case true? where !result.isEmpty: skipsSubgraphLookup = true
            default: break
            }
        }
        return result
    }

    /// Whether leaving out the subgraph lookup (a byte of AttributeGraph's private child iterator) changes nothing, checked
    /// on the first elements of the first tree big enough to tell: `nil` until then, while every tree is checked.
    private static var skipsSubgraphLookup: Bool?

    /// `nil`: too few elements to tell.
    private static func childrenAgree(below root: LIAGTreeElement, attachments: Set<UnsafeRawPointer>) -> Bool? {
        var queue = [root]
        var checked = 0
        var buffer = [LIAGTreeElement?](repeating: nil, count: 1024)
        while !queue.isEmpty, checked < 200 {
            let element = queue.removeFirst()
            let quick = Int(buffer.withUnsafeMutableBufferPointer {
                LIAGTreeElementGetChildrenIncludingSubgraphs(element, $0.baseAddress!, Int32($0.count), attachments.contains(element))
            })
            let quickChildren = Array(buffer[0..<quick])
            let full = Int(buffer.withUnsafeMutableBufferPointer { LIAGTreeElementGetChildren(element, $0.baseAddress!, Int32($0.count)) })
            guard full == quick else {
                NSLog("%@", "LayoutInspector: AttributeGraph's child iterator changed; trees are read the slow way")
                return false
            }
            checked += 1
            queue += quickChildren.compactMap { $0 }
        }
        return checked >= 50 ? true : nil
    }


    private static var buffer = [LIAGTreeElement?](repeating: nil, count: 1024)

    private static func element(_ e: LIAGTreeElement, depth: Int, attachments: Set<UnsafeRawPointer>?) -> Element {
        var name = "?"
        let meta = LIAGTreeElementGetType(e)
        if let meta {
            name = TypeNames.qualifiedName(of: unsafeBitCast(meta, to: Any.Type.self))
        }
        var children: [Element] = []
        if depth < 400 {
            let withSubgraphs = attachments.map { $0.contains(e) } ?? true
            let n = Int(buffer.withUnsafeMutableBufferPointer {
                LIAGTreeElementGetChildrenIncludingSubgraphs(e, $0.baseAddress!, Int32($0.count), withSubgraphs)
            })
            let elements = buffer[0..<n].compactMap { $0 }   // copy before recursing (the buffer is shared)
            children.reserveCapacity(elements.count)
            for c in elements { children.append(element(c, depth: depth + 1, attachments: attachments)) }
        }
        return Element(typeName: name, typeID: meta, flags: LIAGTreeElementGetFlags(e), children: children)
    }

    /// Mirror lookup through optionals and superclasses.
    static func child(of value: Any, _ label: String) -> Any? {
        var mirror: Mirror? = Mirror(reflecting: value)
        while let m = mirror {
            for c in m.children where c.label == label { return unwrap(c.value) }
            mirror = m.superclassMirror
        }
        return nil
    }

    private static func unwrap(_ value: Any) -> Any? {
        let m = Mirror(reflecting: value)
        guard m.displayStyle == .optional else { return value }
        return m.children.first.map { unwrap($0.value) } ?? nil
    }

    /// The first `length` characters of `readable(full)`, from the start of the name only: names of long modifier
    /// chains run to kilobytes, and the log needs their beginning.
    static func readablePrefix(_ full: String, _ length: Int) -> Substring {
        let head = full.utf8.count > 1024 ? String(full.prefix(1024)) : full
        let short = readable(head)
        // A module prefix cut at the end of `head` may read differently; far enough from the end it doesn't matter.
        if head.count == full.count || short.count >= length + 256 { return short.prefix(length) }
        return readable(full).prefix(length)
    }

    /// "SwiftUI.ModifiedContent<InspectorDemo.ProfileHeader, …>" -> "ModifiedContent<ProfileHeader, …>"
    static func readable(_ full: String) -> String {
        full.replacingOccurrences(of: #"\b[A-Za-z_][A-Za-z0-9_]*\.(?=[A-Za-z_(])"#, with: "", options: .regularExpression)
    }
}

#endif
