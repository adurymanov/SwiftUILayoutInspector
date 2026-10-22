import SwiftUI
import UIKit

/// SwiftUI screen that embeds legacy UIKit components built with Auto Layout.
struct PromoScreen: View {
    @State private var promo: (title: String, subtitle: String)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Offers").font(.largeTitle.bold())
                if let promo {
                    PromoBanner(title: promo.title, subtitle: promo.subtitle)
                        .frame(height: 96)
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 96)
                }
                Text("UIKit components inside SwiftUI keep their Auto Layout constraints – switch to the Constraints or UIKit mode to see them.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                RatingStrip(value: 4)
                    .frame(height: 28)
            }
            .padding(20)
        }
        .navigationTitle("UIKit interop")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            _ = await DemoAPI.shared.profile()
            promo = ("Premium for 3 months", "Unlimited downloads, no ads and offline mode")
        }
    }
}

struct PromoBanner: UIViewRepresentable {
    let title: String
    let subtitle: String

    func makeUIView(context: Context) -> PromoBannerView { PromoBannerView() }

    func updateUIView(_ view: PromoBannerView, context: Context) {
        view.titleLabel.text = title
        view.subtitleLabel.text = subtitle
    }
}

final class PromoBannerView: UIView {
    let iconView = UIImageView(image: UIImage(systemName: "crown.fill"))
    let titleLabel = UILabel()
    let subtitleLabel = UILabel()
    let actionButton = UIButton(configuration: .filled())

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 16

        iconView.tintColor = .systemYellow
        iconView.contentMode = .scaleAspectFit
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        subtitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 2
        actionButton.configuration?.title = "Get"
        actionButton.configuration?.cornerStyle = .capsule

        iconView.accessibilityIdentifier = "icon"
        titleLabel.accessibilityIdentifier = "title"
        subtitleLabel.accessibilityIdentifier = "subtitle"
        actionButton.accessibilityIdentifier = "button"

        for v in [iconView, titleLabel, subtitleLabel, actionButton] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        actionButton.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 40),
            iconView.heightAnchor.constraint(equalToConstant: 40),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: actionButton.leadingAnchor, constant: -8),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.trailingAnchor.constraint(equalTo: actionButton.leadingAnchor, constant: -8),

            actionButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            actionButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            actionButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 64),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// UIStackView based component – its spacing is visible in Spacing mode.
struct RatingStrip: UIViewRepresentable {
    let value: Int

    func makeUIView(context: Context) -> UIStackView {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .center
        for i in 0..<5 {
            let star = UIImageView(image: UIImage(systemName: i < value ? "star.fill" : "star"))
            star.tintColor = .systemOrange
            star.translatesAutoresizingMaskIntoConstraints = false
            star.widthAnchor.constraint(equalToConstant: 24).isActive = true
            star.heightAnchor.constraint(equalToConstant: 24).isActive = true
            stack.addArrangedSubview(star)
        }
        let label = UILabel()
        label.text = "4.0 · 1,204 reviews"
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = .secondaryLabel
        stack.addArrangedSubview(label)
        stack.setCustomSpacing(12, after: stack.arrangedSubviews[4])
        return stack
    }

    func updateUIView(_ uiView: UIStackView, context: Context) {}
}
