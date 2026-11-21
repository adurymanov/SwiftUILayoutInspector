import Observation
import SwiftUI

/// A design-system text used everywhere, as apps have: many of them on one screen, in a lazy list whose rows off
/// screen still exist, inside other components and in a hidden copy. Re-renders tells each one apart.
struct BrandLabel: View {
    enum Style { case title, body, amount }
    /// Like a design system's text: plain, attributed or a localization key, picked in the body.
    enum Content { case plain(String), attributed(AttributedString), key(LocalizedStringKey) }
    let content: Content
    var style: Style = .body
    @Environment(\.redactionReasons) private var redaction

    init(text: String, style: Style = .body) {
        content = .plain(text)
        self.style = style
    }

    init(_ content: Content, style: Style = .body) {
        self.content = content
        self.style = style
    }

    var body: some View {
        HStack(spacing: 0) {
            if redaction.contains(.privacy) {
                text.privacySensitive()
            } else {
                text.allowsHitTesting(false)
            }
        }
    }

    private var text: some View {
        Group {
            switch content {
            case let .plain(string): Text(string)
            case let .attributed(string): Text(string)
            case let .key(key): Text(key)
            }
        }
        .font(style == .title ? .headline : style == .amount ? .subheadline.monospacedDigit() : .subheadline)
        .foregroundStyle(style == .body ? .secondary : .primary)
    }
}

@Observable final class LedgerLine {
    let title: String
    var amount: Int
    init(title: String, amount: Int) { self.title = title; self.amount = amount }
}

@Observable final class LedgerModel {
    let lines = (0..<80).map { LedgerLine(title: "Payment \($0 + 1)", amount: 10 + $0 * 3) }
}

/// Reads only its own line's amount.
struct LedgerAmount: View {
    let line: LedgerLine
    var body: some View { BrandLabel(.attributed(AttributedString(line.amount.formatted(.currency(code: "USD")))), style: .amount) }
}

struct LedgerRow: View {
    let line: LedgerLine

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                BrandLabel(text: line.title, style: .title)
                BrandLabel(.attributed(AttributedString("Card payment")))
            }
            Spacer()
            LedgerAmount(line: line)
        }
        .padding(.vertical, 6)
    }
}

struct LabelsScreen: View {
    @State private var model: LedgerModel

    init(model: LedgerModel = LedgerModel()) {
        _model = State(initialValue: model)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                BrandLabel(text: "Ledger", style: .title)
                    .background { BrandLabel(text: "Ledger", style: .title).hidden() }
                Button("Change payment 3") { model.lines[2].amount += 1 }
                    .buttonStyle(.borderedProminent)
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.lines, id: \.title) { LedgerRow(line: $0) }
                }
            }
            .padding(.horizontal, 16)
        }
        .navigationTitle("Labels")
    }
}
