import SwiftUI

struct FeedScreen: View {
    @State private var products: [Product]?
    @State private var filter = "All"

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                FilterChips(selection: $filter, options: ["All", "Audio", "Wearables", "Desk", "Sale"])
                if let products {
                    ForEach(products) { ProductCard(product: $0) }
                } else {
                    ForEach(0..<3, id: \.self) { _ in ProductCardSkeleton() }
                }
            }
            .padding(16)
        }
        .navigationTitle("Feed")
        .task { products = await DemoAPI.shared.products() }
    }
}

struct FilterChips: View {
    @Binding var selection: String
    let options: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(options, id: \.self) { option in
                    Text(option)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(option == selection ? Color.accentColor : Color(.tertiarySystemFill)))
                        .foregroundStyle(option == selection ? .white : .primary)
                        .onTapGesture { selection = option }
                }
            }
        }
    }
}

struct ProductCard: View {
    let product: Product

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ProductThumbnail(symbol: product.symbol, tint: product.tint)
            VStack(alignment: .leading, spacing: 6) {
                Text(product.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(product.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                HStack {
                    PriceTag(price: product.price, oldPrice: product.oldPrice)
                    Spacer()
                    RatingView(rating: product.rating)
                }
            }
        }
        .padding(12)
        .frame(height: 112)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
    }
}

struct ProductThumbnail: View {
    let symbol: String
    let tint: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(tint.gradient)
            .frame(width: 88, height: 88)
            .overlay(Image(systemName: symbol).font(.system(size: 32)).foregroundStyle(.white))
    }
}

struct PriceTag: View {
    let price: String
    let oldPrice: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(price).font(.title3.bold())
            if let oldPrice {
                Text(oldPrice).font(.caption).strikethrough().foregroundStyle(.secondary)
            }
        }
    }
}

struct RatingView: View {
    let rating: Double

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
            Text(rating, format: .number.precision(.fractionLength(1))).font(.caption.weight(.semibold))
        }
    }
}

struct ProductCardSkeleton: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(Color(.secondarySystemBackground))
            .frame(height: 112)
            .overlay(ProgressView())
    }
}
