import SwiftUI

/// A screen shaped like a big app's home: hundreds of views, nested app components, long modifier chains,
/// toolbar items, Liquid Glass, and views that carry whole data models (each row holds its account with all of
/// its transactions), so SwiftUI's debug values are large. Used to measure the capture, not to look at.
struct HeavyScreen: View {
    @State private var home: HomeData?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if let home {
                    StoriesStrip(stories: home.stories)
                    BalanceHeader(home: home)
                    HomeActionsGrid(actions: home.actions)
                    ForEach(home.accounts) { account in
                        AccountWidget(account: account, home: home)
                    }
                    OffersCarousel(offers: home.offers, home: home)
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(.horizontal, 16)
        }
        .navigationTitle("Home")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button {} label: { Image(systemName: "person.crop.circle") } }
            ToolbarItem(placement: .topBarTrailing) { Button {} label: { Image(systemName: "bell") } }
            ToolbarItem(placement: .topBarTrailing) { Button {} label: { Image(systemName: "qrcode.viewfinder") } }
        }
        .safeAreaInset(edge: .bottom) { if let home { TabBarMock(home: home) } }
        .task { home = await DemoAPI.shared.home() }
    }
}

private extension View {
    func card() -> some View { modifier(CardModifier()) }

    @ViewBuilder func glassCard(cornerRadius: CGFloat = 24) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            background(RoundedRectangle(cornerRadius: cornerRadius).fill(.ultraThinMaterial))
        }
    }
}

struct CardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(.secondarySystemBackground)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color(.separator), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
    }
}

struct StoriesStrip: View {
    let stories: [Story]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(stories) { StoryBubble(story: $0) }
            }
            .padding(.vertical, 4)
        }
    }
}

struct StoryBubble: View {
    let story: Story

    var body: some View {
        VStack(spacing: 4) {
            Circle()
                .fill(story.tint.gradient)
                .frame(width: 64, height: 64)
                .overlay(Image(systemName: story.symbol).font(.title2).foregroundStyle(.white))
                .overlay(Circle().stroke(story.isSeen ? Color(.separator) : .accentColor, lineWidth: 2).padding(-3))
            Text(story.title).font(.caption2).lineLimit(1).frame(width: 68)
        }
    }
}

struct BalanceHeader: View {
    let home: HomeData

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Total balance").font(.subheadline).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(home.totalBalance).font(.system(size: 34, weight: .bold, design: .rounded))
                Text(home.currency).font(.title3.weight(.semibold)).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                ForEach(home.highlights, id: \.self) { HighlightChip(text: $0) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard()
    }
}

struct HighlightChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
    }
}

struct HomeActionsGrid: View {
    let actions: [HomeAction]
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(actions) { HomeActionButton(action: $0) }
        }
        .card()
    }
}

struct HomeActionButton: View {
    let action: HomeAction

    var body: some View {
        Button {} label: {
            VStack(spacing: 6) {
                Image(systemName: action.symbol)
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(action.tint.opacity(0.15)))
                Text(action.title).font(.caption2).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }
}

struct AccountWidget: View {
    let account: Account
    let home: HomeData

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AccountHeader(account: account)
            Divider()
            ForEach(account.transactions.prefix(5)) { transaction in
                TransactionRow(transaction: transaction, account: account)
            }
            AccountFooter(account: account, home: home)
        }
        .card()
    }
}

struct AccountHeader: View {
    let account: Account

    var body: some View {
        HStack(spacing: 12) {
            AccountIcon(symbol: account.symbol, tint: account.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.title).font(.headline).lineLimit(1)
                Text(account.iban).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            AmountLabel(amount: account.balance, currency: account.currency, style: .large)
        }
    }
}

struct AccountIcon: View {
    let symbol: String
    let tint: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(tint.gradient)
            .frame(width: 40, height: 40)
            .overlay(Image(systemName: symbol).foregroundStyle(.white))
    }
}

struct TransactionRow: View {
    let transaction: Payment
    let account: Account

    var body: some View {
        HStack(spacing: 10) {
            MerchantLogo(merchant: transaction.merchant)
            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.title).font(.subheadline.weight(.medium)).lineLimit(1)
                HStack(spacing: 4) {
                    CategoryChip(category: transaction.category)
                    Text(transaction.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            AmountLabel(amount: transaction.amount, currency: account.currency, style: .regular)
        }
        .contentShape(Rectangle())
    }
}

struct MerchantLogo: View {
    let merchant: Merchant

    var body: some View {
        ZStack {
            Circle().fill(merchant.tint.opacity(0.2))
            Text(merchant.initials).font(.caption.bold()).foregroundStyle(merchant.tint)
        }
        .frame(width: 32, height: 32)
    }
}

struct CategoryChip: View {
    let category: Payment.Category

    var body: some View {
        Text(category.title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color(.tertiarySystemFill)))
    }
}

struct AmountLabel: View {
    enum Style { case regular, large }
    let amount: Decimal
    let currency: String
    let style: Style

    var body: some View {
        Text("\(amount.formatted(.number.precision(.fractionLength(2)))) \(currency)")
            .font(style == .large ? .headline.monospacedDigit() : .subheadline.monospacedDigit())
            .foregroundStyle(amount < 0 ? Color.primary : Color.green)
    }
}

struct AccountFooter: View {
    let account: Account
    let home: HomeData

    var body: some View {
        HStack {
            Label("\(account.transactions.count) operations", systemImage: "list.bullet").font(.caption)
            Spacer()
            Button("Details") {}.font(.caption.weight(.semibold))
        }
        .foregroundStyle(.secondary)
    }
}

struct OffersCarousel: View {
    let offers: [Offer]
    let home: HomeData

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("For you").font(.title3.bold())
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(offers) { OfferCard(offer: $0, home: home) }
                }
            }
        }
    }
}

struct OfferCard: View {
    let offer: Offer
    let home: HomeData

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: offer.symbol).font(.title2).foregroundStyle(offer.tint)
            Text(offer.title).font(.headline).lineLimit(2)
            Text(offer.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(width: 180, height: 140, alignment: .topLeading)
        .padding(12)
        .glassCard(cornerRadius: 20)
    }
}

struct TabBarMock: View {
    let home: HomeData

    var body: some View {
        HStack {
            ForEach(home.tabs, id: \.self) { tab in
                VStack(spacing: 2) {
                    Image(systemName: tab).font(.title3)
                    Circle().fill(tab == home.tabs.first ? Color.accentColor : .clear).frame(width: 4, height: 4)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 10)
        .glassCard(cornerRadius: 30)
        .padding(.horizontal, 24)
    }
}

// MARK: - Data

struct HomeData {
    var stories: [Story]
    var totalBalance: String
    var currency: String
    var highlights: [String]
    var actions: [HomeAction]
    var accounts: [Account]
    var offers: [Offer]
    var tabs: [String]
}

struct Story: Identifiable { var id: Int; var title: String; var symbol: String; var tint: Color; var isSeen: Bool }
struct HomeAction: Identifiable { var id: Int; var title: String; var symbol: String; var tint: Color }
struct Offer: Identifiable { var id: Int; var title: String; var subtitle: String; var symbol: String; var tint: Color }

struct Account: Identifiable {
    struct Limits { var daily: Decimal; var monthly: Decimal; var atm: Decimal; var online: Bool; var abroad: Bool }
    var id: Int
    var title: String
    var iban: String
    var balance: Decimal
    var currency: String
    var symbol: String
    var tint: Color
    var limits: Limits
    var flags: [String]
    var transactions: [Payment]
}

struct Merchant {
    struct Address { var street: String; var city: String; var postcode: String; var country: String }
    var name: String
    var initials: String
    var mcc: Int
    var tint: Color
    var address: Address
    var website: URL?
}

struct Payment: Identifiable {
    enum Category {
        case groceries, transport, dining(tip: Decimal), transfer(to: String), salary
        var title: String {
            switch self {
            case .groceries: "Groceries"
            case .transport: "Transport"
            case .dining: "Dining"
            case .transfer: "Transfer"
            case .salary: "Salary"
            }
        }
    }
    var id: Int
    var title: String
    var subtitle: String
    var date: Date
    var amount: Decimal
    var category: Category
    var merchant: Merchant
    var tags: [String]
}

extension DemoAPI {
    func home() async -> HomeData {
        try? await Task.sleep(for: delay)
        return HomeData.sample
    }
}

extension HomeData {
    static let sample: HomeData = {
        let tints: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .indigo, .red]
        let symbols = ["creditcard", "banknote", "eurosign", "chart.line.uptrend.xyaxis", "bag", "cart", "car", "airplane"]
        let categories: [Payment.Category] = [.groceries, .transport, .dining(tip: 2.5), .transfer(to: "Anna Petrova"), .salary]
        let merchants = ["Supermarket", "Metro", "Café Central", "Anna Petrova", "Employer GmbH", "Bookshop", "Pharmacy", "Cinema"]
        func merchant(_ i: Int) -> Merchant {
            let name = merchants[i % merchants.count]
            return Merchant(name: name, initials: String(name.prefix(2)).uppercased(), mcc: 5000 + i * 7, tint: tints[i % tints.count],
                            address: .init(street: "Main street \(i + 1)", city: "Berlin", postcode: "10\(100 + i)", country: "DE"),
                            website: URL(string: "https://example.com/\(i)"))
        }
        let accounts = (0..<6).map { a in
            Account(
                id: a, title: ["Main account", "Savings", "Travel card", "Joint account", "Business", "Kids"][a],
                iban: "DE89 3704 0044 0532 0130 0\(a)", balance: Decimal(1250 + a * 731) + Decimal(string: "0.45")!,
                currency: "EUR", symbol: symbols[a], tint: tints[a],
                limits: .init(daily: 1000, monthly: 20000, atm: 500, online: true, abroad: a % 2 == 0),
                flags: ["primary", "contactless", "virtual"].prefix(a % 3 + 1).map { $0 },
                transactions: (0..<40).map { t in
                    Payment(id: a * 100 + t, title: merchants[(a + t) % merchants.count], subtitle: "Card ··\(1000 + a * 11)",
                                date: Date(timeIntervalSince1970: 1_790_000_000 - Double(t) * 3600 * 7),
                                amount: Decimal(t % 5 == 4 ? 2400 : -(t * 3 + 7)) / 2, category: categories[t % categories.count],
                                merchant: merchant(a + t), tags: ["card", t % 2 == 0 ? "online" : "pos"])
                }
            )
        }
        return HomeData(
            stories: (0..<12).map { Story(id: $0, title: "Story \($0 + 1)", symbol: symbols[$0 % symbols.count], tint: tints[$0 % tints.count], isSeen: $0 > 3) },
            totalBalance: "12,480.70", currency: "EUR", highlights: ["+3.2% this month", "2 bills due"],
            actions: ["Pay", "Transfer", "Top up", "Exchange", "Cards", "Savings", "Invest", "More"].enumerated().map {
                HomeAction(id: $0.offset, title: $0.element, symbol: symbols[$0.offset], tint: tints[$0.offset])
            },
            accounts: accounts,
            offers: (0..<6).map { Offer(id: $0, title: "Offer number \($0 + 1) with cashback", subtitle: "Up to \($0 + 2)% back on purchases", symbol: symbols[$0], tint: tints[$0]) },
            tabs: ["house.fill", "creditcard", "arrow.left.arrow.right", "chart.pie", "ellipsis"]
        )
    }()
}
