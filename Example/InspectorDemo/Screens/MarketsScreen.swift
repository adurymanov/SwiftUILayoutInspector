import Combine
import SwiftUI

// A trading app's home, built the way such screens are built in a big app: every price is a generic streaming wrapper
// around a TimelineView, with an overlay whose body is usually empty; prices are a conditional-body text component
// with the same "0.00%" in many places; cards are a geometry group with a press modifier; icons are a generic image
// view with a state object; and the tab bar is drawn by hosting controllers, two per tab at the same place.

/// A text component with a conditional body, the way design systems hide sensitive amounts.
struct AmountText: View {
    enum Content { case plain(String), attributed(AttributedString) }

    let content: Content
    @Environment(\.redactionReasons) private var redaction

    init(_ string: String) { content = .plain(string) }
    init(_ string: AttributedString) { content = .attributed(string) }

    var body: some View {
        if redaction.contains(.privacy) {
            text.privacySensitive()
        } else {
            text.allowsHitTesting(false)
        }
    }

    private var text: Text {
        switch content {
        case .plain(let string): Text(string)
        case .attributed(let string): Text(string)
        }
    }
}

/// A change in price: an arrow and a percent.
struct PriceDelta: View {
    let percent: Double

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: percent >= 0 ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill").font(.system(size: 8))
            HStack(spacing: 0) {
                AmountText(String(format: "%.2f%%", percent))
            }
            .foregroundStyle(percent >= 0 ? .green : .red)
        }
        .font(.footnote)
        .frame(height: 16)
    }
}

/// Usually draws nothing: a debug dot when the stream failed.
struct StreamErrorDot: View {
    let failed: Bool

    var body: some View {
        if failed {
            Circle().fill(.red.opacity(0.3)).frame(width: 10, height: 10)
        }
    }
}

@Observable final class StreamModel {
    var failed = false
}

/// One instrument's price change, as the stream last sent it.
@Observable final class MarketQuote {
    var percent: Double
    init(percent: Double) { self.percent = percent }
}

@Observable final class MarketsModel {
    let quotes = Dictionary(uniqueKeysWithValues: MarketsScreen.symbols.map { ($0, MarketQuote(percent: 0)) })
    var balance = 5000.0
}

/// A value from a stream, redrawn by a TimelineView every second.
struct StreamValue<T, Content: View>: View {
    @State private var model = StreamModel()
    let value: () -> T?
    let content: (T?) -> Content

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            content(value())
        }
        .onAppear {}
        .overlay(alignment: .topLeading) { StreamErrorDot(failed: model.failed) }
    }
}

/// One instrument's price change, streamed.
struct PriceChangeStream<Content: View>: View {
    let quote: MarketQuote
    @ViewBuilder let content: (Double?) -> Content

    var body: some View {
        StreamValue<Double, Content>(value: { quote.percent }, content: content)
    }
}

/// Animates a streamed value's changes.
struct ValueAnimation<V: Equatable>: ViewModifier {
    @State private var isEnabled = false
    let value: V

    func body(content: Content) -> some View {
        content
            .contentTransition(isEnabled ? .numericText() : .identity)
            .animation(isEnabled ? .easeInOut : nil, value: value)
            .task { isEnabled = true }
    }
}

final class RemoteImageModel: ObservableObject {
    @Published var image: Image?
}

/// An image loaded from a URL, with a placeholder; never loads in the demo.
struct RemoteImage<Content: View>: View {
    @StateObject private var model = RemoteImageModel()
    @Environment(\.displayScale) private var scale
    let url: URL?
    @ViewBuilder let content: (Image?) -> Content

    var body: some View {
        content(model.image)
            .task {}
            .overlay { mockOverlay }
    }

    @ViewBuilder private var mockOverlay: some View {
        if let image = model.image { image.resizable() }
    }
}

/// A light band sweeping across the view, again and again: `Animatable`, so its `body` runs on every frame.
struct Shimmer: ViewModifier, Animatable {
    var position: CGFloat
    var animatableData: CGFloat {
        get { position }
        set { position = newValue }
    }

    func body(content: Content) -> some View {
        content.overlay {
            GeometryReader { proxy in
                LinearGradient(colors: [.clear, .white.opacity(0.6), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: proxy.size.width * 0.3)
                    .offset(x: proxy.size.width * (position * 1.6 - 0.3))
            }
            .allowsHitTesting(false)
        }
        .clipped()
    }
}

@Observable final class ShimmerSwitch {
    var isOn: Bool
    init(isOn: Bool = true) { self.isOn = isOn }
}

/// A button whose shimmer runs as long as it is on screen.
struct NewProductsButton: View {
    var shimmer = ShimmerSwitch()
    @State private var sweeping = false

    var body: some View {
        Text("Open a new product")
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.accentColor, in: Capsule())
            .foregroundStyle(.white)
            .modifier(Shimmer(position: sweeping ? 1 : 0))
            .onChange(of: shimmer.isOn, initial: true) { _, isOn in
                guard isOn else { return }
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { sweeping = true }
            }
    }
}

/// An instrument's logo.
struct InstrumentIcon: View {
    let symbol: String
    var expiring = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RemoteImage(url: URL(string: "https://example.com/\(symbol).png")) { image in
                if let image { image.resizable() } else { Circle().fill(.gray.opacity(0.25)) }
            }
            .frame(width: 40, height: 40)
            .clipShape(Circle())
            if expiring {
                Image(systemName: "clock").font(.system(size: 9)).padding(2).background(.background, in: Circle())
            }
        }
        .opacity(1)
    }
}

/// Changes the background while pressed, and calls `action` on release.
struct PressColor: ViewModifier {
    let normal: Color
    let pressed: Color
    let action: () -> Void
    @GestureState private var isPressed = false

    func body(content: Content) -> some View {
        content
            .background(isPressed ? pressed : normal)
            .gesture(DragGesture(minimumDistance: 0).updating($isPressed) { _, state, _ in state = true }.onEnded { _ in action() })
    }
}

struct InstrumentCard: View {
    let symbol: String
    let quote: MarketQuote

    var body: some View {
        VStack(spacing: 0) {
            InstrumentIcon(symbol: symbol)
            Spacer().frame(height: 12)
            AmountText(symbol).font(.subheadline.weight(.semibold))
            Spacer().frame(height: 2)
            PriceChangeStream(quote: quote) { percent in
                PriceDelta(percent: percent ?? 0).modifier(ValueAnimation(value: percent ?? 0))
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity)
        .modifier(PressColor(normal: Color.gray.opacity(0.1), pressed: Color.gray.opacity(0.2), action: {}))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .geometryGroup()
    }
}

struct InstrumentRow: View {
    let symbol: String
    let name: String
    let quote: MarketQuote

    var body: some View {
        PriceChangeStream(quote: quote) { percent in
            HStack(spacing: 12) {
                InstrumentIcon(symbol: symbol, expiring: symbol.hasPrefix("A"))
                VStack(alignment: .leading, spacing: 2) {
                    AmountText(name).font(.body)
                    AmountText(symbol).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                PriceDelta(percent: percent ?? 0).modifier(ValueAnimation(value: percent ?? 0))
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 20)
        }
    }
}

struct PortfolioSummary: View {
    let model: MarketsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AmountText("Portfolio").font(.headline)
            HStack {
                StreamValue<Double, _>(value: { model.balance }) { amount in
                    AmountText(String(format: "USD %.2f", amount ?? 5000)).font(.title2.bold())
                        .modifier(ValueAnimation(value: amount ?? 0))
                }
                Spacer()
                StreamValue<Double, _>(value: { nil }) { percent in
                    PriceDelta(percent: percent ?? 0)
                }
            }
        }
        .padding(20)
        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 20))
    }
}

struct MarketsScreen: View {
    @State private var model: MarketsModel

    let showsShimmer: Bool

    init(model: MarketsModel = MarketsModel(), showsShimmer: Bool = true) {
        _model = State(initialValue: model)
        self.showsShimmer = showsShimmer
    }

    static let symbols = ["AAPL", "MSFT", "NVDA", "AMZN", "GOOG", "META", "TSLA", "NFLX", "AMD", "INTC", "ORCL", "ADBE"]
    private let grid = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PortfolioSummary(model: model)
                if showsShimmer { NewProductsButton() }
                AmountText("Popular").font(.title3.bold())
                LazyVGrid(columns: grid, spacing: 8) {
                    ForEach(Self.symbols.prefix(6), id: \.self) { InstrumentCard(symbol: $0, quote: model.quotes[$0]!) }
                }
                AmountText("Watchlist").font(.title3.bold())
                VStack(spacing: 0) {
                    ForEach(Self.symbols, id: \.self) { InstrumentRow(symbol: $0, name: "\($0) Inc.", quote: model.quotes[$0]!) }
                }
                .padding(.horizontal, -20)
            }
            .padding(20)
        }
        .navigationTitle("Markets")
        .safeAreaInset(edge: .bottom) { HostedTabBar().frame(height: 54) }
    }
}

// MARK: - Tab bar drawn by hosting controllers

struct TabItemLabel: View {
    let symbol: String
    let title: String
    let selected: Bool
    var shown = true

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: symbol).font(.system(size: 18))
            Text(title).font(.caption2)
        }
        .foregroundStyle(selected ? Color.accentColor : .secondary)
        .opacity(shown ? 1 : 0.02)
    }
}

/// A UIKit bar with a selected and an unselected hosting controller per tab, both at the item's place.
struct HostedTabBar: UIViewRepresentable {
    static let items = [("chart.pie", "Trade"), ("house", "Home"), ("creditcard", "Cards"), ("person", "Profile")]

    func makeUIView(context: Context) -> UIStackView {
        let stack = UIStackView()
        stack.distribution = .fillEqually
        stack.backgroundColor = .secondarySystemBackground
        for (index, item) in Self.items.enumerated() {
            let slot = UIView()
            for selected in [false, true] {
                let shown = selected == (index == 0)
                let host = UIHostingController(rootView: TabItemLabel(symbol: item.0, title: item.1, selected: selected, shown: shown))
                host.view.backgroundColor = .clear
                host.view.translatesAutoresizingMaskIntoConstraints = false
                slot.addSubview(host.view)
                NSLayoutConstraint.activate([
                    host.view.leadingAnchor.constraint(equalTo: slot.leadingAnchor),
                    host.view.trailingAnchor.constraint(equalTo: slot.trailingAnchor),
                    host.view.topAnchor.constraint(equalTo: slot.topAnchor),
                    host.view.bottomAnchor.constraint(equalTo: slot.bottomAnchor),
                ])
                context.coordinator.hosts.append(host)
            }
            stack.addArrangedSubview(slot)
        }
        return stack
    }

    func updateUIView(_ uiView: UIStackView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var hosts: [UIViewController] = []
    }
}
