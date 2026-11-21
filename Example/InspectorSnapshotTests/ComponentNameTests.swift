import SwiftUI
import XCTest
@testable import LayoutInspector
@testable import InspectorDemo

/// Component names land on the component's own nodes only.
@MainActor
final class ComponentNameTests: XCTestCase {
    /// A banking app's tab bar icon modifier: its body resolves to types that live in the tab button's own hosting view,
    /// and in the screen's host only SwiftUI's opacity-transition wrapper matches its chain. That wrapper is in every
    /// view with an opacity transition, and the name must not land on them.
    func test_genericWrapper_doesNotCarryAComponentName() {
        let wrapper = "SwiftUI.ModifiedContent<SwiftUI.PlaceholderContentView<SwiftUI.OpacityTransition>, SwiftUI.OpacityRendererEffect>"
        let tree = AttributeGraphTree.Element(typeName: "Demo.IconScale", flags: 1, children: [
            .init(typeName: wrapper, flags: 0, children: [
                .init(typeName: "SwiftUI.ZStack<Demo.TabIconContent>", flags: 0, children: []),
            ]),
        ])
        let screen = Self.node("SwiftUI.VStack<SwiftUI.ForEach<Swift.Range<Swift.Int>, Swift.Int, SwiftUI.Text>>",
                               children: (0..<8).map { _ in Self.node(wrapper, children: [Self.node("SwiftUI.Text")]) })
        ComponentReconstruction(trees: [tree]).apply(to: [screen])

        var names: [String] = []
        screen.forEach { if $0.isSynthetic { names.append($0.readable) } }
        XCTAssertEqual(names, [], ComponentReconstruction.log.joined(separator: "\n"))
    }

    /// A component whose only anchor is found many more times than the view exists is left unnamed.
    func test_ambiguousAnchor_isSkipped() {
        let specific = "SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.Image, SwiftUI.Text)>>"
        let tree = AttributeGraphTree.Element(typeName: "Demo.Badge", flags: 1, children: [
            .init(typeName: specific, flags: 0, children: []),
        ])
        let screen = Self.node("SwiftUI.VStack<Demo.Rows>",
                               children: (0..<9).map { _ in Self.node(specific, children: [Self.node("SwiftUI.Text")]) })
        ComponentReconstruction(trees: [tree]).apply(to: [screen])

        var names: [String] = []
        screen.forEach { if $0.isSynthetic { names.append($0.readable) } }
        XCTAssertEqual(names, [])
    }

    /// A banking app's tab items: `MainTabItem`, `ChatTabItem`… all have the body `HolaTabItem(…)`, and every tab button
    /// hosts one of them. In a host, only `HolaTabItem` can be named.
    func test_siblingViewsBuiltAlike_leaveTheNodeUnnamed() {
        let item = "SwiftUI.VStack<SwiftUI.TupleView<(SwiftUI.Image, SwiftUI.Text)>>"
        func tabItem(_ name: String) -> AttributeGraphTree.Element {
            .init(typeName: "Demo.\(name)", flags: 1, children: [
                .init(typeName: "Demo.HolaTabItem", flags: 1, children: [.init(typeName: item, flags: 0, children: [])]),
            ])
        }
        let tabs = AttributeGraphTree.Element(typeName: "SwiftUI.TabView<Demo.Tabs>", flags: 0,
                                              children: [tabItem("MainTabItem"), tabItem("ChatTabItem"), tabItem("PayTabItem")])
        let button = Self.node("SwiftUI.ModifiedContent<SwiftUI.AnyView, SwiftUI._PaddingLayout>",
                               children: [Self.node(item, children: [Self.node("SwiftUI.Text")])])
        ComponentReconstruction(trees: [tabs]).apply(to: [button])

        var names: [String] = []
        button.forEach { if $0.isSynthetic { names.append($0.readable) } }
        XCTAssertEqual(names, ["HolaTabItem"], ComponentReconstruction.log.joined(separator: "\n"))
    }

    private static func node(_ type: String, children: [RawDebugNode] = []) -> RawDebugNode {
        let attribute: [String: Any] = ["type": type, "readableType": AttributeGraphTree.readable(type)]
        let node = RawDebugNode(encoded: ["properties": [["id": 0, "attribute": attribute]], "children": []])
        node.children = children
        children.forEach { $0.parent = node }
        return node
    }

    /// An app's own `GeometryEffect` is a node in `_ViewDebug` already: no second node for it.
    func test_geometryEffect_isOneNode() async throws {
        let harness = ScreenHarness(DemoScreen.spaces.view)
        defer { harness.tearDown() }
        let layout = try await harness.waitUntilLoaded()
        XCTAssertEqual(layout.swiftUINodes.filter { $0.title == "Nudge" }.count, 1)
    }
}
