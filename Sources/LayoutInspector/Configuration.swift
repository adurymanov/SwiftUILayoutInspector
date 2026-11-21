import CoreGraphics
import Foundation

extension LayoutInspector {
    /// What the inspector shows and how it behaves.
    ///
    /// A plain value type: keep it in your own state, persist it (it is `Codable`), edit it with
    /// ``LayoutInspectorSettings`` and pass it to `.layoutInspector(_:)`.
    /// When the modifier gets a binding, changes made from the inspector's toolbar are written back.
    nonisolated public struct Configuration: Hashable, Codable, Sendable {
        /// `false` removes the inspector completely: no overlay, no toolbar, no captures.
        public var isEnabled: Bool
        /// The overlay that is drawn on top of the view.
        public var mode: Mode
        /// Text tags next to the outlines (names, sizes, values).
        public var showsLabels: Bool
        /// A square grid over the inspected area.
        public var showsGrid: Bool
        /// Grid step in points.
        public var gridSize: CGFloat
        /// How the inspector's own controls are presented.
        public var toolbar: Toolbar
        /// Taps on the inspected area select elements (outlined in the overlay) instead of reaching the view.
        /// Always on in ``Mode/measure``.
        public var selectsOnTap: Bool
        /// Re-capture when the content changes (data loading, navigation inside the view, animations).
        /// Scrolling is followed either way.
        public var autoRefresh: Bool
        /// Capture and highlight a screen as soon as it appears. Off: a screen stays untouched until a mode is picked
        /// in the inspector's menu, so nothing is computed while navigating.
        public var highlightsOnAppear: Bool
        /// Design rules checked in ``Mode/lint``.
        public var lintRules: LintRules

        public init(
            isEnabled: Bool = true,
            mode: Mode = .components,
            showsLabels: Bool = true,
            showsGrid: Bool = false,
            gridSize: CGFloat = 8,
            toolbar: Toolbar = .visible,
            selectsOnTap: Bool = false,
            autoRefresh: Bool = true,
            highlightsOnAppear: Bool = true,
            lintRules: LintRules = LintRules()
        ) {
            self.isEnabled = isEnabled
            self.mode = mode
            self.showsLabels = showsLabels
            self.showsGrid = showsGrid
            self.gridSize = gridSize
            self.toolbar = toolbar
            self.selectsOnTap = selectsOnTap
            self.autoRefresh = autoRefresh
            self.highlightsOnAppear = highlightsOnAppear
            self.lintRules = lintRules
        }

        /// Inspector off. Handy as the initial value of a setting.
        public static let disabled = Configuration(isEnabled: false)

        /// Taps select elements in this mode, whatever ``selectsOnTap`` says.
        var effectiveSelectsOnTap: Bool { selectsOnTap || mode == .measure }

        // Missing keys fall back to defaults, so stored configurations survive new options.
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Configuration()
            isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? d.isEnabled
            mode = (try? c.decodeIfPresent(Mode.self, forKey: .mode)) ?? d.mode
            showsLabels = try c.decodeIfPresent(Bool.self, forKey: .showsLabels) ?? d.showsLabels
            showsGrid = try c.decodeIfPresent(Bool.self, forKey: .showsGrid) ?? d.showsGrid
            gridSize = try c.decodeIfPresent(CGFloat.self, forKey: .gridSize) ?? d.gridSize
            toolbar = (try? c.decodeIfPresent(Toolbar.self, forKey: .toolbar)) ?? d.toolbar
            selectsOnTap = try c.decodeIfPresent(Bool.self, forKey: .selectsOnTap) ?? d.selectsOnTap
            autoRefresh = try c.decodeIfPresent(Bool.self, forKey: .autoRefresh) ?? d.autoRefresh
            highlightsOnAppear = try c.decodeIfPresent(Bool.self, forKey: .highlightsOnAppear) ?? d.highlightsOnAppear
            lintRules = try c.decodeIfPresent(LintRules.self, forKey: .lintRules) ?? d.lintRules
        }
    }

    /// Overlay drawn on top of the inspected view.
    nonisolated public enum Mode: String, CaseIterable, Identifiable, Codable, Sendable {
        /// Custom views with their type name and size, stacks (spacing, alignment), controls, scroll views.
        case components
        /// Measured paddings, gaps between stack children (including the real default spacing), list insets.
        case spacing
        /// Font, size, weight, line height, number of lines, color and baseline of every text; truncation.
        case typography
        /// `.frame`, `fixedSize`, `layoutPriority`, `aspectRatio`, spacers, alignment guides, Auto Layout.
        case constraints
        /// UIKit render tree: views and layers SwiftUI draws into, UIKit fonts and constraints.
        case uikit
        /// Design rule violations (see ``LintRules``).
        case lint
        /// Distance between two tapped elements (or from one element to its container).
        case measure
        /// How many times each component's `body` ran since the mode was turned on (or since Reset), as a heatmap.
        /// Counts come from SwiftUI's AttributeGraph profiler, which runs only while this mode is on.
        case rerenders

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .components: "Components"
            case .spacing: "Spacing"
            case .typography: "Fonts"
            case .constraints: "Constraints"
            case .uikit: "UIKit"
            case .lint: "Lint"
            case .measure: "Measure"
            case .rerenders: "Re-renders"
            }
        }

        /// SF Symbol name.
        public var systemImage: String {
            switch self {
            case .components: "square.on.square.dashed"
            case .spacing: "arrow.left.and.right.square"
            case .typography: "textformat.size"
            case .constraints: "ruler"
            case .uikit: "square.stack.3d.down.right"
            case .lint: "exclamationmark.triangle"
            case .measure: "arrow.up.and.down.and.arrow.left.and.right"
            case .rerenders: "flame"
            }
        }

        /// One line for settings screens.
        public var summary: String {
            switch self {
            case .components: "Views, stacks, controls and their sizes"
            case .spacing: "Paddings and gaps between elements"
            case .typography: "Fonts, line height, color, truncation"
            case .constraints: "Frames, fixed size, priorities, Auto Layout"
            case .uikit: "Views and layers SwiftUI renders into"
            case .lint: "Design rule violations"
            case .measure: "Distance between two tapped elements"
            case .rerenders: "How often each view's body runs, as a heatmap"
            }
        }

        /// Development tools, listed in the menu's Dev section rather than with the layout modes.
        public var isDevelopmentTool: Bool {
            switch self {
            case .uikit, .rerenders: true
            default: false
            }
        }
    }

    /// How the inspector's controls are presented.
    nonisolated public enum Toolbar: String, CaseIterable, Identifiable, Codable, Sendable {
        /// A round glass button with the mode's icon. Drag it anywhere, tap it for every option.
        case visible
        /// No controls: the overlay is driven by the configuration only (screenshots, demos).
        case hidden

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .visible: "Visible"
            case .hidden: "Hidden"
            }
        }
    }

    /// Design rules checked in ``Mode/lint``.
    nonisolated public struct LintRules: Hashable, Codable, Sendable {
        /// Paddings and stack spacings must be multiples of this value (2 = "no odd or fractional values").
        /// `0` turns the check off.
        public var grid: CGFloat
        /// Allowed sizes of fixed (non Dynamic Type) fonts. Empty = any size.
        public var typeScale: Set<CGFloat>
        /// Warn about fixed-size fonts that ignore Dynamic Type.
        public var warnOnFixedSizeFonts: Bool
        /// Minimum size of buttons and navigation links.
        public var minTapTarget: CGFloat
        /// Children of a leading/trailing aligned stack that are off by at most this many points are reported
        /// as "almost aligned".
        public var alignmentTolerance: CGFloat

        public init(
            grid: CGFloat = 2,
            typeScale: Set<CGFloat> = [11, 12, 13, 15, 17, 20, 22, 28, 34],
            warnOnFixedSizeFonts: Bool = true,
            minTapTarget: CGFloat = 44,
            alignmentTolerance: CGFloat = 2
        ) {
            self.grid = grid
            self.typeScale = typeScale
            self.warnOnFixedSizeFonts = warnOnFixedSizeFonts
            self.minTapTarget = minTapTarget
            self.alignmentTolerance = alignmentTolerance
        }
    }
}
