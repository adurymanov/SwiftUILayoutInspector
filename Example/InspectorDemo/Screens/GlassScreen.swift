import SwiftUI

/// Cards on Liquid Glass. On iOS 26+ `_ViewDebug` measures what sits under `.glassEffect` from the glass,
/// not from the screen.
@available(iOS 26.0, *)
struct GlassScreen: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                BalanceCard(amount: "€2,480.50", change: "+€120 this month")
                GlassEffectContainer(spacing: 12) {
                    HStack(spacing: 12) {
                        QuickAction(title: "Top up", symbol: "plus")
                        QuickAction(title: "Send", symbol: "arrow.up.right")
                            .offset(x: 8)
                    }
                    .padding(.horizontal, 4)
                }
                PlainCard(title: "Savings goal", subtitle: "Same card without glass")
                TransactionsCard(rows: [.init(title: "Coffee Lab", amount: "−€4.20"), .init(title: "Metro", amount: "−€2.10"),
                                         .init(title: "Salary", amount: "+€3,100.00")])
            }
            .padding(16)
        }
        .background(LinearGradient(colors: [.orange, .purple], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
        .navigationTitle("Liquid Glass")
        .navigationBarTitleDisplayMode(.inline)
    }
}

@available(iOS 26.0, *)
struct BalanceCard: View {
    let amount: String
    let change: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Balance").font(.subheadline).foregroundStyle(.secondary)
            Text(amount).font(.largeTitle.bold())
            Text(change).font(.footnote)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }
}

@available(iOS 26.0, *)
struct QuickAction: View {
    let title: String
    let symbol: String

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.headline)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .glassEffect(.regular.interactive())
    }
}

struct PlainCard: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(subtitle).font(.caption)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.35), in: .rect(cornerRadius: 28))
    }
}

/// Built like the widget cards of a banking home screen.
@available(iOS 26.0, *)
struct TransactionsCard: View {
    struct Row: Hashable {
        let title: String
        let amount: String
    }

    let rows: [Row]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Transactions").font(.title3.bold())
                Spacer()
                Text("See all").font(.subheadline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .glassEffect()
            }
            ForEach(rows, id: \.title) { row in
                HStack {
                    Text(row.title)
                    Spacer()
                    Text(row.amount).monospacedDigit()
                }
            }
        }
        .padding(20)
        .modifier(WidgetGlassCard())
    }
}

@available(iOS 26.0, *)
struct WidgetGlassCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color.clear.contentShape(.rect).onTapGesture {})
            .glassEffect(Glass.clear.tint(nil).interactive(true), in: .rect(cornerRadius: 28, style: .continuous))
    }
}
