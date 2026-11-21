import SwiftUI
import XCTest
@_spi(Diagnostics) import LayoutInspector

/// Every captured text sits where SwiftUI drew it: the frame the capture reports equals the text's frame in the
/// window, read by the view itself with `onGeometryChange`. One small screen per layout construct.
@MainActor
final class PlacementTests: XCTestCase {
    private static let tolerance: CGFloat = 0.5

    func test_offsetOnContainerInScroll() async throws {
        try await assertPlacement {
            ScrollView {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 0)
                    VStack(spacing: 8) {
                        PlacementProbe("Offset title").padding(.top, 40)
                        PlacementProbe("Offset subtitle")
                    }
                    Card { PlacementProbe("Offset card") }
                    Spacer()
                }
                .offset(y: -22)
            }
        }
    }

    func test_offsetOnText() async throws {
        try await assertPlacement {
            VStack {
                PlacementProbe("Moved text").offset(x: 12, y: -30)
                PlacementProbe("Still text")
            }
        }
    }

    func test_offsetOnPlainText() async throws {
        try await assertPlacement {
            VStack(spacing: 30) {
                probe("Plain moved").offset(x: 12, y: -30)
                probe("Plain still")
                HStack { probe("Row moved") }.padding(8).background(.yellow).offset(x: -20, y: 10)
            }
        }
    }

    func test_nestedOffsets() async throws {
        try await assertPlacement {
            VStack(spacing: 8) {
                probe("Nested top").padding(.top, 10)
                VStack {
                    probe("Nested inner").offset(x: 5, y: 5)
                    Card { probe("Nested card") }.offset(y: 12)
                }
                .offset(y: -20)
            }
        }
    }

    func test_offsetInLazyStack() async throws {
        try await assertPlacement {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(0..<3) { i in Card { probe("Lazy offset \(i)") }.offset(x: CGFloat(i) * 4) }
                }
                .offset(y: -10)
            }
        }
    }

    func test_componentOffsetInside() async throws {
        try await assertPlacement {
            VStack(spacing: 20) {
                Shifted { PlacementProbe("Shifted A") }
                Shifted { Card { PlacementProbe("Shifted card") } }
            }
        }
    }

    func test_negativePaddingInScroll() async throws {
        try await assertPlacement {
            ScrollView {
                VStack { PlacementProbe("Negative padding") }.padding(.top, -8)
                PlacementProbe("After negative")
            }
        }
    }

    func test_safeAreaInsetAndToolbar() async throws {
        try await assertPlacement {
            ScrollView { PlacementProbe("Scrolled body") }
                .safeAreaInset(edge: .bottom) { PlacementProbe("Bottom inset").padding() }
                .toolbar { ToolbarItem(placement: .principal) { PlacementProbe("Principal") } }
                .navigationBarTitleDisplayMode(.inline)
        }
    }

    func test_position() async throws {
        try await assertPlacement {
            ZStack {
                PlacementProbe("Positioned").position(x: 100, y: 300)
            }
        }
    }

    func test_geometryReaderAndOverlay() async throws {
        try await assertPlacement {
            GeometryReader { proxy in
                VStack {
                    PlacementProbe("In reader").padding(.top, proxy.size.height / 4)
                    Color.gray.frame(height: 80).overlay(alignment: .bottomTrailing) { PlacementProbe("In overlay") }
                    Color.gray.frame(height: 80).background(alignment: .topLeading) { PlacementProbe("In background") }
                }
            }
        }
    }

    func test_buttonsAndLabels() async throws {
        try await assertPlacement {
            VStack(spacing: 24) {
                Button {} label: { PlacementProbe("Plain button") }
                Button {} label: { PlacementProbe("Bordered button") }.buttonStyle(.borderedProminent)
                Label { PlacementProbe("Label title") } icon: { Image(systemName: "star") }
            }
        }
    }

    func test_lazyStackInScrollWithMargins() async throws {
        try await assertPlacement {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(0..<4) { i in Card { PlacementProbe("Lazy row \(i)") } }
                }
            }
            .contentMargins(.top, 30, for: .scrollContent)
        }
    }

    func test_effectsThatKeepGeometry() async throws {
        try await assertPlacement {
            VStack(spacing: 24) {
                PlacementProbe("Clipped").padding().background(.yellow).clipShape(.rect(cornerRadius: 12))
                PlacementProbe("Shadowed").padding().background(.white).shadow(radius: 8)
                PlacementProbe("Masked").padding().mask(RoundedRectangle(cornerRadius: 8))
                PlacementProbe("Faded").opacity(0.5)
                PlacementProbe("Blurred").blur(radius: 1)
            }
        }
    }

    func test_alignmentGuidesAndFrames() async throws {
        try await assertPlacement {
            VStack(alignment: .leading) {
                PlacementProbe("Guided").alignmentGuide(.leading) { _ in -30 }
                PlacementProbe("Framed").frame(width: 200, height: 60, alignment: .bottomTrailing)
                PlacementProbe("Fixed").fixedSize()
            }
        }
    }

    func test_tabView() async throws {
        try await assertPlacement {
            TabView {
                PlacementProbe("Tab content").tabItem { Label("First", systemImage: "house") }
                Text("Other").tabItem { Label("Second", systemImage: "gear") }
            }
        }
    }

    /// A banking app's instrument grid: `Grid { ForEach { GridRow { ForEach { cell } } } }` in a scroll view.
    func test_grid() async throws {
        try await assertPlacement {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    probe("Above grid").padding(.top, 30)
                    Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                        ForEach(0..<3) { row in
                            GridRow {
                                ForEach(0..<3) { column in GridCard(label: "Cell \(row)-\(column)") }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
    }

    /// `.accessibilityRepresentation { content }` in a modifier (a banking app's pressable card) can put a second copy
    /// of the content into `_ViewDebug`, laid out on its own and not on screen. Only the copy on screen is captured.
    func test_accessibilityRepresentation_isNotCaptured() async throws {
        try await assertPlacement {
            ScrollView {
                VStack(spacing: 24) {
                    ForEach(0..<3) { i in
                        VStack { probe("Represented \(i)") }.padding(20).modifier(PressableCard())
                    }
                }
                .padding(.top, 200)
            }
        }
        let harness = ScreenHarness(VStack { Text("Represented") }.padding(20).modifier(PressableCard()))
        defer { harness.tearDown() }
        let capture = try await harness.waitUntilLoaded()
        let texts = capture.nodes(.text).filter { $0.text?.string == "Represented" && $0.isVisible }
        XCTAssertEqual(texts.count, 1)
        // The copy on screen is centred in the window; the hidden one is laid out from its own corner.
        XCTAssertEqual(try XCTUnwrap(texts.first).frame.midX, harness.window.bounds.midX, accuracy: 1, "the copy on screen")
    }

    /// An app view whose first child reaches under the safe area: its content is measured in the screen's space, no
    /// space of its own opens.
    func test_componentReachingUnderSafeArea() async throws {
        try await assertPlacement {
            VStack(spacing: 0) {
                SafeAreaHeader()
                probe("Below header")
                Spacer()
            }
        }
    }

    /// A banking app's passcode dots: an app `GeometryEffect` on the row, a scale on the stack and, on every dot, a scale,
    /// an offset and another app `GeometryEffect`.
    func test_passcodeDots() async throws {
        try await assertPlacement {
            VStack {
                Spacer().frame(height: 200)
                ZStack {
                    Image(systemName: "checkmark").opacity(0)
                    HStack(spacing: 24) {
                        ForEach(0..<4) { i in
                            ZStack { probe("Dot \(i)").compositingGroup().frame(width: 40, height: 20) }
                                .frame(width: 44, height: 24)
                                .scaleEffect(1)
                                .offset(x: 0)
                                .modifier(Wave(scale: 1, shift: 8))
                                .modifier(Stoppable())
                        }
                    }
                    .opacity(1)
                    .scaleEffect(1)
                }
                .padding(.vertical, 4)
                .modifier(Shake(amount: 0))
                Spacer()
            }
        }
    }

    /// The passcode dot itself: a circle with a blend mode in a compositing group, centred in a larger frame.
    func test_blendedCircleInFrame() async throws {
        ProbeStore.frames = [:]
        let harness = ScreenHarness(
            HStack(spacing: 20) {
                ForEach(0..<3) { i in
                    ZStack {
                        Circle()
                            .foregroundColor(.gray)
                            .blendMode(.multiply)
                            .compositingGroup()
                            .frame(width: 12, height: 12)
                            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { ProbeStore.frames["dot \(i)"] = $0 }
                    }
                    .frame(width: 28, height: 28)
                    .scaleEffect(1)
                    .modifier(Wave(scale: 1.25, shift: 8))
                }
            }
            .modifier(Shake(amount: 0))
        )
        defer { harness.tearDown() }
        let capture = try await harness.waitUntilLoaded()
        let circles = capture.nodes(.shape).filter { $0.title == "Circle" && $0.isVisible }.map(\.frame).sorted { $0.minX < $1.minX }
        let truth = (0..<3).compactMap { ProbeStore.frames["dot \($0)"] }.sorted { $0.minX < $1.minX }
        XCTAssertEqual(circles.count, 3)
        for (captured, real) in zip(circles, truth) {
            XCTAssertEqual(captured.minX, real.minX, accuracy: 0.5)
            XCTAssertEqual(captured.minY, real.minY, accuracy: 0.5)
        }
    }

    /// A chat feed: the scroll view is turned upside down and every row turned back.
    func test_flippedList() async throws {
        try await assertPlacement {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(0..<4) { i in
                        Card { probe("Message \(i)") }.rotationEffect(.degrees(180))
                    }
                }
            }
            .rotationEffect(.degrees(180))
        }
    }

    func test_scaledAndRotated() async throws {
        try await assertPlacement {
            VStack(spacing: 40) {
                Card { probe("Scaled card") }.scaleEffect(0.8)
                Card { probe("Scaled from corner") }.scaleEffect(0.5, anchor: .topLeading)
                probe("Upside down").rotationEffect(.degrees(180))
                HStack { probe("Turned row") }.padding().rotationEffect(.degrees(180))
                probe("Quarter turn").rotationEffect(.degrees(90), anchor: .topLeading).frame(height: 90)
            }
        }
    }

    func test_effectsInsideEffects() async throws {
        try await assertPlacement {
            VStack(spacing: 50) {
                Card { probe("Moved in scaled").offset(x: 10, y: 6) }.scaleEffect(0.8, anchor: .leading)
                Card { Card { probe("Scaled twice") }.scaleEffect(0.9) }.scaleEffect(0.8)
                probe("Transformed").transformEffect(CGAffineTransform(translationX: 30, y: 12).scaledBy(x: 1.2, y: 1.2))
                Card { probe("Turned in scaled").rotationEffect(.degrees(30)) }.scaleEffect(0.9)
            }
        }
    }

    /// Under a full-screen cover the screen below stays in the window, but none of it is visible. A translucent
    /// sheet (Liquid Glass at a partial detent) hides nothing, and nothing outside a presentation is ever hidden.
    func test_presentation_hidesWhatItCovers() async throws {
        let cover = ScreenHarness(
            Text("Below cover").fullScreenCover(isPresented: .constant(true)) { Text("In cover") }
        )
        defer { cover.tearDown() }
        let covered = try await cover.waitUntilLoaded()
        XCTAssertEqual(covered.find("In cover", kind: .text)?.isVisible, true)
        XCTAssertEqual(covered.find("Below cover", kind: .text)?.isVisible, false)
        cover.tearDown()

        let sheet = ScreenHarness(
            VStack {
                Text("Above sheet")
                Spacer()
            }
            .sheet(isPresented: .constant(true)) { Text("In sheet").presentationDetents([.medium]) }
        )
        defer { sheet.tearDown() }
        let sheeted = try await sheet.waitUntilLoaded()
        XCTAssertEqual(sheeted.find("In sheet", kind: .text)?.isVisible, true)
        XCTAssertEqual(sheeted.find("Above sheet", kind: .text)?.isVisible, true)
    }

    // MARK: - Helpers

    private func assertPlacement<V: View>(@ViewBuilder _ content: () -> V,
                                          file: StaticString = #filePath, line: UInt = #line) async throws {
        ProbeStore.frames = [:]
        let harness = ScreenHarness(content())
        defer { harness.tearDown() }
        let capture = try await harness.waitUntilLoaded()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(ProbeStore.frames.isEmpty, "no probes reported a frame", file: file, line: line)
        var problems: [String] = []
        for (label, truth) in ProbeStore.frames.sorted(by: { $0.key < $1.key }) {
            let nodes = capture.nodes(.text).filter { $0.text?.string == label }
            guard let node = nodes.min(by: { distance($0.frame, truth) < distance($1.frame, truth) }) else {
                problems.append("“\(label)” not captured")
                continue
            }
            let d = distance(node.frame, truth)
            if d > Self.tolerance {
                problems.append("“\(label)” off by \(d): captured \(node.frame) real \(truth)")
            }
        }
        // Spacing mode draws a padding as its outer box minus its content: both must be where SwiftUI put them.
        for node in capture.nodes(.padding) {
            guard let padding = node.padding, let declared = padding.declared, !padding.isSystem else { continue }
            let m = padding.measured
            let pairs: [(String, CGFloat, CGFloat)] = [("top", declared.top, m.top), ("leading", declared.leading, m.leading),
                                                      ("bottom", declared.bottom, m.bottom), ("trailing", declared.trailing, m.trailing)]
            for (edge, want, got) in pairs where padding.edges.contains(edge) && abs(want - got) > Self.tolerance {
                problems.append("\(node.title)\(node.detail ?? "") measures \(edge) \(got), declared \(want)")
            }
        }
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"), file: file, line: line)
    }

    private func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        guard !a.isNull else { return .infinity }
        return max(abs(a.minX - b.minX), abs(a.minY - b.minY), abs(a.maxX - b.maxX), abs(a.maxY - b.maxY))
    }
}

/// A plain text (no component of its own) that reports where it is in the window.
@MainActor
func probe(_ label: String) -> some View {
    Text(label).onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { ProbeStore.frames[label] = $0 }
}

@MainActor
enum ProbeStore {
    static var frames: [String: CGRect] = [:]
}

/// A text that reports where it is in the window.
struct PlacementProbe: View {
    let label: String
    init(_ label: String) { self.label = label }

    var body: some View {
        Text(label)
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { ProbeStore.frames[label] = $0 }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(Color.gray.opacity(0.2), in: .rect(cornerRadius: 16))
            .padding(.horizontal, 20)
    }
}

/// Built like a banking app's instrument card: paddings, a background, a clip and `.geometryGroup()`.
struct GridCard: View {
    let label: String
    var body: some View {
        VStack(spacing: 0) {
            Color.orange.frame(width: 32, height: 32)
            probe(label).padding(.top, 12)
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity)
        .background(Color.gray.opacity(0.2))
        .clipShape(.rect(cornerRadius: 16))
        .geometryGroup()
    }
}

struct SafeAreaHeader: View {
    var body: some View {
        VStack(alignment: .leading) { probe("Header title").padding(20) }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.ignoresSafeArea())
    }
}

/// Built like a banking app's pressable card: a button around the content, which is also its accessibility representation.
struct PressableCard: ViewModifier {
    func body(content: Content) -> some View {
        Button {} label: { content.background(Color.gray.opacity(0.2)) }
            .accessibilityRepresentation { content }
            .buttonStyle(.plain)
    }
}

struct Shake: GeometryEffect {
    var amount: CGFloat
    var animatableData: CGFloat {
        get { amount }
        set { amount = newValue }
    }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: -sin(amount * .pi) * 5, y: 0))
    }
}

/// Built like a banking app's `ScaleWaveEffect`: a scale, then a move back by half the dot.
struct Wave: GeometryEffect {
    var scale: CGFloat
    var shift: CGFloat = 0
    var animatableData: CGFloat {
        get { scale }
        set { scale = newValue }
    }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: -shift, y: -shift))
    }
}

struct Stoppable: ViewModifier {
    func body(content: Content) -> some View { content.animation(nil, value: 0) }
}

/// A component whose body starts with an offset.
struct Shifted<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content.offset(x: 10, y: 15)
    }
}
