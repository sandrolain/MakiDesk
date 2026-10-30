# MakiDesk — architecture

MakiDesk is a SwiftPM executable for macOS 14+ with no Xcode project. It runs as
an `.accessory` menu-bar app and controls the **real** windows of other apps; it
never draws a separate desktop or mirrors their content as a workspace.

- [Process model](#process-model)
- [Modules](#modules)
- [Window discovery and control](#window-discovery-and-control)
- [Layout engines](#layout-engines)
- [Window switcher](#window-switcher)
- [Persistence](#persistence)
- [Panels and settings](#panels-and-settings)
- [Permissions](#permissions)
- [Dependencies](#dependencies)
- [Tests](#tests)
- [Design notes](#design-notes)
- [Known constraints](#known-constraints)

## Process model

- `MakiDeskApp` is a SwiftUI `App` with a `MenuBarExtra` and a `Settings`
  scene. It sets the activation policy to `.accessory` (no Dock icon) and
  starts the stores and monitors in `init`.
- Panels are `NSPanel`s or `NSWindow`s with `NSHostingView`/AppKit content:
  the window switcher, notes, clipboard, shelf, shortcuts reference, HUD,
  overlay and peek. Settings is the SwiftUI scene.
- There is one process. State lives in `WorkspaceStore` (windows, groups,
  scenes, settings), `NotesStore`, `ClipboardHistory` and `ShelfController`.

## Modules

| File | Responsibility |
|---|---|
| `MakiDeskApp.swift` | Menu bar, app delegate, first-run Settings bridge, lifecycle. |
| `WorkspaceStore.swift` | Central observable state: settings, window list, groups, focus, layout commands, status, colours, reset. |
| `WindowController.swift` | Accessibility wrappers: discovery, frontmost window, frames, capabilities, full screen, screens. |
| `WindowIndex.swift` | Cached window index with AX/workspace/screen observers; stable identity. |
| `WindowOutlineController.swift`, `FocusBorder.swift` | Click-through focus-border panel and its pure geometry. |
| `WindowCapture.swift` | ScreenCaptureKit previews and the edge-energy content measure. |
| `TilingEngine.swift` | Pure geometry: ladders, halves, quarters, grid, golden spiral, squarified treemap. |
| `LayoutAdvisor.swift` | Pure advisor: window kinds, content measure, priors, suggested preset, reasons. |
| `WindowPalette.swift` | `⌥⇥` / `⌥Space` switcher and search, preview cards, applications shelf, groups column, layout buttons. |
| `InstalledApplications.swift` | Installed `.app` inventory and pure matching for the palette shelf; own worker queue, small in-memory cache. |
| `WindowDrag.swift`, `DragActivator.swift`, `MacOSTiling.swift` | ⌥-drag snapping, live activator, macOS tiling detection. |
| `GroupStore.swift`, `WindowGroup.swift`, `GroupRenamePrompt.swift` | Groups: members, names, arrangement, persistence. |
| `WindowScene.swift`, `WorkspaceStore` (focus) | Scene/focus state, send-away and undo. |
| `PeekController.swift`, `PeekPanel.swift` | Designated-window overlay and hold state machine. |
| `HUDController.swift` | Small passive feedback panel. |
| `MiniMapController.swift` | Transient real-window overview overlay. |
| `CornerPlacement.swift` | Pure corner rule shared by the mini map and the timer card: keep the corner, step aside for the checklist, stay on the display. |
| `ChecklistModel.swift`, `ChecklistPanel.swift` | Checklist card: items, rules and persistence; the always-on panel. |
| `TimerModel.swift`, `TimerPanel.swift` | Timers: deadlines, text formats and parser, proximity rule; the countdown card and the input field. |
| `ShortcutManager.swift` | Carbon global hot keys (no Input Monitoring). |
| `NotesStore.swift` | Notes, drafts, session, external-file baselines, Trash. |
| `NotesPanel.swift` | Notes window, sidebar, toolbar, tabs-free navigation, anchoring. |
| `NotesEditor.swift` | TextKit 1 text view and line-number ruler. |
| `NotesSyntax.swift`, `NotesGrammarQueries.swift` | Syntax configuration, captures, colours, highlighter. |
| `ClipboardHistory.swift`, `ClipboardPanel.swift` | In-memory text history, pasteboard poll, picker. |
| `ShelfController.swift`, `ShelfShake.swift` | Drag shelf, file promises, Quick Look, drag out, shake detector. |
| `ScreenshotLibrary.swift` | Screenshot inventory, Quick Look, native file drags, configurable grid, sorting, date groups and file operations. |
| `MarkupModel.swift` | Pure screenshot markup: arrow, rectangle, pen, highlighter, text label and pixel mosaic, rendered into pixels for both the preview and the saved file. |
| `MarkupCrop.swift` | Pure crop: the capture is replaced and every mark is mapped into the new space, dropped when it falls outside. |
| `ScreenshotAnnotationController.swift` | Area, window or whole-display capture → in-place annotation editor (marks, text, crop) → PNG on the shelf and on the clipboard. |
| `ScreenRecordingController.swift` | Area recording to an H.264 movie: `SCStream` → `AVAssetWriter`, pause with retimed frames, system audio, menu-bar control, `.mov` on the shelf. |
| `ShortcutsWindow.swift` | Searchable keyboard-shortcut reference. |
| `SettingsView.swift` | Tabbed settings, permissions, reset. |
| `Theme.swift`, `MenuBarIcon.swift` | Palette themes and the menu-bar glyph. |
| `LegacyMigration.swift` | One-time migration from the project's previous name. |
| `CanvasCore.swift` | Legacy geometry/helpers from the earlier canvas prototype; no longer referenced by the live app. |

## Window discovery and control

`WindowIndex` owns the cache. It reads `CGWindowList`/Accessibility, filters to
real windows (normal window level, a frame, an accessibility window), and keeps
a stable identity across title changes where possible. `WindowController`
provides the AX operations and verifies a frame after setting it; apps that
clamp or ignore a size are retried and reported (the T27 behaviour).

AX move/resize events keep one pending geometry read per window. A burst is
flushed after a fixed debounce, and frame reads run on a serial utility queue;
newer events replace pending work, while stale results are discarded before
the cache and UI are updated. Change and focus notifications share a fixed
debounce window so a noisy event source cannot keep postponing publication.
Matching AX and `NSWorkspace` app-activation events share one immediate focus
refresh; the existing delayed focus publication still runs.

`WindowOutlineController` draws the focus border in a transparent,
click-through panel at the target window's level. Other apps' windows arrive
through `WindowIndex`'s focus events and coalesced geometry results. During a
drag, the border follows Window Server bounds until release; ordinary geometry
updates reuse the frame read by the index. MakiDesk's own windows come from the
key/main window and the `NSWindow` move, resize and focus notifications.
`FocusBorder` owns the outset and corner arithmetic and is tested without a
window server.

`FocusDimController` (T62) dims everything outside the focused window with one
click-through panel per display at the ordinary window level, ordered under the
target with `order(.below, relativeTo:)`. The relationship is the stacking
order, so a window that moves or resizes needs no update and no frame is read.
`FocusDim` owns the anchor rules — which display is lit, the topmost window of a
display, the lowest window of the frontmost app, the focused window but only
when it still belongs to the app in front, and the drift rule — and is tested
without a window server. That last check matters: a focus read that lands after
the user has already moved to another app names the previous app's window, and
anchoring there would keep the app that just lost the focus lit over the veil. A fixed set of windows (`FocusDim.Source
.selection`, T62 phase 2) would light everything between its windows if it were
anchored as it stands, so the set is brought forward first, once per pick, the
way the switcher and the groups activate a window: macOS keeps the active app's
windows above the others, so activating the apps is the only public way to lift
a background window (Accessibility's raise reports success and changes nothing).
The picks are activated in reverse pick order, which leaves the first pick in
front and the set contiguous at the top; the veil then anchors under the lowest
of them on each display, with no geometry and no hole to track. The activation is
postponed while the switcher is open — it would take the keyboard away from it —
and completed by `WindowPalette.hide()` and by the drift check; a window the user
activates from the switcher is queued as the last step, so the set lands under it
and the keyboard ends where they chose. It is never repeated for the same set, so
choosing another app later is not fought. The set is
`WorkspaceStore.veilSelection`, filled by ⌥-clicking cards in the switcher (or
⌥K on the highlighted one) and toggled through the pure `FocusDim.toggled`,
which keeps pick order because *Only the active display* reads the first pick.
It is session state, resolved against the current snapshot by stable identity; a
minimised window is skipped while it is in the Dock, a window that is gone cannot
be anchored to, and an empty plan takes the veil down. The
selection mode is planned before the focus is read: it does not depend on which
window or app has the keyboard, so it also holds while the switcher or another
MakiDesk panel is in front. A one-second drift check runs only while the
veil is up and re-orders the panel when it has slipped above its anchor; a
pending fade-out is invalidated by generation, so a veil that comes back before
it ends is not ordered out from under the new one.

The `WorkspaceStore` reads the index freshly before a command (`syncNow`) and
keeps a model for the palette/overlay. It never assumes that a window found a
moment ago is still there.

## Layout engines

All layout maths is pure and unit-tested:

- `TilingEngine` has the seven-position ladder, fixed halves/quarters,
  `gridFrames`, `goldenSpiralSlots` (capped at six) and
  `weightedFrames` (squarified treemap, deterministic, gap-inset).
- `LayoutAdvisor` classifies windows by app/title (`WindowKind`), reads the
  content measure and chooses grid/spiral/content. `LayoutAdvisor.weights`
  combines the per-kind priors with `0.7 + 0.6 × score/median`. The advisor is
  pure; all of its rules can be read off tests.
- `WorkspaceStore.applyFrame` is the only path that writes a frame, so a layout,
  a drag, a recall and a manual move all remember the same arrangement.

`WindowCapture` produces downscaled images on a background queue and
`edgeEnergy` turns them into a scalar. The switcher uses the same captures for
previews, so the advisor does not add a capture pass.

## Window switcher

`WindowPalette` is a SwiftUI panel with a model. Browse mode keeps the keyboard
in the panel (no field focus); `⌥Space` enters search. `PaletteLayoutEngine` is a
pure geometry helper for cards/columns/panel size and has its own tests; in
search mode it also reserves the applications shelf. Previews are cached in
memory, refreshed on open and periodically while the panel is visible.
`ApplicationCatalog` scans `/Applications`, `/System/Applications` and
`~/Applications` off the main thread, coalesces concurrent requests and publishes
value-only `InstalledApplication` records; `ApplicationSearch` ranks them without
I/O. Icons are loaded on the main thread only for the visible matches. The groups
column edits the real groups; ticks are the members of the group being edited.
The footer's layout commands call the same store methods as the menu and
keyboard.

## Persistence

| Data | Where |
|---|---|
| Window groups | `~/Library/Application Support/MakiDesk/groups.json` |
| Notes and drafts | `~/Library/Application Support/MakiDesk/Note/note-<uuid>.txt` |
| Notes session | `…/Note/session.json` (order, cursors, languages, external paths, frame, anchor) |
| Preferences | `UserDefaults` (theme, layout priors, shelf shake, screenshot folder/view, animations, switcher, etc.) |
| Clipboard history | Memory only; lost on quit |
| Shelf | Memory + a temporary staging folder; removed on close |
| Screenshot library | Original image files stay in the selected folder; previews are generated on demand in memory |
| Peek | Session only; nothing on disk |

Writes are debounced (notes 0.4 s, session 0.6 s) and flushed on hide/quit; the
session carries a clean-close marker. An external file opened as a note keeps a
baseline; saving writes only on `⌘S`.

## Panels and settings

The panels share the app theme: the switcher, notes, clipboard, shelf, HUD,
overlay and Settings all read `PaletteTheme` and repaint on
`.makiDeskThemeChanged`. Settings keeps native controls but paints its
background, sidebar and section cards with the theme, and flips the window
appearance to match light or dark themes. Its window is AppKit's own
(`SettingsController`), not a SwiftUI `Window` scene: SwiftUI builds those with
`.borderless` in the style mask and keeps the title bar behind the hosted
content, which on macOS 26 left the standard close/minimise/zoom buttons drawn
under the content, invisible and unclickable. Its sections are a single enum whose
raw values are the persisted selection, so the menu's deep links and an existing
preference keep pointing at the same page. Pages with many groups split them
into a strip of sub-sections, held as view state: the choice lasts while the
window is open and is deliberately not a stored preference. Animations
have one switch and one duration in Settings; macOS Reduce Motion always wins.
The keyboard reference is a plain data catalogue (`ShortcutCatalog`) rendered by
a searchable window.

`ThemedTextCursor` keeps the caret and the selection on the theme accent for
every editable control. They all edit through AppKit's shared field editor, an
`NSTextView` that posts `NSText.didBeginEditingNotification`, so one observer
covers SwiftUI text fields, search fields and the Notes editor without owning
any of them; a theme change repaints the open ones immediately.

`ApplicationLauncherController` (T37) is a separate panel from the window
palette: a field, the installed applications and no captures. Ranking lives in
`ApplicationSearch.launcherResults` — the same name/executable/bundle-id order
as the palette's shelf, with recent use only ordering an empty field and
breaking ties — and `ApplicationUsageStore` keeps that history in one bounded
JSON table in the defaults. `ApplicationCatalog` owns the coalesced scan and the
`⌘Return` new-instance launch, so the launcher does not duplicate either.

`CommandCatalog` (T38) is the typed form of the menu: phrases, a one-line
summary and the action each one runs, all values. `CommandBoxController` shows
them in a panel with an `NSTextField` that reports the arrows, Tab, Return and
Escape through `doCommandBy:`, so the palette's keys work while the field has the
keyboard. Running a command goes through the same `applyShortcut` the menu uses,
so a phrase and a menu row cannot diverge.

`ScreenshotCaptureWatcher` (T48) keeps one FSEvents stream on the screenshot
folder while the opt-in notice is on, baselines the files already there, and
announces only a fresh image, with Shelf and Copy text as actions. Its policy —
enabled, not while secure input is on, image, younger than eight seconds — is a
pure rule with tests; the scan runs on a worker and publishes on the main actor,
and the library and the watcher share the localised capture names
(`ScreenshotNames`) so they cannot drift.

`ScreenshotAnnotationController` (T40) takes one picture — an area through the
shared selector, the window in front of the app that was in front before our
menu opened, or the display under the pointer — and shows it in one editor.
Marks are values in normalised coordinates rendered into pixels by
`MarkupRenderer`, so the preview and the saved file cannot disagree; a crop is
the one operation that changes the capture itself, and `MarkupCrop` moves the
marks into the new space so they stay where they were drawn.

`ScreenRecordingController` (T40) records an area with `SCStream` into an
`AVAssetWriter` (H.264, 30 fps, system audio when the setting is on). The stream
hands its samples to one serial queue and pause/resume/stop are commands on that
same queue, which is the documented invariant behind `@unchecked Sendable` on
the session; a paused stretch is cut out by retiming the samples instead of
leaving a frozen frame. The writer opens the file itself, so a session that
never saw a frame removes it again and reports "nothing captured" instead of
leaving an empty movie. The menu-bar menu owns pause/resume/stop while a
recording runs, and its icon changes so the recording is not forgotten.

`TextRecognitionController` (T41) reads text with Vision from four sources —
the selected area (shared selector), the window under the pointer, the frontmost
window and the whole screen — and from an image the caller already has. One
pipeline: take or receive a picture, recognize once, deliver once, with the
generation checked at publication. `TextRecognitionController.windowUnderPointer`
is the pure rule for the window source and is tested without a desktop.

`HUDController` keeps what is on screen in two lanes (`HUDStack`): sticky
notices the user must dismiss, and transients that expire. The budgets are
separate, so a sticky notice never blocks the queue and a burst never pushes an
unread error away; one `layout()` stacks progress, sticky notices and
transients together. A transient notice is click-through; a sticky one is a
small interactive card, closed by a click anywhere on it (the ✕ is drawn as a
hint, not as a separate target), and it can carry `HUDAction`s that are rendered
as their own buttons and dismissed once used. `HUDStickyPolicy` owns the "nothing sticky by
default, errors if the option is on" rule and `HUDTiming.duration(for:base:)`
returns `nil` for a sticky notice.

`TimerController` (T61) owns the timers, one beat and one card. `TimerBoard`
holds deadlines as absolute instants — a countdown and an "until 8:30" timer are
the same thing once started — and `TimerText` owns the formats and the parser
(`25m`, `1h 30m`, `8:30` as a time of day). The 1 Hz timer exists only while
something is running; every remaining time is read from the deadline, so a
sleep or a clock change cannot make it drift, and expiry is decided against the
wall clock. `TimerProximity` is the pure hysteresis behind the card stepping
aside: hidden within 70 pt of the pointer, back only beyond 140 pt and after
0.4 s, so a pointer resting on the boundary cannot make it flicker. A global
`mouseMoved` monitor covers the moving pointer while the card is on screen, and
the same 1 Hz beat samples `NSEvent.mouseLocation` as the fallback; both stop
with the last timer.

`ChecklistController` (T59) owns one small card: a borderless, non-activating
panel at the floating level, in every space, sized to its content and placed in
a corner by `ChecklistSettings.frame` (the same corner arithmetic the notices
use). `Checklist` holds the items and their rules — trim, 200 characters per
item, 50 items, one-step moves, clear completed — and `ChecklistFile` writes
them atomically to `checklist.json` from a serial queue, setting an unreadable
file aside as `.bak`. Ticking never activates MakiDesk; the panel takes the keys
only when the add field is clicked, and `PanelFocusReturn` gives them back on
hide or on `Esc`. The card is SwiftUI in an `NSHostingView` and the controller
re-measures it after each change, so the list grows and shrinks with its
content.

## Permissions

- **Accessibility** — AX window discovery/frames, `CGEvent` for clipboard paste,
  the shelf's global shake monitor. No Input Monitoring entitlement is requested.
- **Screen Recording** — ScreenCaptureKit previews and the content measure.
- **No sandbox** — the app is distributed outside the Mac App Store. A sandboxed
  build would not be able to drive other apps' windows this way.

macOS keys TCC grants on the app's code identity. A stable signing identity and
bundle id keep the grants across rebuilds (`task cert` / `task sign`).

## Dependencies

The notes editor links a syntax runtime and nine grammar packages. Their exact
versions are pinned in `Package.resolved`; their licences and copyright notices
are in [THIRD_PARTY_NOTICES](../THIRD_PARTY_NOTICES.md). The JavaScript, Python and
CSS external scanners are vendored in `Sources/GrammarScanners` because the
upstream SwiftPM manifests look for `scanner.c` relative to the current working
directory and leave it out of a normal build. The highlight queries are embedded
in `NotesGrammarQueries.swift` to avoid resource-bundle packaging.

## Tests

`swift test` runs the SwiftPM test target. The suite covers geometry (ladders,
grid, spiral, treemap), the advisor and weights, group/scene logic, window
identity, content scores, the palette geometry, notes persistence and external
drafts, grammar compilation, clipboard history, shelf shake and shelf item
behaviour, focus-border placement, and the shortcut catalogue. At the time of
writing: **235 tests**.

## Design notes

- `NSSplitView` was replaced by a small custom split for the notes sidebar: the
  split view ignored its divider position once the panes used Auto Layout.
- Notes panes use TextKit 1 deliberately: the line-number ruler reads the layout
  manager, and a whole-document parse with a 120 ms debounce is enough for a
  scratchpad.
- The app never stores window thumbnails or clipboard text on disk.

## Known constraints

- Layout commands act on the main screen; window moves follow the window's
  screen. There is no multi-monitor layout command yet.
- macOS has no public API to move a window between Spaces.
- Accessibility support varies by app; some windows reject frames or expose no
  title. The app reports a refusal instead of silently leaving a gap.
- The current release binary is arm64-only and locally signed; see
  [Distribution](DISTRIBUTION.md) for the notarized release path.
