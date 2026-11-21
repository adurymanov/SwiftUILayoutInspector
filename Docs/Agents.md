# Measuring from scripts and coding agents

The inspector can be driven from the Mac and gives back what it measured as files, so a script or a coding agent
can check paddings, gaps, fonts and frames without tapping the simulator or reading pixels off a screenshot.

- Commands switch the inspector in a running simulator app, one Darwin notification per command.
- Report files describe every capture: `report.txt`, `capture.json`, `status.json`.
- `LayoutInspector.snapshot(_:)` captures a view without an app, for Xcode's `RunCodeSnippet` and previews.
- `Tools/li`, a single-file Python 3 CLI (standard library only), wraps all of it.

All of this is part of the engine, so it exists only in builds that compile the inspector in (see the README).

## Quick start

```bash
# The app runs in the simulator: a Debug build that calls LayoutInspector.bootstrap() at launch.
Tools/li spacing --device <udid>          # switch to Spacing, wait for a fresh capture, collect the files
Tools/li query --text "Anna Petrova"      # frame, font, paddings, gaps and neighbours of one element
Tools/li measure "text:Anna Petrova" "text:@anna.designs"   # distance between two elements
```

`li spacing` prints where it put the files:

```
capture #3  spacing  412 ms  311 nodes  2 lint issues
files ready 0.10 s after the capture ended
out:    /var/folders/…/layout-inspector/8D6B8895/20261121-171502-spacing
        report.txt  capture.json  status.json  screen.png
```

## Commands

Each command is a Darwin notification without a payload. Post it into the simulator with `notifyutil`:

```bash
xcrun simctl spawn <udid> notifyutil -p dev.layoutinspector.mode.spacing
xcrun simctl spawn <udid> notifyutil -p dev.layoutinspector.<bundle id>.mode.spacing   # one app only
```

| Command | What it does |
|---|---|
| `mode.components`, `mode.spacing`, `mode.typography`, `mode.constraints`, `mode.uikit`, `mode.lint`, `mode.measure` | Highlights the screen in the mode and captures it again. Shows the inspector if it was closed: the window inspector, configured as it was last shown with `LayoutInspector.show(_:)`. |
| `off` | Stops highlighting; the button stays. |
| `refresh` | Captures again in the current mode. |
| `close` | Closes the inspector, like its Close button. |
| `status` | Only writes `status.json`. |

The app listens from `LayoutInspector.bootstrap()` on (not with `isEnabled: false`). Commands go to the inspector
in front: the one of the `.layoutInspector` modifier on screen, or the window inspector.

## Report files

From the first command until `close` (always in Xcode previews, with `LAYOUT_INSPECTOR_REPORTS=1` or with
`LAYOUT_INSPECTOR_DUMP`) the inspector writes three files after every capture. An app that only a human looks at
writes nothing.

Where:

1. `LAYOUT_INSPECTOR_DUMP`, if set (the directory also gets the `capture-NNN.txt` dumps);
2. in the simulator, a folder of the Mac user that the Mac reads directly:
   `~/Library/Caches/LayoutInspector/<simulator udid>/<bundle id>/`;
3. otherwise, or when that is not writable, `Library/Caches/LayoutInspector/` in the app's container
   (`status.json` then says `"directoryIsFallback": true`).

Each file is written next to its final name and renamed over it, on a background queue. `status.json` is written
last: when it names a capture, the other two files already hold that capture.

### `status.json`

```json
{
  "schemaVersion": 1,
  "library": "0.2.6",
  "updated": 1795275048.79,
  "app": { "bundleID": "dev.layoutinspector.example", "process": "InspectorDemo", "pid": 32529, "launchID": "23A0…" },
  "enabled": true,
  "graph": true,
  "directoryIsFallback": false,
  "inspector": { "kind": "window", "highlighting": true, "mode": "spacing", "capturing": false },
  "command": { "name": "mode.spacing", "number": 1, "date": 1795275047.93 },
  "capture": { "number": 1, "afterCommand": 1, "date": 1795275048.79, "duration": 0.295, "mode": "spacing",
               "graph": true, "nodes": 98, "timings": ["total 295 ms", "…"], "writeMainThreadMs": 1.5 }
}
```

- `inspector.kind`: `window` (`LayoutInspector.show`), `view` (a `.layoutInspector` modifier) or `none`.
- `command.number` counts the commands this process got. `capture.afterCommand` is the number of the last command
  when that capture started. To wait for the capture a command asked for: post it, wait for `command.name` with a
  `date` after the post, then for `capture.afterCommand >= command.number` with the same `app.launchID`.
- Dates are seconds since 1970. The simulator and the Mac share the clock.

### `capture.json`

```json
{
  "schemaVersion": 1,
  "library": "0.2.6",
  "graph": true,
  "space": { "width": 402, "height": 874, "scale": 3 },
  "capture": { "…": "as in status.json" },
  "nodes": [ { "id": 12, "parent": 11, "tree": "swiftui", "kind": "text", "title": "Text", "…": "…" } ],
  "lint": [ { "id": 1, "severity": "error", "message": "Font 11.5pt is not in the type scale", "node": 57, "rect": [16, 300, 80, 14] } ]
}
```

Units are points of the window the inspector covers (the screen for the window inspector), rounded to 0.01.
Rects are `[x, y, width, height]`; `null` when the node is off screen or hidden by a presentation.

Every node:

| Key | |
|---|---|
| `id`, `parent` | Unique within the process; ids change on every capture. Roots have no `parent`. |
| `tree` | `swiftui` (the view graph) or `uikit` (UIKit views; render layers are left out). |
| `kind` | `host`, `component`, `customModifier`, `stack`, `scroll`, `list`, `control`, `text`, `image`, `shape`, `color`, `spacer`, `divider`, `platform`, `padding`, `frame`, `flexFrame`, `fixedSize`, `aspectRatio`, `offset`, `layoutPriority`, `ignoresSafeArea`, `uikitView`. |
| `title`, `detail` | What the overlay labels show: `ProfileHeader`, `.padding`, `VStack` / `(16)`, `spacing 8 · .leading`, the string of a text. |
| `type` | The Swift type name (cut at 300 characters). |
| `component` | The closest app-defined view the node is in. |
| `frame`, `visible` | |

Present when they apply:

| Key | |
|---|---|
| `text` | `string`, `font` (`family`, `postScriptName`, `size`, `weight`, `textStyle` or `null` for fixed fonts, `lineHeight`, `display`), `color` (`#RRGGBB` or `#RRGGBBAA`), `alignment`, `lines`, `truncated`, `firstBaseline`, `kerning`. |
| `padding` | `declared` (as written; `null` for `.padding()` with the system default), `measured` (from the real geometry), `edges`, `system`. Edges are `top`, `leading`, `bottom`, `trailing`. |
| `stack` | `axis` (`vertical`, `horizontal`, `depth`, `grid`), `name`, `alignment`, `spacing` (as written; `null` = default), `gaps` (as laid out, between consecutive children). |
| `siblingGaps` | For a child of a vertical or horizontal stack: `axis`, `before`, `after`: the gaps to its neighbours, as Spacing draws them. |
| `constraints` | `frame` (the `.frame(…)` as code), `fixedSize`, `layoutPriority`, `spacerMinLength`, `aspectRatio`, `offset`. |
| `image` | `name`, `symbol`, `naturalSize`. |
| `shape`, `fill`, `decorations` | |
| `uikit` | UIKit views: `className`, `text`, `font`, `color`, `constraints` (Auto Layout as text), `autoLayout`, `ambiguous`, `stackSpacing`, `appView`. |
| `accessibility` | `identifier`, `label`. The app fills it for UIKit views only: SwiftUI builds its accessibility tree only while an accessibility client is connected, and reading it from inside the app costs too much. `li` reads the simulator's accessibility tree from the Mac (with `simtool` or `axe`) and adds it to SwiftUI nodes by frame; it then also writes the elements to a top-level `accessibility` list (`frame`, `identifier`, `label`, `role`, `node`) and sets `"accessibilitySource": "mac"`. |

`schemaVersion` changes when a key is removed or renamed or its meaning changes. New keys don't change it.

## Previews and code snippets

```swift
let snapshot = await LayoutInspector.snapshot(ProfileScreen())   // a window of its own, waits until it settles
print(snapshot.report)
let json = snapshot.json()                                          // capture.json
try snapshot.write(to: URL(fileURLWithPath: "/tmp/profile"), modes: [.spacing])   // files + spacing.png
snapshot.close()
```

`snapshot` lays the view out in a window that joins the app's scene when there is one (the preview agent has one),
waits like `captureWhenStable` and captures anyway when the time runs out (`isStable == false`). A `#Preview` with
`.layoutInspector(…)` writes the report files too.

`li preview` runs that through headless Xcode (`xcrun mcp-server`, the Xcode service for agents), without an Xcode window:

```bash
exec Tools/li bridge                         # once, in the background, from the agent's own shell
Tools/li preview Sources/Profile/ProfileScreen.swift --list
Tools/li preview Sources/Profile/ProfileScreen.swift --preview "Profile" --mode spacing,typography
```

Headless Xcode trusts an agent by the code signature of the process that launched `mcpbridge`. `exec` makes that
the agent itself; started from a wrapper (`python3 li bridge`, a script) the first call waits for a human to approve
a new agent. The project's folder must also be allowed for headless Xcode (`xcrun mcp-server status` lists them).

Limits of the snippet path: the window has the scene's safe area, but no navigation chrome around a view that has
none; content SwiftUI draws through RenderBox (charts, some materials) stays empty; a shimmer or a timer never
settles; previews with `@Previewable` state can't run as a snippet (pass the view with `--view`).

## `li`

```
li <mode> [--device UDID] [--bundle ID] [--out DIR] [--timeout S] [--ax auto|on|off] [--no-screenshot]
li off | refresh | close | status
li query  (--text T | --id ID | --label L | --type NAME | --node N) [--index N] [--all] [--json] [--dir DIR]
li measure A [B] [--json]           A, B: text:… id:… label:… type:… node:… or a bare text
li preview FILE (--list | --preview NAME | --index N | --view EXPR) [--mode m1,m2] [--size WxH|fit] [--out DIR]
exec li bridge
li dirs | version
```

- The device is `--device`, else `$LI_DEVICE`, else `$SIMULATOR_UDID`, else the only booted simulator.
- `li` reads `status.json` from `~/Library/Caches/LayoutInspector/<udid>/<bundle id>/`. For an app launched with
  `LAYOUT_INSPECTOR_DUMP`, or one that fell back to its own container, pass `--reports-dir`.
- `measure` takes `--index` for A and `--index-b` for B when several elements match.
- On iOS 18 the inspector can't read component names (the app's own view types), so `component` is missing and
  `--type` finds only SwiftUI types such as `VStack`.
- Every wait has a timeout and ends with a message that says what to check, so no command hangs. The exit
  code is 0 when it worked, 1 for usage errors and missing elements, 2 for environment problems, 3 for timeouts.
- `li` warns when the app's library or schema version differs from its own.
- `measure` follows the Measure mode: when one element contains the other, the four insets between them; otherwise
  the horizontal and vertical gaps (an axis on which they overlap has none). With one element, the insets inside
  its container: the enclosing component, else the closest stack, padding or scroll view.
- `query` prints the element's frame, font, text facts, the paddings that wrap it, its gaps in the parent stack,
  the insets in its container, the nearest element above, below, left and right with the gap to each, and its lint
  issues.
- `preview` queues the build through `plq` when that command is on `PATH` (`--no-queue` to skip).
