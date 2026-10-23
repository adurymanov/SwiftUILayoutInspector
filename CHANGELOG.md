# Changelog

## 0.1.2

- Xcode previews and `RunCodeSnippet` record the SwiftUI graph without `bootstrap()`: in processes with
  `XCODE_RUNNING_FOR_PREVIEWS=1` the library sets `SWIFTUI_VIEW_DEBUG` when it is loaded. Before, previews of
  screens in packages and frameworks (hosted by Xcode's own app, no `App.init`) only saw the render tree.
- `InspectorImageRenderer` draws the content of a window without a scene (snippets) instead of an empty
  background.

## 0.1.1

- `LayoutInspector.bootstrap()` detects a call made after SwiftUI created its first view. SwiftUI reads
  `SWIFTUI_VIEW_DEBUG` once per process, so such a call cannot turn recording on: it now logs a warning,
  leaves the variable unset and `isSwiftUIGraphRecordingEnabled` reports `false` (it used to report `true`).
  The overlay banner and `LayoutInspectorSettings` say why the SwiftUI graph is missing.

## 0.1.0

First release.

- `.layoutInspector(_:)` modifiers: mode + `isEnabled`, a configuration value, or a binding that the
  inspector's toolbar writes back to.
- `LayoutInspector.Configuration` (`Codable`): mode, labels, grid, toolbar style, tap selection, auto refresh,
  lint rules. `LayoutInspectorSettings` rows to edit it.
- Seven overlay modes: components, spacing, typography, constraints, UIKit, lint, measure. Element details,
  view tree, text layout report.
- Works in pushed screens, sheets and full-screen covers; follows scrolling, data loading and transitions;
  one inspector on screen at a time.
- `LayoutInspector.show()` / `hide()` for the whole key window.
- Turning it off: per view, `LayoutInspector.bootstrap(isEnabled:)` / `LayoutInspector.isEnabled` for the app,
  the `LayoutInspectorEngine` package trait for the build.
- Test API: `LayoutInspector.capture(_:)`, `captureWhenStable(_:)`, queries on `InspectorCapture` /
  `InspectorNode`, `lintIssues(rules:)`, `report()`, `InspectorImageRenderer`.
