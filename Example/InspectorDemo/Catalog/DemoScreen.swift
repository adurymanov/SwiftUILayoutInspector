import SwiftUI

enum DemoScreen: String, CaseIterable, Identifiable, Hashable {
    case profile, feed, checkout, dashboard, promo, glass, spaces, heavy, rerenders, deep, labels, markets

    var id: String { rawValue }

    var title: String {
        switch self {
        case .profile: "Profile"
        case .feed: "Product feed"
        case .checkout: "Checkout (Form)"
        case .dashboard: "Dashboard (Grid)"
        case .promo: "UIKit interop"
        case .glass: "Liquid Glass"
        case .spaces: "Coordinate spaces"
        case .heavy: "Heavy home"
        case .rerenders: "Re-renders"
        case .deep: "Deep chain"
        case .labels: "Many labels"
        case .markets: "Markets"
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
        case .spaces: "geometryGroup, drawingGroup, transform and visual effects"
        case .heavy: "A big app's home: many views, large models, glass – for timing"
        case .rerenders: "@Observable model: only the readers of a changed property update"
        case .deep: "20+ same-size wrappers with long names, zero-size views, many rows"
        case .labels: "One text component 200+ times: lazy rows off screen, nested, a hidden copy"
        case .markets: "Generic streaming wrappers, TimelineView, empty overlays, hosted tab items"
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
        case .spaces: "square.3.layers.3d"
        case .heavy: "gauge.with.dots.needle.67percent"
        case .rerenders: "flame"
        case .deep: "list.bullet.indent"
        case .labels: "textformat"
        case .markets: "chart.line.uptrend.xyaxis"
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
        case .spaces: SpacesScreen()
        case .heavy: HeavyScreen()
        case .rerenders: RerenderScreen()
        case .deep: DeepChainScreen()
        case .labels: LabelsScreen()
        case .markets: MarketsScreen()
        }
    }
}
