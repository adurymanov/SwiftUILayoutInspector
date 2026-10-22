import SwiftUI

struct DashboardScreen: View {
    @State private var metrics: [Metric] = []
    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DashboardHeader()
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(metrics) { MetricTile(metric: $0) }
                }
                if metrics.isEmpty { ProgressView().frame(maxWidth: .infinity) }
                UpdatedRow()
            }
            .padding(16)
        }
        .navigationTitle("Dashboard")
        .task { metrics = await DemoAPI.shared.metrics() }
    }
}

struct DashboardHeader: View {
    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Good morning").font(.subheadline).foregroundStyle(.secondary)
                Text("Store overview").font(.title.bold())
            }
            Spacer()
            Button {} label: {
                Image(systemName: "bell.badge")
                    .frame(width: 32, height: 32)   // < 44pt tap target – see Lint mode
                    .background(Circle().fill(Color(.tertiarySystemFill)))
            }
        }
    }
}

struct MetricTile: View {
    let metric: Metric

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: metric.symbol).font(.title3).foregroundStyle(metric.tint)
                Spacer()
                Text(metric.delta)
                    .font(.system(size: 11.5, weight: .semibold))   // not in the type scale – see Lint mode
                    .foregroundStyle(metric.delta.hasPrefix("+") ? .green : .orange)
            }
            Text(metric.value).font(.system(size: 28, weight: .bold, design: .rounded))
            HStack(alignment: .bottom) {
                Text(metric.title).font(.footnote).foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Sparkline(points: metric.points)
                    .stroke(metric.tint, lineWidth: 2)
                    .frame(width: 56, height: 20)
            }
        }
        .padding(14)
        .frame(height: 128)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemBackground)))
    }
}

struct Sparkline: Shape {
    let points: [Double]

    func path(in rect: CGRect) -> Path {
        Path { p in
            guard let min = points.min(), let max = points.max(), max > min else { return }
            for (i, v) in points.enumerated() {
                let pt = CGPoint(x: rect.minX + rect.width * CGFloat(i) / CGFloat(points.count - 1),
                                 y: rect.maxY - rect.height * CGFloat((v - min) / (max - min)))
                i == 0 ? p.move(to: pt) : p.addLine(to: pt)
            }
        }
    }
}

struct UpdatedRow: View {
    var body: some View {
        HStack(spacing: 8) {
            Text("Data is aggregated across all sales channels and refreshed automatically")
                .font(.footnote)
                .lineLimit(1)
            Text("5 min ago")
                .font(.footnote.weight(.semibold))
                .fixedSize()
                .layoutPriority(1)
        }
        .foregroundStyle(.secondary)
    }
}
