# Changelog

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
