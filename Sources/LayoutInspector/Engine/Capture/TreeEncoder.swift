#if LayoutInspectorEngine && !LAYOUT_INSPECTOR_DISABLED && os(iOS)
import SwiftUI

/// `Encoder` that produces Foundation collections directly (`NSMutableDictionary` / `NSMutableArray` / `NSNumber` /
/// `String`): the same values `JSONSerialization` would return for SwiftUI's own JSON of `_ViewDebug.Data`, without
/// the JSON. It has no nesting limit (SwiftUI's `JSONEncoder` gives up on a `Form`: "Too many nested arrays") and
/// writes NaN/∞ as SwiftUI does: "nan", "inf", "-inf".
final class TreeEncoder {
    func encode<T: Encodable>(_ value: T) throws -> Any {
        try TreeEncoding.box(value, codingPath: [])
    }

    /// The `properties` of one `_ViewDebug.Data` node, without encoding its children: SwiftUI reflects a node's
    /// values when the node is encoded, so this costs only the node itself.
    func encodeProperties(of node: _ViewDebug.Data) throws -> [[String: Any]] {
        let encoder = TreeEncoding.Impl(codingPath: [], skipsChildren: true)
        try node.encode(to: encoder)
        return ((encoder.storage as? NSDictionary)?["properties"] as? [[String: Any]]) ?? []
    }
}

private enum TreeEncoding {
    static func box<T: Encodable>(_ value: T, codingPath: [CodingKey]) throws -> Any {
        switch value {
        case let v as Double: return number(v)
        case let v as Float: return number(v)
        case let v as CGFloat: return number(Double(v))
        // `JSONEncoder` writes these as plain values instead of using their own `Encodable` conformances.
        case let v as Decimal:
            // JSON has its digits; read them back the way `JSONSerialization` does (an integer stays exact).
            return (try? JSONSerialization.jsonObject(with: Data(v.description.utf8), options: .fragmentsAllowed))
                ?? NSDecimalNumber(decimal: v)
        case let v as URL: return v.absoluteString
        case let v as Data: return v.base64EncodedString()
        case let v as String: return v
        case let v as Bool: return NSNumber(value: v)
        case let v as Int: return NSNumber(value: v)
        case let v as UInt: return NSNumber(value: v)
        case let v as Int64: return NSNumber(value: v)
        case let v as UInt64: return NSNumber(value: v)
        case let v as Int32: return NSNumber(value: v)
        case let v as UInt32: return NSNumber(value: v)
        default:
            let encoder = Impl(codingPath: codingPath)
            try value.encode(to: encoder)
            return encoder.storage ?? NSDictionary()
        }
    }

    static func number(_ v: Double) -> Any {
        if v.isNaN { return "nan" }
        if v.isInfinite { return v > 0 ? "inf" : "-inf" }
        return NSNumber(value: v)
    }

    /// JSON has the shortest decimal form of a `Float` ("0.06"), which reads back as the `Double` nearest to it.
    static func number(_ v: Float) -> Any {
        if v.isNaN || v.isInfinite { return number(Double(v)) }
        return NSNumber(value: Double(v.description) ?? Double(v))
    }

    final class Impl: Encoder {
        var codingPath: [CodingKey]
        var userInfo: [CodingUserInfoKey: Any] = [:]
        var storage: Any?
        /// Top level only: leave out the `children` key of a `_ViewDebug.Data`.
        let skipsChildren: Bool

        init(codingPath: [CodingKey], skipsChildren: Bool = false) {
            self.codingPath = codingPath
            self.skipsChildren = skipsChildren
        }

        func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
            let dict = (storage as? NSMutableDictionary) ?? NSMutableDictionary()
            storage = dict
            return KeyedEncodingContainer(Keyed<Key>(dict: dict, codingPath: codingPath, skipsChildren: skipsChildren))
        }

        func unkeyedContainer() -> UnkeyedEncodingContainer {
            let array = (storage as? NSMutableArray) ?? NSMutableArray()
            storage = array
            return Unkeyed(array: array, codingPath: codingPath)
        }

        func singleValueContainer() -> SingleValueEncodingContainer { Single(encoder: self) }
    }

    struct Keyed<Key: CodingKey>: KeyedEncodingContainerProtocol {
        let dict: NSMutableDictionary
        var codingPath: [CodingKey]
        var skipsChildren = false

        private func set(_ value: Any, _ key: Key) { dict[key.stringValue] = value }

        mutating func encodeNil(forKey key: Key) throws { set(NSNull(), key) }
        mutating func encode(_ value: Bool, forKey key: Key) throws { set(NSNumber(value: value), key) }
        mutating func encode(_ value: String, forKey key: Key) throws { set(value, key) }
        mutating func encode(_ value: Double, forKey key: Key) throws { set(number(value), key) }
        mutating func encode(_ value: Float, forKey key: Key) throws { set(number(value), key) }
        mutating func encode(_ value: Int, forKey key: Key) throws { set(NSNumber(value: value), key) }
        mutating func encode(_ value: Int8, forKey key: Key) throws { set(NSNumber(value: value), key) }
        mutating func encode(_ value: Int16, forKey key: Key) throws { set(NSNumber(value: value), key) }
        mutating func encode(_ value: Int32, forKey key: Key) throws { set(NSNumber(value: value), key) }
        mutating func encode(_ value: Int64, forKey key: Key) throws { set(NSNumber(value: value), key) }
        mutating func encode(_ value: UInt, forKey key: Key) throws { set(NSNumber(value: value), key) }
        mutating func encode(_ value: UInt8, forKey key: Key) throws { set(NSNumber(value: value), key) }
        mutating func encode(_ value: UInt16, forKey key: Key) throws { set(NSNumber(value: value), key) }
        mutating func encode(_ value: UInt32, forKey key: Key) throws { set(NSNumber(value: value), key) }
        mutating func encode(_ value: UInt64, forKey key: Key) throws { set(NSNumber(value: value), key) }
        mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
            if skipsChildren, key.stringValue == "children" { return }
            set(try box(value, codingPath: codingPath + [key]), key)
        }

        mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> {
            let nested = NSMutableDictionary()
            set(nested, key)
            return KeyedEncodingContainer(Keyed<NestedKey>(dict: nested, codingPath: codingPath + [key]))
        }

        mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
            let nested = NSMutableArray()
            set(nested, key)
            return Unkeyed(array: nested, codingPath: codingPath + [key])
        }

        mutating func superEncoder() -> Encoder {
            let dict = self.dict
            return Deferred(codingPath: codingPath) { dict["super"] = $0 }
        }

        mutating func superEncoder(forKey key: Key) -> Encoder {
            let dict = self.dict
            return Deferred(codingPath: codingPath + [key]) { dict[key.stringValue] = $0 }
        }
    }

    struct Unkeyed: UnkeyedEncodingContainer {
        let array: NSMutableArray
        var codingPath: [CodingKey]
        var count: Int { array.count }

        private func add(_ value: Any) { array.add(value) }

        mutating func encodeNil() throws { add(NSNull()) }
        mutating func encode(_ value: Bool) throws { add(NSNumber(value: value)) }
        mutating func encode(_ value: String) throws { add(value) }
        mutating func encode(_ value: Double) throws { add(number(value)) }
        mutating func encode(_ value: Float) throws { add(number(value)) }
        mutating func encode(_ value: Int) throws { add(NSNumber(value: value)) }
        mutating func encode(_ value: Int8) throws { add(NSNumber(value: value)) }
        mutating func encode(_ value: Int16) throws { add(NSNumber(value: value)) }
        mutating func encode(_ value: Int32) throws { add(NSNumber(value: value)) }
        mutating func encode(_ value: Int64) throws { add(NSNumber(value: value)) }
        mutating func encode(_ value: UInt) throws { add(NSNumber(value: value)) }
        mutating func encode(_ value: UInt8) throws { add(NSNumber(value: value)) }
        mutating func encode(_ value: UInt16) throws { add(NSNumber(value: value)) }
        mutating func encode(_ value: UInt32) throws { add(NSNumber(value: value)) }
        mutating func encode(_ value: UInt64) throws { add(NSNumber(value: value)) }
        mutating func encode<T: Encodable>(_ value: T) throws { add(try box(value, codingPath: codingPath)) }

        mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
            let nested = NSMutableDictionary()
            add(nested)
            return KeyedEncodingContainer(Keyed<NestedKey>(dict: nested, codingPath: codingPath))
        }

        mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
            let nested = NSMutableArray()
            add(nested)
            return Unkeyed(array: nested, codingPath: codingPath)
        }

        mutating func superEncoder() -> Encoder {
            let array = self.array
            return Deferred(codingPath: codingPath) { array.add($0) }
        }
    }

    struct Single: SingleValueEncodingContainer {
        let encoder: Impl
        var codingPath: [CodingKey] { encoder.codingPath }

        mutating func encodeNil() throws { encoder.storage = NSNull() }
        mutating func encode(_ value: Bool) throws { encoder.storage = NSNumber(value: value) }
        mutating func encode(_ value: String) throws { encoder.storage = value }
        mutating func encode(_ value: Double) throws { encoder.storage = number(value) }
        mutating func encode(_ value: Float) throws { encoder.storage = number(value) }
        mutating func encode(_ value: Int) throws { encoder.storage = NSNumber(value: value) }
        mutating func encode(_ value: Int8) throws { encoder.storage = NSNumber(value: value) }
        mutating func encode(_ value: Int16) throws { encoder.storage = NSNumber(value: value) }
        mutating func encode(_ value: Int32) throws { encoder.storage = NSNumber(value: value) }
        mutating func encode(_ value: Int64) throws { encoder.storage = NSNumber(value: value) }
        mutating func encode(_ value: UInt) throws { encoder.storage = NSNumber(value: value) }
        mutating func encode(_ value: UInt8) throws { encoder.storage = NSNumber(value: value) }
        mutating func encode(_ value: UInt16) throws { encoder.storage = NSNumber(value: value) }
        mutating func encode(_ value: UInt32) throws { encoder.storage = NSNumber(value: value) }
        mutating func encode(_ value: UInt64) throws { encoder.storage = NSNumber(value: value) }
        mutating func encode<T: Encodable>(_ value: T) throws { encoder.storage = try box(value, codingPath: codingPath) }
    }

    /// Encoder whose result is written back when it is released (used for `superEncoder`).
    final class Deferred: Encoder {
        let inner: Impl
        let commit: (Any) -> Void
        var codingPath: [CodingKey] { inner.codingPath }
        var userInfo: [CodingUserInfoKey: Any] { [:] }

        init(codingPath: [CodingKey], commit: @escaping (Any) -> Void) {
            inner = Impl(codingPath: codingPath)
            self.commit = commit
        }

        deinit { commit(inner.storage ?? NSDictionary()) }

        func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> { inner.container(keyedBy: type) }
        func unkeyedContainer() -> UnkeyedEncodingContainer { inner.unkeyedContainer() }
        func singleValueContainer() -> SingleValueEncodingContainer { inner.singleValueContainer() }
    }
}

#endif
