import SwiftUI
import XCTest
@testable import LayoutInspector
@testable import InspectorDemo

/// Component names land on the component's own nodes only.
@MainActor
final class ComponentNameTests: XCTestCase {
    /// Whether one view is built from another is read from bytes for ASCII names: the answer must be the one the
    /// Character search gives, at word edges, across the lines of a chain and with repeated partial matches.
    func test_nameSearch_readsLikeCharacters() {
        let cases: [([String], String)] = [
            (["Demo.Row"], "Demo.Row"),
            (["SwiftUI.ModifiedContent<Demo.Row, Demo.CardStyle>"], "Demo.CardStyle"),
            (["Demo.RowStyle"], "Demo.Row"),
            (["XDemo.Row"], "Demo.Row"),
            (["Demo.Row.Inner"], "Demo.Row"),
            (["Demo.Row_x"], "Demo.Row"),
            (["A<Demo.Row_>, Demo.Row>"], "Demo.Row"),
            (["Demo.RowDemo.Row"], "Demo.Row"),
            (["Demo.Demo.Row"], "Demo.Row"),
            (["(Demo.Row)"], "Demo.Row"),
            (["Demo.Rowx", "Demo.Row"], "Demo.Row"),
            (["Demo.Ro", "w"], "Demo.Row"),
            (["Demo.Row", ""], "Demo.Row"),
            ([], "Demo.Row"),
            (["Demo.Generic<Demo.Row>"], "Demo.Generic<Demo.Row>"),
            (["Demo.Generic<Demo.Row>2"], "Demo.Generic<Demo.Row>"),
            // The search goes on after a match that is not a whole name, past its end: an overlapping one is not seen.
            (["BA<A<A"], "A<A"),
        ]
        for (lines, name) in cases {
            guard let text = ComponentReconstruction.ASCIIText(lines: lines).bytes,
                  let needle = ComponentReconstruction.ASCIIText(name: name).bytes else {
                XCTFail("not read as bytes: \(lines) / \(name)"); continue
            }
            XCTAssertEqual(ComponentReconstruction.mentions(in: text, needle),
                           lines.contains { ComponentReconstruction.mentions($0, name) }, "\(lines) / \(name)")
        }
        // Names that are not one byte per Character are left to the Character search.
        XCTAssertNil(ComponentReconstruction.ASCIIText(lines: ["Demo.Café"]).bytes)
        XCTAssertNil(ComponentReconstruction.ASCIIText(lines: ["Demo.A\r\nB"]).bytes)
        XCTAssertNil(ComponentReconstruction.ASCIIText(name: "").bytes)
        XCTAssertNil(ComponentReconstruction.ASCIIText(name: "Demo.A\nB").bytes)
    }

    /// Sampled dictionary keys find what whole-name keys find: names alike at the start, middle and end stay apart.
    func test_typeKeys_matchWholeNames() {
        let long = String(repeating: "SwiftUI.ModifiedContent<", count: 40)
        let names = [long + "Demo.A" + String(repeating: ">", count: 40), long + "Demo.B" + String(repeating: ">", count: 40),
                     "Demo.A", "Demo.B", long, long + "x"]
        var byKey: [ComponentReconstruction.TypeKey: Int] = [:]
        for (i, name) in names.enumerated() { byKey[ComponentReconstruction.TypeKey(name)] = i }
        XCTAssertEqual(byKey.count, names.count)
        for (i, name) in names.enumerated() {
            XCTAssertEqual(byKey[ComponentReconstruction.TypeKey(String(name))], i, name)
            XCTAssertEqual(byKey[ComponentReconstruction.TypeKey(NSString(string: name) as String)], i, "bridged \(name)")
        }
    }

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

    /// A banking app's tab items: `HomeTab`, `InboxTab`… all have the body `TabButton(…)`, and every tab button
    /// hosts one of them. In a host, only `TabButton` can be named.
    func test_siblingViewsBuiltAlike_leaveTheNodeUnnamed() {
        let item = "SwiftUI.VStack<SwiftUI.TupleView<(SwiftUI.Image, SwiftUI.Text)>>"
        func tabItem(_ name: String) -> AttributeGraphTree.Element {
            .init(typeName: "Demo.\(name)", flags: 1, children: [
                .init(typeName: "Demo.TabButton", flags: 1, children: [.init(typeName: item, flags: 0, children: [])]),
            ])
        }
        let tabs = AttributeGraphTree.Element(typeName: "SwiftUI.TabView<Demo.Tabs>", flags: 0,
                                              children: [tabItem("HomeTab"), tabItem("InboxTab"), tabItem("PayTab")])
        let button = Self.node("SwiftUI.ModifiedContent<SwiftUI.AnyView, SwiftUI._PaddingLayout>",
                               children: [Self.node(item, children: [Self.node("SwiftUI.Text")])])
        ComponentReconstruction(trees: [tabs]).apply(to: [button])

        var names: [String] = []
        button.forEach { if $0.isSynthetic { names.append($0.readable) } }
        XCTAssertEqual(names, ["TabButton"], ComponentReconstruction.log.joined(separator: "\n"))
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
