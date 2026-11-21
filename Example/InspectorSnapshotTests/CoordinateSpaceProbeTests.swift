import XCTest
import SwiftUI
@_spi(Diagnostics) import LayoutInspector

/// Research probe: which modifiers make `_ViewDebug` measure the positions below them from themselves.
@MainActor
final class CoordinateSpaceProbeTests: XCTestCase {
    struct Card: View {
        let label: String
        var body: some View { Text(label).padding(8).background(Color.yellow) }
    }

    struct Shift: GeometryEffect {
        var dx: CGFloat
        func effectValue(size: CGSize) -> ProjectionTransform { ProjectionTransform(CGAffineTransform(translationX: dx, y: 0)) }
    }

    /// Like a widget whose `body` is `content.geometryGroup()`.
    struct Wrapper: View {
        var body: some View { VStack { Card(label: "inWrapper") }.geometryGroup() }
    }

    struct Probe: View {
        @Namespace var ns
        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Card(label: "plain")
                    Card(label: "geometryGroup").geometryGroup()
                    Card(label: "drawingGroup").drawingGroup()
                    Card(label: "compositingGroup").compositingGroup()
                    Card(label: "visualEffect").visualEffect { c, _ in c.offset(x: 0) }
                    Card(label: "scrollTransition").scrollTransition { c, _ in c.opacity(1) }
                    Card(label: "containerRelativeFrame").containerRelativeFrame(.horizontal) { w, _ in w / 2 }
                    Card(label: "mask").mask(Rectangle())
                    Card(label: "clipShape").clipShape(RoundedRectangle(cornerRadius: 4))
                    Card(label: "shadow").shadow(radius: 2)
                    Card(label: "blur").blur(radius: 0.5)
                    Card(label: "scaleEffect").scaleEffect(0.9)
                    Card(label: "rotationEffect").rotationEffect(.degrees(1))
                    Card(label: "rotation3D").rotation3DEffect(.degrees(5), axis: (1, 0, 0))
                    Card(label: "blendMode").blendMode(.multiply)
                    Card(label: "opacity").opacity(0.9)
                    Card(label: "colorInvert").colorInvert()
                    Card(label: "brightness").brightness(0.1)
                    Card(label: "projectionEffect").projectionEffect(ProjectionTransform(CGAffineTransform(translationX: 1, y: 0)))
                    Card(label: "transformEffect").transformEffect(CGAffineTransform(translationX: 1, y: 0))
                    Card(label: "contentShape").contentShape(Rectangle())
                    Card(label: "luminanceToAlpha").luminanceToAlpha()
                    Card(label: "overlayGroup").overlay(Card(label: "inOverlay"))
                    Card(label: "customGeometryEffect").modifier(Shift(dx: 0))
                    Card(label: "matchedGeometry").matchedGeometryEffect(id: 1, in: ns)
                    Card(label: "offset").offset(x: 3, y: 0)
                    Card(label: "scrollTransitionScale").scrollTransition { c, _ in c.scaleEffect(1) }
                    Card(label: "nestedGroups").geometryGroup().padding(4).geometryGroup()
                    Wrapper()
                    Card(label: "groupUnderOffset").geometryGroup().offset(x: 5)
                    Card(label: "visualEffectMoved").visualEffect { c, _ in c.offset(x: 10) }
                    Card(label: "scrollTransitionMoved").scrollTransition { c, _ in c.offset(x: 10) }
                    Card(label: "customEffectMoved").modifier(Shift(dx: 10))
                    Card(label: "scaleThenOffset").scaleEffect(0.95).offset(x: 8)
                    Card(label: "flipRTL").flipsForRightToLeftLayoutDirection(true)
                    glassRow
                }
                .padding(.leading, 40)
                .padding(.top, 30)
            }
        }

        @ViewBuilder var glassRow: some View {
            if #available(iOS 26.0, *) {
                Card(label: "glassEffect").glassEffect()
                GlassEffectContainer { Card(label: "glassContainer").glassEffect() }
            }
        }
    }

    func test_probe() async throws {
        guard let out = ProcessInfo.processInfo.environment["GOLDEN_OUT"] else { throw XCTSkip("set GOLDEN_OUT=<dir>") }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.rootViewController = UIHostingController(rootView: Probe())
        window.isHidden = false
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(800))
        var text: [String] = []
        func walk(_ v: UIView) {
            if let dump = LayoutInspector.debugDataDump(of: v) { text.append("## \(type(of: v))\n" + dump) }
            v.subviews.forEach(walk)
        }
        walk(window)
        // Positions and types only.
        let lines = text.joined(separator: "\n").split(separator: "\n").map { line -> String in
            let parts = line.components(separatedBy: " | ")
            return parts.count >= 4 ? "\(parts[1]) | \(parts[2]) | \(parts[3])".replacingOccurrences(of: "  ", with: "  ") : String(line)
        }
        let indented = zip(text.joined(separator: "\n").split(separator: "\n"), lines).map { full, short in
            String(full.prefix { $0 == " " }) + short
        }
        try indented.joined(separator: "\n").write(toFile: out + "/coordinate-spaces.txt", atomically: true, encoding: .utf8)
    }
}
