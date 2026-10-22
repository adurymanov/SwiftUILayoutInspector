import SwiftUI

enum DemoScreen: String, CaseIterable, Identifiable, Hashable {
    case profile, feed, checkout, dashboard, promo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .profile: "Profile"
        case .feed: "Product feed"
        case .checkout: "Checkout (Form)"
        case .dashboard: "Dashboard (Grid)"
        case .promo: "UIKit interop"
        }
    }

    var subtitle: String {
        switch self {
        case .profile: "Custom components, custom Layout, truncated text"
        case .feed: "ScrollView + LazyVStack, skeletons → data"
        case .checkout: "Form, TextField/Toggle (UIKit-backed), safeAreaInset"
        case .dashboard: "LazyVGrid, fixed frames, layoutPriority, lint issues"
        case .promo: "UIViewRepresentable with Auto Layout & UIStackView"
        }
    }

    var symbol: String {
        switch self {
        case .profile: "person.crop.circle"
        case .feed: "square.grid.2x2"
        case .checkout: "cart"
        case .dashboard: "chart.bar.xaxis"
        case .promo: "uiwindow.split.2x1"
        }
    }

    @ViewBuilder var view: some View {
        switch self {
        case .profile: ProfileScreen()
        case .feed: FeedScreen()
        case .checkout: CheckoutScreen()
        case .dashboard: DashboardScreen()
        case .promo: PromoScreen()
        }
    }
}
