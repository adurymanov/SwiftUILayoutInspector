# Changelog

## 0.2.13

- Re-renders on a big app's trading home. Content a container gets from its caller (the cards of a grid, declared
  by the section around it) sits in AttributeGraph under the caller, beside the container: it is now looked for
  there right after the container itself. Views drawn twice at one place (a press effect drawing its content again on
  top) count as one view. Away from the nearest component, a component is still tied to a view by its recorded box
  when no other waiting component could take that view; a component whose box has no size is placed by its origin.
  Recorded home of 528 components: 172 of 272 components with a count shared one; now 25 of 461 (the tests replay
  the recording and require under 20 %).
- `LAYOUT_INSPECTOR_MATCH_DUMP=<dir>` records what matching read for each capture (`match-NNN.json`), and
  `Tools/anonymize-match.py` replaces its names and texts with tokens, so a screen of any app can be replayed offline
  (`ComponentMatcher`, `MatchReplayTests`).
- Mapping components to the graph no longer holds the main thread: the views of each host are read in a frame of
  their own, then the matching; `body` nodes are classified by the type of their rule (`AGGraphGetAttributeInfo`)
  as they are read, not from a description of the whole graph; and reading AttributeGraph trees skips the lookup of
  child subgraphs on elements none hang from (also in captures). On the big app's home the mapping took 375 ms in
  one step; read a host a frame, its biggest host took 297 ms, 82 % of it in that lookup. A mapping is dropped
  when the content scrolls or hosts change under it. `capture.json` → `capture.rendersMap` has the timings; in
  Re-renders a capture's report waits for its counts.
- Components list with the default filters: a modifier folded into a row shows its count on that row, shared or
  not, and the shared counts above the list are only those of the rows shown. The capture knows the app's
  `ViewModifier` types from its own trees, and a view named `…Modifier` folds as one too. Visible also drops what is
  outside its host's on-screen part (clipping containers) and the second copy of bar items a tab bar draws twice.
  `capture.json` → `components` has the rows as the list shows them.
- Demo: Markets cards come in three sections whose grids get them from the caller, and the press effect draws the
  card twice.

## 0.2.12

- Re-renders finds each view from the outside in: inside the view of the nearest component around it that was
  already told apart, then further out (AttributeGraph doesn't nest every view the way the capture does), in the
  component's own host first. Away from the nearest component a view is told apart only while no other component
  of its type waits in the same scope. The insides of cards that are geometry groups (SwiftUI records
  the same box in every card), views whose `body` draws nothing, generic wrappers around a `TimelineView` and tab
  items in hosting controllers of their own now get counts of their own. A view whose produced boxes don't cover
  the component's box is never paired with it, so a component the capture named after a view elsewhere gets no
  count instead of a wrong one. Demo trading home: 71 of 118 components shared a count; now 1 of 118 (the tests
  require under 5 %).
- Reading the counts no longer describes the whole graph every second: the `body` nodes are classified once per
  capture and then read through a description of only those nodes. Demo Heavy screen: 30 ms a read, now about 1 ms.
- `ViewModifier` bodies are counted: an `Animatable` modifier with a repeating animation (a shimmer) shows its
  count on the view it is applied to and on that view's row in the components list.
- The panel, the components list and `capture.json` show one tally of shared counts: "N of M views share a
  count" and each group once, `Σ` with the components on screen and the views in the graph. `capture.json`
  `renders` has `groups`.
- Components list: siblings of one type fold into one row by their parent, not only when they are next to each
  other in reading order, so rows and cards with components inside fold too, and hide their insides while folded.
- Demo: a trading home ("Markets") with streaming price wrappers, geometry-group cards, empty overlays, hosted tab
  items and a shimmer.

## 0.2.11

- Re-renders ties each view to the box SwiftUI recorded for the first view its `body` produced: the element of a
  produced view resolves, through AttributeGraph's indirect attributes, to the `body` node that built it. Views
  built from the same texts, formatted or attributed texts, and views without any text (images, icons, overlays)
  now get counts of their own; texts are only a fallback.
- `capture.json` has a top-level `renders` summary while Re-renders is on: `views`, `own`, `shared`.
- The panel (Re-renders, Lint, Measure) and the button's default spot stay above the app's bar at the bottom (a
  `UITabBar`, a `UIToolbar`, or a row of SwiftUI buttons there), so their taps reach the bar.
- Components list: presenters and controller hosts the size of their parent with nothing of their own to show
  fold into the row as wrappers. Three or more siblings of one type next to each other become one row
  ("Row ×14") that opens with a tap.
- Demo: the deep chain screen has presenters and a bottom bar; the labels screen uses attributed and formatted
  texts behind a condition, like a design system's text.

## 0.2.10

- Components list v2, made for a phone: one compact row per view (name, then frame and the view it is in), no
  indentation. Same-size chains of wrappers fold into one row with a `+N wrappers` chip; the details list the
  chain, the parents and the children.
- Filters under the search field, kept between launches: Visible, Hide wrappers, App types (on by default),
  Re-rendered, Has state, Module; sorting by reading order, re-renders or area. The search matches the module too.
- Pick on screen: the target button lowers the sheet, and a tap keeps the views under that point, smallest first.
- Re-renders tells apart the views of one type by the texts they were built with, so a text component used all
  over a lazy list (rows off screen included) gets a count per label. Views it still can't tell apart get a faint outline, and their
  total shows once, in the panel and in the components list, instead of `Σ` on every one of them.
- Re-renders marks only the views whose body ran; Dev → Show zeros marks the others too.
- The info card of Re-renders, Lint and Measure is a glass panel that folds into a pill with a tap and stays
  folded. With the controls hidden it is drawn into the overlay as before.
- `LayoutInspector.version` says 0.2.10 (0.2.9 still said 0.2.8); a demo test keeps it equal to the top of this
  file and to `li`.
- An app launched with `LAYOUT_INSPECTOR_DUMP` leaves `redirect.json` in its usual report folder, and `li` follows
  it without `--reports-dir`.
- Demo: a screen under a 20-deep chain of wrappers with long names, zero-size views and many rows, and a screen
  with one text component 200 times in a lazy list.

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
