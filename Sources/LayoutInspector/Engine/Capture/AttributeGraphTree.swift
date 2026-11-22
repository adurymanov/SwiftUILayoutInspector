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
        let reader = ChildReader(subgraph: subgraph)
        return element(root, depth: 0, reader: reader)
    }

    private static var buffer = [LIAGTreeElement?](repeating: nil, count: 1024)

    private static func element(_ e: LIAGTreeElement, depth: Int, reader: ChildReader) -> Element {
        var name = "?"
        let meta = LIAGTreeElementGetType(e)
        if let meta {
            name = TypeNames.qualifiedName(of: unsafeBitCast(meta, to: Any.Type.self))
        }
        var children: [Element] = []
        if depth < 400 {
            let n = Int(buffer.withUnsafeMutableBufferPointer { reader.children(of: e, into: $0) })
            let elements = buffer[0..<n].compactMap { $0 }   // copy before recursing (the buffer is shared)
            children.reserveCapacity(elements.count)
            for c in elements { children.append(element(c, depth: depth + 1, reader: reader)) }
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


/// Reads the children of the tree elements of one host's graph: with ``LIAGChildWalk`` where the code it was written
/// against is there (the iOS 26.5 and 27.0 simulators), which asks AttributeGraph about hung subgraphs only for the
/// elements that own a subgraph root's value, else every element the plain way. `LAYOUT_INSPECTOR_FULL_WALK` turns the walk off.
final class ChildReader {
    private let walk: OpaquePointer?

    init(subgraph: UnsafeRawPointer, plain: Bool = ChildReader.isOff) {
        walk = plain ? nil : LIAGChildWalkCreate(subgraph)
    }

    deinit { if let walk { LIAGChildWalkDestroy(walk) } }

    static let isOff = ProcessInfo.processInfo.environment["LAYOUT_INSPECTOR_FULL_WALK"] != nil

    /// The AttributeGraph in this process is one the walk knows.
    static var isAvailable: Bool { LIAGChildWalkIsAvailable() }

    var isWalking: Bool { walk != nil }

    func children(of element: LIAGTreeElement, into buffer: UnsafeMutableBufferPointer<LIAGTreeElement?>) -> Int32 {
        if let walk { return LIAGChildWalkGetChildren(walk, element, buffer.baseAddress!, Int32(buffer.count)) }
        return LIAGTreeElementGetChildren(element, buffer.baseAddress!, Int32(buffer.count))
    }

    /// Elements asked about hung subgraphs, and the subgraph roots known.
    var stats: (searched: Int, roots: Int) {
        guard let walk else { return (0, 0) }
        var searched: Int32 = 0, roots: Int32 = 0
        LIAGChildWalkGetStats(walk, &searched, &roots)
        return (Int(searched), Int(roots))
    }

    /// The code hashes of the functions the walk checks, for adding an iOS version.
    static var codeHashes: [UInt64] {
        var out = [UInt64](repeating: 0, count: 8)
        out.withUnsafeMutableBufferPointer { LIAGChildWalkCodeHashes($0.baseAddress!) }
        return out
    }

    /// Walks the whole tree of `host` both ways and compares the children of every element (tests and
    /// `LAYOUT_INSPECTOR_CHECK_WALK`): the elements seen, and the ones whose children differ. `nil` without a walk.
    static func check(_ host: UIView) -> (elements: Int, mismatches: Int, searched: Int, roots: Int)? {
        guard let subgraph = AttributeGraphTree.rootSubgraph(of: host), let root = LIAGSubgraphGetTreeRoot(subgraph) else { return nil }
        let fast = ChildReader(subgraph: subgraph, plain: false)
        guard fast.isWalking else { return nil }
        let full = ChildReader(subgraph: subgraph, plain: true)
        var a = [LIAGTreeElement?](repeating: nil, count: 4096), b = a
        var stack = [root], elements = 0, mismatches = 0
        while let element = stack.popLast(), elements < 2_000_000 {
            elements += 1
            let n = Int(a.withUnsafeMutableBufferPointer { full.children(of: element, into: $0) })
            let m = Int(b.withUnsafeMutableBufferPointer { fast.children(of: element, into: $0) })
            if n != m || !zip(a[0..<n], b[0..<m]).allSatisfy({ $0 == $1 }) { mismatches += 1 }
            stack += a[0..<n].compactMap { $0 }
        }
        let stats = fast.stats
        return (elements, mismatches, stats.searched, stats.roots)
    }
}

#endif

