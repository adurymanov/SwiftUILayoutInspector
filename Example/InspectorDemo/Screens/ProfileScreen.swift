import SwiftUI

struct ProfileScreen: View {
    @State private var state: LoadState<Profile> = .loading

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView("Loading profile…")
            case .loaded(let profile):
                ProfileContent(profile: profile)
            }
        }
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .task { state = .loaded(await DemoAPI.shared.profile()) }
    }
}

private struct ProfileContent: View {
    let profile: Profile

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ProfileHeader(profile: profile)
                StatsRow(stats: profile.stats)
                Button {} label: {
                    Text("Follow").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                BioSection(text: profile.bio)
                TagCloud(tags: profile.tags)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
    }
}

struct ProfileHeader: View {
    let profile: Profile

    var body: some View {
        HStack(spacing: 14) {
            AvatarView(initials: profile.initials)
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(profile.name).font(.title2.bold())
                Text(profile.handle).font(.subheadline).foregroundStyle(.secondary)
                Label(profile.city, systemImage: "mappin.and.ellipse")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

struct AvatarView: View {
    let initials: String

    var body: some View {
        Circle()
            .fill(LinearGradient(colors: [.pink, .orange], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(Text(initials).font(.title3.weight(.semibold)).foregroundStyle(.white))
    }
}

struct StatsRow: View {
    let stats: [Profile.Stat]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(stats, id: \.self) { stat in
                VStack(spacing: 2) {
                    Text(stat.value).font(.headline)
                    Text(stat.title).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
    }
}

struct BioSection: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("About").font(.headline)
            Text(text)
                .font(.body)
                .lineLimit(3)
        }
    }
}

struct TagCloud: View {
    let tags: [String]

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
            }
        }
    }
}

/// Custom `Layout` – shows up in the inspector under its own name.
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (i, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if rows[rows.count - 1].width + size.width > width, !rows[rows.count - 1].indices.isEmpty {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
            }
            rows[rows.count - 1].indices.append(i)
            rows[rows.count - 1].width += size.width + (rows[rows.count - 1].indices.count > 1 ? spacing : 0)
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}
