import SwiftUI
import XCTest
@testable import LayoutInspector

/// The menu's mode toggles, the components list's row width, the heatmap's fills.
@MainActor
final class InspectorUXTests: XCTestCase {
    func test_pickingTheCheckedModeAgain_turnsHighlightingOff() {
        XCTAssertNil(InspectorToolbar.mode(afterPicking: .rerenders, isOn: false, current: .rerenders))
        XCTAssertEqual(InspectorToolbar.mode(afterPicking: .spacing, isOn: true, current: .rerenders), .spacing)
        XCTAssertNil(InspectorToolbar.mode(afterPicking: nil, isOn: true, current: .rerenders))
        XCTAssertNil(InspectorToolbar.mode(afterPicking: nil, isOn: false, current: nil))
        // Unchecking a mode that isn't the highlighted one leaves the highlighted one alone.
        XCTAssertEqual(InspectorToolbar.mode(afterPicking: .spacing, isOn: false, current: .rerenders), .rerenders)
    }

    /// 0.2.15: a row with many re-rendered modifiers grew wider than the sheet and pushed its name off screen.
    func test_modifierCapsules_neverWiderThanTheRow() {
        let renders = (1...6).map { ("NetworkReachabilityBannerModifier\($0)", RenderCounts.Entry(count: 12 * $0, instances: 1)) }
        for width in [375.0, 402.0, 200.0] {
            let host = UIHostingController(rootView: ModifierCapsules(renders: renders))
            let size = host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
            XCTAssertLessThanOrEqual(size.width, width, "capsules at \(width) pt")
            XCTAssertGreaterThan(size.width, 60, "capsules show text at \(width) pt")
            XCTAssertLessThan(size.height, 40, "capsules stay on one line at \(width) pt")
        }
    }

    /// Nested fills stacked up into an opaque layer on a deep screen: views holding a marked view are outlined only.
    func test_heatmap_fillsOnlyTheInnermostMarkedViews() {
        func node(_ id: Int, _ kind: NodeKind, in parent: InspectorNode? = nil) -> InspectorNode {
            let node = InspectorNode(id: id, kind: kind, title: "N\(id)", typeName: "N\(id)", anchor: NodeAnchor(view: nil, rect: .zero))
            parent?.add(node)
            return node
        }
        let screen = node(1, .component)
        let stack = node(2, .stack, in: screen)
        let card = node(3, .component, in: stack)
        let label = node(4, .component, in: card)
        let shared = node(5, .component, in: screen)
        let quiet = node(6, .component, in: shared)
        var counts = RenderCounts()
        counts.byNode = [1: .init(count: 3, instances: 1), 3: .init(count: 9, instances: 1), 4: .init(count: 9, instances: 1),
                         5: .init(count: 4, instances: 2), 6: .init(count: 0, instances: 1)]
        let components = [screen, card, label, shared, quiet]

        XCTAssertEqual(InspectorRenderer.markedContainers(components, counts: counts, showsZeros: false), [1, 2, 3])
        // A view whose count is shared isn't filled, so it doesn't make its parent a container; a zero is, with zeros shown.
        XCTAssertEqual(InspectorRenderer.markedContainers(components, counts: counts, showsZeros: true), [1, 2, 3, 5])
    }

    func test_heatmap_fillsStayFaint() {
        XCTAssertLessThanOrEqual(InspectorRenderer.fillAlpha(heat: 1, rendered: true), 0.12)
        XCTAssertLessThanOrEqual(InspectorRenderer.fillAlpha(heat: 5, rendered: true), 0.12)
        XCTAssertLessThan(InspectorRenderer.fillAlpha(heat: 0, rendered: false), InspectorRenderer.fillAlpha(heat: 0.1, rendered: true))
    }
}
