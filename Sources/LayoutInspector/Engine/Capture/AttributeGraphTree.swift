#if LayoutInspectorEngine && !LAYOUT_INSPECTOR_DISABLED && os(iOS)
import UIKit
internal import LayoutInspectorAttributeGraph

/// Approach #1b – walk AttributeGraph's tree elements directly (private C API via dlsym, see LIAttributeGraph.c).
/// Unlike `_ViewDebug` JSON, this keeps *view list* elements – the place where app-defined views live
/// (`ProfileHeader` inside a `VStack` is built as a view list, so `_ViewDebug` hoists its children and drops it).
enum AttributeGraphTree {
    final class Element {
        let typeName: String
        let flags: UInt32
        let children: [Element]

        init(typeName: String, flags: UInt32, children: [Element]) {
            self.typeName = typeName
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
        return element(root, depth: 0)
    }

    /// `String(reflecting:)` of deeply generic SwiftUI types is expensive – cache per metadata pointer.
    private static var typeNames: [UnsafeRawPointer: String] = [:]
    private static var buffer = [LIAGTreeElement?](repeating: nil, count: 1024)

    private static func element(_ e: LIAGTreeElement, depth: Int) -> Element {
        var name = "?"
        if let meta = LIAGTreeElementGetType(e) {
            if let cached = typeNames[meta] {
                name = cached
            } else {
                name = String(reflecting: unsafeBitCast(meta, to: Any.Type.self))
                typeNames[meta] = name
            }
        }
        var children: [Element] = []
        if depth < 400 {
            let n = Int(buffer.withUnsafeMutableBufferPointer { LIAGTreeElementGetChildren(e, $0.baseAddress!, Int32($0.count)) })
            let elements = buffer[0..<n].compactMap { $0 }   // copy before recursing (the buffer is shared)
            children.reserveCapacity(elements.count)
            for c in elements { children.append(element(c, depth: depth + 1)) }
        }
        return Element(typeName: name, flags: LIAGTreeElementGetFlags(e), children: children)
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

    /// "SwiftUI.ModifiedContent<InspectorDemo.ProfileHeader, …>" -> "ModifiedContent<ProfileHeader, …>"
    static func readable(_ full: String) -> String {
        full.replacingOccurrences(of: #"\b[A-Za-z_][A-Za-z0-9_]*\.(?=[A-Za-z_(])"#, with: "", options: .regularExpression)
    }
}

#endif
