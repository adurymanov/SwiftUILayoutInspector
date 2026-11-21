import SwiftUI
import XCTest
@testable import LayoutInspector

/// Subtrees `_ViewDebug` reports that are not on screen are left out of the capture.
@MainActor
final class HiddenContentTests: XCTestCase {
    /// A banking app's instrument cards (a button around the content with `.accessibilityRepresentation { content }`):
    /// `_ViewDebug` held a second copy of each card under `HiddenModifierAllowingAccessibility`, laid out from its own
    /// corner, and the inspector drew all the copies on top of each other at the top of the grid.
    func test_accessibilityCopy_isPruned() {
        let shown = node("SwiftUI.Text")
        let copy = node("SwiftUI.HiddenModifierAllowingAccessibility", children: [node("SwiftUI.Text")])
        let root = node("SwiftUI.VStack<Demo.Card>", children: [shown, copy])
        SwiftUIGraphReader.pruneHidden(root)
        XCTAssertEqual(root.children.map(\.readable), ["Text"])
    }

    private func node(_ type: String, children: [RawDebugNode] = []) -> RawDebugNode {
        let attribute: [String: Any] = ["type": type, "readableType": AttributeGraphTree.readable(type)]
        let node = RawDebugNode(encoded: ["properties": [["id": 0, "attribute": attribute]], "children": []])
        node.children = children
        children.forEach { $0.parent = node }
        return node
    }
}
