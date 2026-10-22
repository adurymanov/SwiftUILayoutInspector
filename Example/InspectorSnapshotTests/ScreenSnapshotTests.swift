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

        // Selection + details card (what you get after tapping an element in the app).
        if let selected {
            harness.showDetails(for: selected)
            let details = harness.image(capture, mode: .components) { $0.selectedID = selected.id; $0.showLabels = false }
            assertSnapshot(of: details, as: .image(precision: 0.98, perceptualPrecision: 0.97), named: "details",
                           file: file, testName: testName, line: line)
            sheet.append(("Tap → details", details))
        }

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
