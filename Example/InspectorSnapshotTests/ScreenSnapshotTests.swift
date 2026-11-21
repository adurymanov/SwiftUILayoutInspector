import SnapshotTesting
import SwiftUI
import XCTest
import LayoutInspector
@testable import InspectorDemo

/// Every demo screen × every inspector mode. Screens load data asynchronously (DemoAPI),
/// the harness waits for the data before capturing.
@MainActor
final class ScreenSnapshotTests: XCTestCase {
    static let modes: [LayoutInspector.Mode?] = [nil, .components, .spacing, .typography, .constraints, .uikit, .lint]

    func test_profile() async throws {
        try await verify(.profile) { capture in
            (capture.find("Anna Petrova", kind: .text), capture.find("AvatarView", kind: .component))
        }
    }

    func test_feed() async throws {
        try await verify(.feed) { capture in
            let card = capture.find("ProductCard", kind: .component)
            let price = card?.first { $0.title == "PriceTag" }
            let thumb = card?.first { $0.title == "ProductThumbnail" }
            return (price, thumb)
        }
    }

    func test_checkout() async throws {
        try await verify(.checkout) { capture in
            (capture.find("PayButton", kind: .component), capture.find("OrderTotalRow", kind: .component))
        }
    }

    func test_dashboard() async throws {
        try await verify(.dashboard) { capture in
            let tile = capture.find("MetricTile", kind: .component)
            return (tile?.first { $0.kind == .text && $0.info.text?.string.hasPrefix("€") == true }, nil)
        }
    }

    func test_promo() async throws {
        try await verify(.promo) { capture in
            (capture.find("Offers", kind: .text), capture.find("PromoBanner", kind: .component))
        }
    }

    /// On iOS 26+ `_ViewDebug` measures what sits under `.glassEffect` from the glass. Each card's texts must
    /// land inside its padding. The image snapshots are left out: the glass renders slightly differently
    /// from run to run.
    func test_glass() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Liquid Glass needs iOS 26") }
        let harness = ScreenHarness(DemoScreen.glass.view)
        defer { harness.tearDown() }
        let capture = try await harness.waitUntilLoaded()
        XCTAssertTrue(capture.isSwiftUIGraphAvailable, "SWIFTUI_VIEW_DEBUG is not enabled")

        let cards: [(title: String, count: Int, padding: CGSize, texts: Int)] = [
            ("BalanceCard", 1, CGSize(width: 20, height: 20), 3),
            ("QuickAction", 2, CGSize(width: 20, height: 14), 1),
            ("PlainCard", 1, CGSize(width: 20, height: 20), 2),
            ("TransactionsCard", 1, CGSize(width: 20, height: 20), 8),
        ]
        for card in cards {
            let nodes = capture.nodes(.component).filter { $0.title == card.title }
            XCTAssertEqual(nodes.count, card.count, card.title)
            for node in nodes {
                let content = node.frame.insetBy(dx: card.padding.width - 0.5, dy: card.padding.height - 0.5)
                var texts: [InspectorNode] = []
                node.forEach { if $0.kind == .text { texts.append($0) } }
                XCTAssertEqual(texts.count, card.texts, card.title)
                for text in texts {
                    XCTAssertTrue(content.contains(text.frame),
                                  "\(text.info.text?.string ?? "") \(text.frame) is outside the padding of \(card.title) \(node.frame)")
                }
            }
        }
        assertSnapshot(of: LayoutReport.text(for: capture), as: .lines, named: "report")

        let sheet = Self.modes.map { mode in (mode?.title ?? "Screen", harness.image(capture, mode: mode)) }
        ArtifactWriter.write(ContactSheet.make(title: DemoScreen.glass.title, items: sheet, columns: 4), name: DemoScreen.glass.rawValue)
    }

    /// Under `.geometryGroup()`, `.drawingGroup()`, the transform effects, `.visualEffect` and a custom
    /// `GeometryEffect` SwiftUI may measure positions from the modifier, and below `.offset` they already include
    /// it. Every card's title still starts inside its padding, one card below the other; `.compositingGroup()`, which
    /// keeps the outer space, is not shifted either.
    func test_spaces() async throws {
        let harness = ScreenHarness(DemoScreen.spaces.view)
        defer { harness.tearDown() }
        let capture = try await harness.waitUntilLoaded()
        XCTAssertTrue(capture.isSwiftUIGraphAvailable, "SWIFTUI_VIEW_DEBUG is not enabled")

        // ScrollView padding 16 + card padding 20, and `.offset(x: 8)` on the last two. A card scaled by 0.95 around
        // its center is 18.5 pt narrower and its padding 19: its title starts at 16 + 9.25 + 19.
        let titles: [(String, CGFloat)] = [
            ("$0.00", 36), ("Drawing group", 36), ("Scaled", 44.25), ("Rotated", 36), ("Visual effect", 36),
            ("Custom effect", 36), ("Compositing group", 36), ("Moved", 44), ("Scaled and moved", 52.25),
        ]
        var previous: CGRect?
        for (title, x) in titles {
            guard let text = capture.find(title, kind: .text) else { XCTFail("no \(title)"); continue }
            XCTAssertEqual(text.frame.minX, x, accuracy: 0.5, title)
            if let previous { XCTAssertGreaterThan(text.frame.minY, previous.maxY + 20, title) }
            previous = text.frame
        }
        assertSnapshot(of: LayoutReport.text(for: capture), as: .lines, named: "report")
    }

    /// Same screen with the SwiftUI graph unavailable would only show the render tree; here we check the
    /// text report ("layout snapshot") – stable and diff-able, no pixels involved.
    func test_profile_textReport() async throws {
        let harness = ScreenHarness(DemoScreen.profile.view)
        defer { harness.tearDown() }
        let capture = try await harness.waitUntilLoaded()
        assertSnapshot(of: LayoutReport.text(for: capture), as: .lines, named: "report")
    }

    func test_promo_textReport_withUIKit() async throws {
        let harness = ScreenHarness(DemoScreen.promo.view)
        defer { harness.tearDown() }
        _ = try await harness.waitUntilLoaded()
        var options = LayoutReport.Options()
        options.includeRenderTree = true
        let report = LayoutReport.text(for: harness.capture(), options: options)
        let uikitPart = report.components(separatedBy: "## UIKit").last ?? ""
        let promo = uikitPart.components(separatedBy: "\n").drop { !$0.contains("PromoBannerView") }.prefix(24).joined(separator: "\n")
        assertSnapshot(of: promo, as: .lines, named: "uikit-constraints")
    }

    // MARK: -

    private func verify(_ screen: DemoScreen, file: StaticString = #filePath, testName: String = #function, line: UInt = #line,
                        pick: (InspectorCapture) -> (InspectorNode?, InspectorNode?)) async throws {
        let harness = ScreenHarness(screen.view)
        defer { harness.tearDown() }
        let capture = try await harness.waitUntilLoaded()
        XCTAssertTrue(capture.isSwiftUIGraphAvailable, "SWIFTUI_VIEW_DEBUG is not enabled", file: file, line: line)

        var sheet: [(String, UIImage)] = []
        for mode in Self.modes {
            let image = harness.image(capture, mode: mode)
            let name = mode?.rawValue ?? "plain"
            assertSnapshot(of: image, as: .image(precision: 0.98, perceptualPrecision: 0.97), named: name,
                           file: file, testName: testName, line: line)
            sheet.append((mode?.title ?? "Screen", image))
        }

        // Measure mode with a programmatic selection.
        let (selected, target) = pick(capture)
        XCTAssertNotNil(selected, "nothing to select on \(screen)", file: file, line: line)
        let measure = harness.image(capture, mode: .measure) {
            $0.selectedID = selected?.id
            $0.measureTargetID = target?.id
        }
        assertSnapshot(of: measure, as: .image(precision: 0.98, perceptualPrecision: 0.97), named: "measure",
                       file: file, testName: testName, line: line)
        sheet.append(("Measure", measure))

        ArtifactWriter.write(ContactSheet.make(title: screen.title, items: sheet, columns: 5), name: screen.rawValue)
    }
}

enum ArtifactWriter {
    static func write(_ image: UIImage, name: String, file: StaticString = #filePath) {
        let dir = URL(fileURLWithPath: "\(file)").deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Artifacts")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? image.pngData()?.write(to: dir.appendingPathComponent("\(name).png"))
    }
}
