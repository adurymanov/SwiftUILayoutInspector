import SwiftUI

enum DemoScreen: String, CaseIterable, Identifiable, Hashable {
    case profile, feed, checkout, dashboard, promo, glass, heavy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .profile: "Profile"
        case .feed: "Product feed"
        case .checkout: "Checkout (Form)"
        case .dashboard: "Dashboard (Grid)"
        case .promo: "UIKit interop"
        case .glass: "Liquid Glass"
        case .heavy: "Heavy home"
        }
    }

    var subtitle: String {
        switch self {
        case .profile: "Custom components, custom Layout, truncated text"
        case .feed: "ScrollView + LazyVStack, skeletons → data"
        case .checkout: "Form, TextField/Toggle (UIKit-backed), safeAreaInset"
        case .dashboard: "LazyVGrid, fixed frames, layoutPriority, lint issues"
        case .promo: "UIViewRepresentable with Auto Layout & UIStackView"
        case .glass: "glassEffect, GlassEffectContainer, widget card (iOS 26+)"
        case .heavy: "A big app's home: many views, large models, glass – for timing"
        }
    }

    var symbol: String {
        switch self {
        case .profile: "person.crop.circle"
        case .feed: "square.grid.2x2"
        case .checkout: "cart"
        case .dashboard: "chart.bar.xaxis"
        case .promo: "uiwindow.split.2x1"
        case .glass: "drop.halffull"
        case .heavy: "gauge.with.dots.needle.67percent"
        }
    }

    @ViewBuilder var view: some View {
        switch self {
        case .profile: ProfileScreen()
        case .feed: FeedScreen()
        case .checkout: CheckoutScreen()
        case .dashboard: DashboardScreen()
        case .promo: PromoScreen()
        case .glass:
            if #available(iOS 26.0, *) {
                GlassScreen()
            } else {
                ContentUnavailableView("Needs iOS 26", systemImage: "drop.halffull")
            }
        case .heavy: HeavyScreen()
        }
    }
}
