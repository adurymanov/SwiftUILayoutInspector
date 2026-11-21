import Observation
import SwiftUI

/// One `@Observable` model, read by different views: changing a property re-renders only its readers.
@Observable final class RerenderModel {
    var balance = 0
    var notifications = 0
    let quotes = [Quote(price: 120), Quote(price: 80), Quote(price: 45)]
}

@Observable final class Quote {
    var price: Int
    init(price: Int) { self.price = price }
}

struct WalletBalance: View {
    let model: RerenderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Balance").font(.subheadline).foregroundStyle(.secondary)
            Text("$\(model.balance)").font(.largeTitle.bold())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct InboxBadge: View {
    let model: RerenderModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack {
            Image(systemName: "bell")
            Text("\(model.notifications) new")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.orange.opacity(colorScheme == .dark ? 0.3 : 0.15), in: Capsule())
    }
}

/// Reads its own quote: changing one price re-renders one row.
struct QuoteRow: View {
    let quote: Quote
    let index: Int

    var body: some View {
        HStack {
            Text("Item \(index + 1)")
            Spacer()
            Text("$\(quote.price)").monospacedDigit()
        }
        .padding(.vertical, 8)
    }
}

/// Reads nothing from the model.
struct HintFooter: View {
    let text: String

    var body: some View {
        Text(text).font(.footnote).foregroundStyle(.secondary)
    }
}

struct TapCounter: View {
    @State private var taps = 0
    @State private var label = "Tapped"

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.tap")
            Button("\(label) \(taps) times") { taps += 1 }
                .buttonStyle(.bordered)
        }
    }
}

struct RerenderScreen: View {
    @State private var model: RerenderModel
    @State private var ticking = false

    init(model: RerenderModel = RerenderModel()) {
        _model = State(initialValue: model)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                WalletBalance(model: model)
                InboxBadge(model: model)
                VStack(spacing: 0) {
                    ForEach(model.quotes.indices, id: \.self) { QuoteRow(quote: model.quotes[$0], index: $0) }
                }
                TapCounter()
                HStack {
                    Button("Balance +1") { model.balance += 1 }
                    Button("Notify") { model.notifications += 1 }
                    Button("Item 2") { model.quotes[1].price += 1 }
                }
                .buttonStyle(.borderedProminent)
                Toggle("Tick balance every 0.2 s", isOn: $ticking)
                HintFooter(text: "Turn on Dev → Re-renders: only the views that read a changed property heat up.")
                    .dynamicTypeSize(.xxLarge)
            }
            .padding(20)
        }
        .navigationTitle("Re-renders")
        .task(id: ticking) {
            while ticking, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                model.balance += 1
            }
        }
    }
}
