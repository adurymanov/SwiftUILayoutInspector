import SwiftUI

/// A large app's screen as the components list sees it: the screen sits under a long chain of same-size wrapper views
/// and modifiers with long names, it has zero-size helper views and many rows of one type.
struct DeepChainScreen: View {
    var body: some View {
        ExternalNavigationStackPresenterContainer {
            PushDestinationsRegistrationContainer {
                ScreenErrorStateOverlayContainer {
                    FeatureFlagGatedContentSwitchingContainer {
                        DeepLinkHandlingCoordinatorContainer {
                            SessionTimeoutObservationContainer {
                                KeyboardAvoidanceAdjustingContainer {
                                    ThemeTokenProvidingEnvironmentContainer {
                                        AccountStatementsHistoryScreenContent()
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .modifier(TabBarVisibilityPreferenceModifier())
        .modifier(DismissObservationLifecycleModifier())
        .modifier(InitialScreenDataFetchingModifier())
        .modifier(LegalDisclaimerBannerPresentationModifier())
        .modifier(AnalyticsScreenImpressionTrackingModifier())
        .modifier(ScreenshotProtectionPolicyModifier())
        .modifier(NetworkReachabilityBannerModifier())
        .modifier(AccessibilityAnnouncementQueueModifier())
        .modifier(PullToRefreshCoordinationModifier())
        .modifier(NavigationBarAppearanceConfiguringModifier())
        .modifier(ScrollPositionRestorationModifier())
        .modifier(ToastPresentationHostingModifier())
        .modifier(ModalPresentationModifier())
        .modifier(ModalPresentationModifier())
        .modifier(ModalPresentationModifier())
        .modifier(ModalPresentationModifier())
        .modifier(ModalPresentationModifier())
        .safeAreaInset(edge: .bottom, spacing: 0) { BottomTabBar() }
        .navigationTitle("Deep chain")
    }
}

// MARK: - Wrapper views: same size as what they wrap

struct ExternalNavigationStackPresenterContainer<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { content.contentShape(Rectangle()) }
}

struct PushDestinationsRegistrationContainer<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { content.coordinateSpace(name: "PushDestinations") }
}

struct ScreenErrorStateOverlayContainer<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var error: String?
    var body: some View { content.overlay { if let error { Text(error) } } }
}

struct FeatureFlagGatedContentSwitchingContainer<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { content.compositingGroup() }
}

struct DeepLinkHandlingCoordinatorContainer<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { content.onOpenURL { _ in } }
}

struct SessionTimeoutObservationContainer<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { content.accessibilityElement(children: .contain) }
}

struct KeyboardAvoidanceAdjustingContainer<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { content.zIndex(0) }
}

struct ThemeTokenProvidingEnvironmentContainer<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { content.tint(.indigo) }
}

// MARK: - Modifiers: same size as the content

struct TabBarVisibilityPreferenceModifier: ViewModifier {
    func body(content: Content) -> some View { content.toolbarBackground(.visible, for: .navigationBar) }
}

struct DismissObservationLifecycleModifier: ViewModifier {
    func body(content: Content) -> some View { content.onDisappear {} }
}

struct InitialScreenDataFetchingModifier: ViewModifier {
    @State private var isLoaded = false
    func body(content: Content) -> some View { content.task { isLoaded = true } }
}

struct LegalDisclaimerBannerPresentationModifier: ViewModifier {
    func body(content: Content) -> some View { content.safeAreaInset(edge: .bottom, spacing: 0) { EmptyView() } }
}

struct AnalyticsScreenImpressionTrackingModifier: ViewModifier {
    func body(content: Content) -> some View { content.onAppear {} }
}

struct ScreenshotProtectionPolicyModifier: ViewModifier {
    func body(content: Content) -> some View { content.privacySensitive(false) }
}

struct NetworkReachabilityBannerModifier: ViewModifier {
    func body(content: Content) -> some View { content.transaction { _ in } }
}

struct AccessibilityAnnouncementQueueModifier: ViewModifier {
    func body(content: Content) -> some View { content.accessibilityAction(named: "Announce") {} }
}

struct PullToRefreshCoordinationModifier: ViewModifier {
    func body(content: Content) -> some View { content.refreshable {} }
}

struct NavigationBarAppearanceConfiguringModifier: ViewModifier {
    func body(content: Content) -> some View { content.toolbarColorScheme(nil, for: .navigationBar) }
}

struct ScrollPositionRestorationModifier: ViewModifier {
    func body(content: Content) -> some View { content.id("statements") }
}

struct ToastPresentationHostingModifier: ViewModifier {
    func body(content: Content) -> some View { content.overlay(alignment: .top) { EmptyView() } }
}

// MARK: - Presenters: a controller host the size of the screen, nothing of its own to show

struct ModalPresentationModifier: ViewModifier {
    func body(content: Content) -> some View { content.background { ModalControllerHost() } }
}

struct ModalControllerHost: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController { UIViewController() }
    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}

/// A bar of buttons at the bottom, like an app's own tab bar.
struct BottomTabBar: View {
    var body: some View {
        HStack {
            ForEach(["Home", "Pay", "Invest", "Invite"], id: \.self) { title in
                Button(title) {}
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

// MARK: - Content

struct AccountStatementsHistoryScreenContent: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                StatementPeriodSummaryHeaderWithBalanceBreakdown()
                AnalyticsImpressionTrackingZeroSizeAnchor()
                ForEach(0..<14, id: \.self) { index in
                    TransactionHistoryRowWithMerchantLogoAndAmount(index: index)
                    AnalyticsImpressionTrackingZeroSizeAnchor()
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

struct StatementPeriodSummaryHeaderWithBalanceBreakdown: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("November statement").font(.headline)
            HStack {
                Text("Spent").foregroundStyle(.secondary)
                Spacer()
                Text("$1,284.50").monospacedDigit()
            }
        }
        .padding(.vertical, 12)
    }
}

/// Zero-size helper, like the impression trackers apps put next to rows.
struct AnalyticsImpressionTrackingZeroSizeAnchor: View {
    var body: some View { Color.clear.frame(width: 0, height: 0) }
}

struct TransactionHistoryRowWithMerchantLogoAndAmount: View {
    let index: Int

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(.orange.gradient).frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("Merchant \(index + 1)").font(.subheadline)
                Text("Card payment").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("-$\(12 + index * 7).00").font(.subheadline.monospacedDigit())
        }
        .padding(.vertical, 8)
    }
}
