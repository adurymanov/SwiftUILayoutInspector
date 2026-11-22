#if LayoutInspectorEngine && !LAYOUT_INSPECTOR_DISABLED && os(iOS)
import Foundation
import SwiftUI

/// Which app types are `ViewModifier`s, by full type name. The runtime answers the first question about a type by
/// scanning every conformance record of every loaded image: about a millisecond a type in a big app, 185 ms on its
/// first screen. So captures ask off the main thread (``ask(_:)``) while their other steps run, and read the answers
/// at their last step (``wait(upTo:)``, ``modifiers(among:)``).
nonisolated enum ModifierTypes {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var answers: [String: Bool] = [:]
    nonisolated(unsafe) private static var asked = Set<String>()
    private static let queue = DispatchQueue(label: "LayoutInspector.ModifierTypes", qos: .userInitiated)
    private static let pending = DispatchGroup()

    /// Answers the types not asked about yet, in the background.
    static func ask(_ types: [(name: String, type: Any.Type)]) {
        let new = lock.withLock { types.filter { asked.insert($0.name).inserted } }
        guard !new.isEmpty else { return }
        queue.async(group: pending) {
            for entry in new {
                let isModifier = entry.type is any ViewModifier.Type
                lock.withLock { answers[entry.name] = isModifier }
            }
        }
    }

    /// Waits for the questions asked so far, at most `timeout` seconds; `true` when all are answered.
    @discardableResult
    static func wait(upTo timeout: TimeInterval) -> Bool {
        pending.wait(timeout: .now() + timeout) == .success
    }

    /// The modifiers among `names`, as far as they are answered.
    static func modifiers(among names: some Sequence<String>) -> Set<String> {
        lock.withLock { Set(names.filter { answers[$0] == true }) }
    }

    /// The modifiers among `types`, answering on this thread what isn't answered yet.
    static func modifiersNow(among types: [(name: String, type: Any.Type)]) -> Set<String> {
        var result = Set<String>()
        for entry in types {
            if let known = lock.withLock({ answers[entry.name] }) {
                if known { result.insert(entry.name) }
                continue
            }
            let isModifier = entry.type is any ViewModifier.Type
            lock.withLock { answers[entry.name] = isModifier; asked.insert(entry.name) }
            if isModifier { result.insert(entry.name) }
        }
        return result
    }
}

#endif
