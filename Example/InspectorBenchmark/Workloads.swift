import SwiftUI

/// Deterministic, synchronous content: no async data, nothing random – only SwiftUI's own work is measured.
@Observable
final class ListModel {
    struct Row: Identifiable {
        let id: Int
        let title: String
        let subtitle: String
        let price: Int
        let symbol: String
    }

    static let symbols = ["cart", "bag", "creditcard", "gift", "tag", "shippingbox", "star", "heart"]

    var rows: [Row]
    var highlighted = -1
    var tick = 0

    init(count: Int) {
        rows = (0..<count).map { i in
            Row(id: i, title: "Item number \(i)", subtitle: "Description of the item \(i), long enough to wrap onto a second line",
                price: 10 + i * 3, symbol: Self.symbols[i % Self.symbols.count])
        }
    }
}

struct RowView: View {
    let row: ListModel.Row
    let isHighlighted: Bool
    let tick: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: row.symbol)
                .font(.title2)
                .frame(width: 44, height: 44)
                .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text(row.title).font(.headline).lineLimit(1)
                Text(row.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            Text("\(row.price + tick) €")
                .font(.body.monospacedDigit())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(isHighlighted ? Color.orange : Color.gray.opacity(0.15), in: Capsule())
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

/// 100 rows in an eager `VStack`: everything is built and laid out.
struct CardList: View {
    let model: ListModel

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(model.rows) { row in
                    RowView(row: row, isHighlighted: model.highlighted == row.id, tick: model.tick)
                }
            }
            .padding(16)
        }
    }
}

/// 2000 rows in a `LazyVStack`: rows are built while scrolling.
struct LazyFeed: View {
    let model: ListModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(model.rows) { row in
                    RowView(row: row, isHighlighted: false, tick: 0)
                }
            }
            .padding(16)
        }
    }
}

/// A settings-like `Form`: deep hierarchy, UIKit-backed controls.
struct SettingsForm: View {
    @State private var toggles = Array(repeating: true, count: 48)
    @State private var texts = Array(repeating: "Value", count: 48)
    @State private var choice = 1

    var body: some View {
        NavigationStack {
            Form {
                ForEach(0..<8, id: \.self) { section in
                    Section("Section \(section)") {
                        ForEach(0..<6, id: \.self) { item in
                            let index = section * 6 + item
                            switch item % 4 {
                            case 0: Toggle("Option \(index)", isOn: $toggles[index])
                            case 1: TextField("Field \(index)", text: $texts[index])
                            case 2: Picker("Choice \(index)", selection: $choice) { Text("One").tag(1); Text("Two").tag(2) }
                            default: LabeledContent("Label \(index)", value: "\(index * 7)")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}
