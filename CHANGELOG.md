# Changelog

## 0.2.9

- Placing component names is fast again. 0.2.4 added a check of whether one view is built from another, and it
  searched kilobytes of type names for every pair of views that claim the same node. Every hosting view also
  looked up all of a screen's chain types by their full names. On the demo's heavy screen the step takes 9–11 ms
  instead of 63–65 ms (0.2.3: 6–7 ms). Names and placement are unchanged.
- Timings (`LAYOUT_INSPECTOR_LOG=1`, `lastCaptureTimings`) break placement into `apply.*` phases, the way they
  already break down the component index (`index.*`).
- The demo's timing test also limits placement (`TEST_RUNNER_APPLY_LIMIT_MS`, 40 ms by default).
- Comments, tests and the demo no longer use type names from the banking app they were modelled on.

## 0.2.8

- Dev → Components list: a sheet with the app's views on the screen, nested as on screen, with frames and
  re-render counts, and a search field. A tap outlines the view and lowers the sheet; Share sends the list as text.
- Details of a view: its properties as its parent built it (read from SwiftUI's graph), `@State`, `@Binding`,
  `@Environment` and observed objects, the fonts inside, and the window's environment that layout depends on.
- `capture.json` gets a top-level `environment`, and `properties` for components with
  `LAYOUT_INSPECTOR_PROPERTIES=1`.
- Fixed: on iOS 26 the Re-renders count of one row of a `ForEach` could land on another row. Views of one type are
  now paired by position instead of by the order AttributeGraph lists them.

## 0.2.7

- The menu has a Dev submenu for tools that help build views rather than check their layout. UIKit moved
  there; the layout modes stay in the menu itself.
- New mode, Dev → Re-renders (`Mode.rerenders`): a heatmap of how many times each app view's `body` ran since
  the mode was turned on or since Dev → Reset counts. The counts are exact and per view, read from SwiftUI's
  AttributeGraph profiler, which runs only while the mode is on. Share report adds `renders N` to every counted
  view. On iOS 18 the mode shows that counts are not available.
- `Mode.isDevelopmentTool` tells the Dev modes from the layout ones.
- `capture.json` gets `renders` (`count`, `views`) for components while Re-renders is on, and `li` knows the
  mode (`li rerenders`).
- Breaking for exhaustive `switch`es over `LayoutInspector.Mode`: it has a new case. Images rendered with
  `.rerenders` outside the inspector (`InspectorImageRenderer`, `snapshot`) have no counts to show.
- The demo has a Re-renders screen with an `@Observable` model.

## 0.2.6

- Commands from the Mac: an app that calls `bootstrap()` switches modes, refreshes and closes the inspector on
  Darwin notifications (`dev.layoutinspector.mode.spacing`, or scoped to one app with its bundle id). A mode
  command shows a closed inspector again.
- Report files after every capture, once the app got a command (or in previews, or with
  `LAYOUT_INSPECTOR_REPORTS=1`): `report.txt`, `capture.json` (every node with its facts, versioned schema) and
  `status.json`, written atomically off the main thread into a folder the Mac reads directly.
- `LayoutInspector.snapshot(_:)` captures a view without an app and gives the report, the JSON and images.
- `Tools/li`, a CLI for agents and scripts: modes with no taps, `query` and `measure` on the captured numbers, and
  `preview` for a `#Preview` through headless Xcode. `Docs/Agents.md` documents all of it.
- `LayoutInspector.version`.

## 0.1.3

- The compilation condition `LAYOUT_INSPECTOR_DISABLED` compiles the engine out like a disabled
  `LayoutInspectorEngine` trait, but per build configuration: keep the inspector in Debug and drop the private
  API from Release.
- `LayoutInspector.capture(_:)` and `captureWhenStable` bring a window without a scene (snippets, tests) up to
  date before capturing, so content that changed after the first layout is drawn instead of empty boxes.
- The repository is public, under the MIT license.

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
