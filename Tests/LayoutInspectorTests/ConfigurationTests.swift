import Foundation
import Testing
import LayoutInspector

struct ConfigurationTests {
    @Test func defaults() {
        let configuration = LayoutInspector.Configuration()
        #expect(configuration.isEnabled)
        #expect(configuration.mode == .components)
        #expect(configuration.showsLabels)
        #expect(!configuration.showsGrid)
        #expect(configuration.toolbar == .expanded)
        #expect(configuration.autoRefresh)
        #expect(!LayoutInspector.Configuration.disabled.isEnabled)
    }

    @Test func codingRoundTrip() throws {
        var configuration = LayoutInspector.Configuration(mode: .typography, showsGrid: true, gridSize: 4, toolbar: .collapsed)
        configuration.lintRules.typeScale = [12, 14, 16]
        configuration.lintRules.minTapTarget = 48
        let data = try JSONEncoder().encode(configuration)
        #expect(try JSONDecoder().decode(LayoutInspector.Configuration.self, from: data) == configuration)
    }

    /// Stored settings keep working when options are added or values become unknown.
    @Test func decodingFallsBackToDefaults() throws {
        let json = #"{"mode": "spacing", "toolbar": "floating", "showsGrid": true}"#
        let configuration = try JSONDecoder().decode(LayoutInspector.Configuration.self, from: Data(json.utf8))
        #expect(configuration.mode == .spacing)
        #expect(configuration.showsGrid)
        #expect(configuration.toolbar == .expanded)
        #expect(configuration.isEnabled)
        #expect(configuration.lintRules == LayoutInspector.LintRules())
    }

    @Test func modesHaveDistinctPresentation() {
        let modes = LayoutInspector.Mode.allCases
        #expect(Set(modes.map(\.title)).count == modes.count)
        #expect(Set(modes.map(\.systemImage)).count == modes.count)
        #expect(modes.allSatisfy { !$0.summary.isEmpty })
    }

    #if !os(iOS)
    @MainActor
    @Test func inertOutsideIOS() {
        #expect(!LayoutInspector.isAvailable)
        LayoutInspector.bootstrap()
        #expect(!LayoutInspector.isSwiftUIGraphRecordingEnabled)
        LayoutInspector.show()
        #expect(!LayoutInspector.isVisible)
    }
    #endif
}
