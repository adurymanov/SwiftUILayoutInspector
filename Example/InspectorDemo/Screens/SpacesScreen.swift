import SwiftUI

/// Cards under modifiers after which `_ViewDebug` measures positions from the modifier, not from the screen:
/// `.geometryGroup()`, `.drawingGroup()`, the transform effects, `.visualEffect`, a custom `GeometryEffect`.
struct SpacesScreen: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupedCard(title: "Investment portfolio", value: "$0.00")
                SpaceCard(title: "Drawing group", value: "drawingGroup()").drawingGroup()
                SpaceCard(title: "Scaled", value: "scaleEffect(0.95)").scaleEffect(0.95)
                SpaceCard(title: "Rotated", value: "rotationEffect(1°)").rotationEffect(.degrees(1))
                SpaceCard(title: "Visual effect", value: "visualEffect").visualEffect { content, _ in content.offset(y: 0) }
                NudgedRow(title: "Custom effect", value: "GeometryEffect").modifier(Nudge(x: 0))
                SpaceCard(title: "Compositing group", value: "same space").compositingGroup()
                SpaceCard(title: "Moved", value: "offset(x: 8)").offset(x: 8)
                SpaceCard(title: "Scaled and moved", value: "scaleEffect(0.95).offset(x: 8)").scaleEffect(0.95).offset(x: 8)
            }
            .padding(16)
        }
        .navigationTitle("Coordinate spaces")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Built like a banking widget whose `body` is `content.geometryGroup()`.
struct GroupedCard: View {
    let title: String
    let value: String

    var body: some View {
        content.geometryGroup()
    }

    private var content: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(value).font(.title2.bold())
                Text(title).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chart.pie.fill").foregroundStyle(.tint)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color(.secondarySystemBackground)))
    }
}

struct SpaceCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(value).font(.caption.monospaced())
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 20))
    }
}

struct NudgedRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            Text(value).font(.caption.monospaced())
        }
        .padding(20)
        .background(Color(.tertiarySystemBackground), in: .capsule)
    }
}

struct Nudge: GeometryEffect {
    var x: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform { ProjectionTransform(CGAffineTransform(translationX: x, y: 0)) }
}
