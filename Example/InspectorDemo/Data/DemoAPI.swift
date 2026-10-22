import Foundation
import SwiftUI

/// Fake backend: every screen loads its data asynchronously, like real screens do.
final class DemoAPI {
    static let shared = DemoAPI()

    var delay: Duration = .milliseconds(Int(ProcessInfo.processInfo.environment["DEMO_API_DELAY_MS"] ?? "") ?? 700)

    private func wait() async { try? await Task.sleep(for: delay) }

    func profile() async -> Profile {
        await wait()
        return Profile(
            name: "Anna Petrova",
            handle: "@anna.designs",
            city: "Berlin",
            initials: "AP",
            stats: [.init(title: "Posts", value: "128"), .init(title: "Followers", value: "12.4K"), .init(title: "Following", value: "312")],
            bio: "Product designer working on design systems and accessible interfaces. Previously at a fintech startup, now building tools that help teams ship consistent UI faster. Loves typography, grids and long bike rides.",
            tags: ["Design systems", "SwiftUI", "Accessibility", "Figma", "Typography", "Motion"]
        )
    }

    func products() async -> [Product] {
        await wait()
        return [
            Product(title: "Wireless Headphones Pro", subtitle: "Active noise cancelling, 40h battery", price: "€249", oldPrice: "€299", rating: 4.8, symbol: "headphones", tint: .indigo),
            Product(title: "Smart Watch Series X with an unusually long product name", subtitle: "Titanium · GPS + Cellular", price: "€449", oldPrice: nil, rating: 4.6, symbol: "applewatch", tint: .orange),
            Product(title: "Mechanical Keyboard", subtitle: "Hot-swappable switches", price: "€129", oldPrice: "€159", rating: 4.9, symbol: "keyboard", tint: .teal),
            Product(title: "4K Monitor 27\"", subtitle: "USB-C 96W", price: "€399", oldPrice: nil, rating: 4.4, symbol: "display", tint: .pink),
            Product(title: "Bluetooth Speaker", subtitle: "Waterproof IP67", price: "€89", oldPrice: "€109", rating: 4.5, symbol: "hifispeaker", tint: .green),
        ]
    }

    func cart() async -> Cart {
        await wait()
        return Cart(items: [.init(name: "Wireless Headphones Pro", price: "€249"), .init(name: "Mechanical Keyboard", price: "€129")],
                    delivery: "€4.99", total: "€382.99")
    }

    func metrics() async -> [Metric] {
        await wait()
        return [
            Metric(title: "Revenue", value: "€48.2K", delta: "+12.4%", symbol: "eurosign.circle.fill", tint: .green, points: [3, 4, 3.5, 5, 6, 5.5, 7]),
            Metric(title: "Orders", value: "1,284", delta: "+3.1%", symbol: "shippingbox.fill", tint: .blue, points: [5, 4, 6, 5, 6, 7, 6.5]),
            Metric(title: "Refunds", value: "23", delta: "−8.0%", symbol: "arrow.uturn.backward.circle.fill", tint: .orange, points: [6, 5, 5.5, 4, 3.5, 3, 2.5]),
            Metric(title: "Conversion", value: "3.42%", delta: "+0.4%", symbol: "chart.line.uptrend.xyaxis.circle.fill", tint: .purple, points: [2, 3, 2.5, 3.5, 4, 3.8, 4.2]),
        ]
    }
}

struct Profile {
    struct Stat: Hashable { var title: String; var value: String }
    var name, handle, city, initials: String
    var stats: [Stat]
    var bio: String
    var tags: [String]
}

struct Product: Identifiable {
    var id: String { title }
    var title, subtitle, price: String
    var oldPrice: String?
    var rating: Double
    var symbol: String
    var tint: Color
}

struct Cart {
    struct Item: Hashable { var name: String; var price: String }
    var items: [Item]
    var delivery: String
    var total: String
}

struct Metric: Identifiable {
    var id: String { title }
    var title, value, delta, symbol: String
    var tint: Color
    var points: [Double]
}

enum LoadState<Value> {
    case loading
    case loaded(Value)
}
