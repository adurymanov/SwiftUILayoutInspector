import SwiftUI
import XCTest
@_spi(Diagnostics) import LayoutInspector

/// Diagnostics, not a real test: writes SwiftUI's raw `_ViewDebug` tree (type, position, size) of small
/// screens to `$TEST_RUNNER_PLACEMENT_DIAG`, to see in which space each position is measured.
@MainActor
final class PlacementDiagnostics: XCTestCase {
    func test_dump() async throws {
        guard let out = ProcessInfo.processInfo.environment["PLACEMENT_DIAG"] else { throw XCTSkip("set PLACEMENT_DIAG") }
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        let cases: [(String, AnyView)] = [
            ("offset-container", AnyView(
                ScrollView {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: 0)
                        VStack(spacing: 8) {
                            PlacementProbe("Offset title").padding(.top, 40)
                            PlacementProbe("Offset subtitle")
                        }
                        Card { PlacementProbe("Offset card") }
                    }
                    .offset(y: -22)
                })),
            ("offset-text", AnyView(VStack { PlacementProbe("Moved text").offset(x: 12, y: -30) })),
            ("component-offset", AnyView(VStack(spacing: 20) {
                Shifted { PlacementProbe("Shifted A") }
                Shifted { Card { PlacementProbe("Shifted card") } }
            })),
            ("grid", AnyView(ScrollView {
                Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                    ForEach(0..<2) { row in
                        GridRow { ForEach(0..<2) { column in GridCard(label: "Cell \(row)-\(column)") } }
                    }
                }
                .padding(.horizontal, 20)
            })),
            ("a11y-representation", AnyView(VStack {
                VStack { probe("Represented") }.padding(20).modifier(PressableCard())
            })),
            ("dots", AnyView(HStack(spacing: 24) {
                ForEach(0..<3) { i in
                    ZStack { probe("Dot \(i)").compositingGroup().frame(width: 40, height: 20) }
                        .frame(width: 44, height: 24).scaleEffect(1).offset(x: 0).modifier(Wave(scale: 1)).modifier(Stoppable())
                }
            }.scaleEffect(1).modifier(Shake(amount: 0)))),
            ("blended-circle", AnyView(HStack(spacing: 20) {
                ForEach(0..<2) { _ in
                    ZStack { Circle().foregroundColor(.gray).blendMode(.multiply).compositingGroup().frame(width: 12, height: 12) }
                        .frame(width: 28, height: 28)
                }
            })),
            ("scaled", AnyView(VStack(spacing: 40) {
                Card { probe("Scaled card") }.scaleEffect(0.8)
                probe("Upside down").rotationEffect(.degrees(180))
            })),
            ("flipped-list", AnyView(ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(0..<2) { i in Card { probe("Message \(i)") }.rotationEffect(.degrees(180)) }
                }
            }.rotationEffect(.degrees(180)))),
        ]
        for (name, view) in cases {
            ProbeStore.frames = [:]
            let harness = ScreenHarness(view)
            defer { harness.tearDown() }
            let capture = try await harness.waitUntilLoaded()
            var lines: [String] = ["# probes"]
            for (k, v) in ProbeStore.frames.sorted(by: { $0.key < $1.key }) { lines.append("\(k) \(v)") }
            lines.append("# raw")
            for host in hosts(in: harness.window) {
                lines.append("## \(type(of: host)) \(host.convert(host.bounds, to: nil))")
                guard let data = host.perform(NSSelectorFromString("makeViewDebugData"))?.takeUnretainedValue() as? Data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { continue }
                json.forEach { walk($0, depth: 0, into: &lines) }
            }
            lines.append("# report")
            lines.append(capture.report())
            try lines.joined(separator: "\n").write(toFile: "\(out)/\(name).txt", atomically: true, encoding: .utf8)
        }
    }

    private func hosts(in view: UIView) -> [UIView] {
        var result: [UIView] = []
        if view.responds(to: NSSelectorFromString("makeViewDebugData")) { result.append(view) }
        view.subviews.forEach { result += hosts(in: $0) }
        return result
    }

    private func walk(_ node: [String: Any], depth: Int, into lines: inout [String]) {
        var type = "?", pos = "", size = ""
        for p in node["properties"] as? [[String: Any]] ?? [] {
            let id = (p["id"] as? NSNumber)?.intValue ?? -1
            let attr = p["attribute"] as? [String: Any] ?? [:]
            switch id {
            case 0: type = (attr["readableType"] as? String) ?? (attr["type"] as? String) ?? "?"
            case 3: pos = "pos=\(attr["value"] ?? "")"
            case 4: size = "size=\(attr["value"] ?? "")"
            case 1 where type.contains("Effect"): size += " value=\(String(describing: attr).prefix(300))"
            default: break
            }
        }
        let short = type.count > 110 ? String(type.prefix(110)) + "…" : type
        lines.append(String(repeating: "  ", count: depth) + "\(short) \(pos) \(size)".replacingOccurrences(of: "\n", with: ""))
        for c in node["children"] as? [[String: Any]] ?? [] { walk(c, depth: depth + 1, into: &lines) }
    }
}
