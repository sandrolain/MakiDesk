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
  scenes, settings), `NotesStore`, `ClipboardHistory`, `ShelfController` and
  `SystemMonitor` (disk space and CPU readings).

## Modules

| File | Responsibility |
|---|---|
| `MakiDeskApp.swift` | Menu bar, app delegate, first-run Settings bridge, lifecycle. |
| `WorkspaceStore.swift` | Central observable state: settings, window list, groups, focus, layout commands, status, colours, reset. |
| `WindowController.swift` | Accessibility wrappers: discovery, frontmost window, frames, capabilities, full screen, screens. |
| `WindowIndex.swift` | Cached window index with AX/workspace/screen observers; stable identity. |
| `WindowOutlineController.swift`, `FocusBorder.swift` | Click-through focus-border panel and its pure geometry. |
| `PointerEffect.swift`, `PointerEffectController.swift`, `PointerEffectSurface.swift` | Pointer pulse, five presentation styles and click ripple: pure trail/display rules; one click-through panel per display; no permission, no logged coordinates. |
| `WindowCapture.swift` | ScreenCaptureKit previews and the edge-energy content measure. |
| `TilingEngine.swift` | Pure geometry: ladders, halves, quarters, grid, golden spiral, squarified treemap. |
| `LayoutAdvisor.swift` | Pure advisor: window kinds, content measure, priors, suggested preset, reasons. |
| `WindowPalette.swift` | `⌥⇥` / `⌥Space` switcher and search, preview cards, applications shelf, groups column, layout buttons. |
| `InstalledApplications.swift` | Installed `.app` inventory and pure matching for the palette shelf; own worker queue, small in-memory cache. |
| `PaletteMath.swift` | Expression parser for the search field: arithmetic, percentages and the closed unit table; pure, locale-aware separators, no I/O. |
| `WindowDrag.swift`, `DragActivator.swift`, `MacOSTiling.swift` | ⌥-drag snapping, live activator, macOS tiling detection. |
| `GroupStore.swift`, `WindowGroup.swift`, `GroupRenamePrompt.swift` | Groups: members, names, arrangement, persistence. |
| `WindowScene.swift`, `WorkspaceStore` (focus) | Scene/focus state, send-away and undo. |
| `PeekController.swift`, `PeekPanel.swift` | Designated-window overlay and hold state machine. |
| `HUDController.swift` | Small passive feedback panel. |
| `MiniMapController.swift` | Transient real-window overview overlay. |
| `CornerPlacement.swift` | Pure corner rule shared by the mini map and the timer card: keep the corner, step aside for the checklist, stay on the display. |
| `ChecklistModel.swift`, `ChecklistPanel.swift` | Checklist card: items, rules and persistence; the always-on panel. |
| `TimerModel.swift`, `TimerPanel.swift` | Timers: deadlines, text formats and parser, proximity rule; the countdown card and the input field. |
| `SystemMetrics.swift` | Disk space (Finder parity, `statfs` fallback), machine CPU ticks and the `libproc` process snapshot; decimal formatting. |
| `SystemAlertPolicy.swift` | Pure sustained-load rule: duration, hysteresis, cooldown, snooze, and when load is attributed to unreadable system processes. |
| `SystemMonitor.swift` | Owner of the disk and CPU timers, the menu-bar figure, the System menu values and the notices; one utility queue, main-actor publishing. |
| `ListeningPorts.swift` | Pure `lsof -Fpcn` parser, injectable reader, list model; reads on open/refresh, never polls. |
| `PortsWindow.swift` | Ports window: filter, addresses, confirmed `SIGTERM` termination. |
| `SystemNotifier.swift` | Opt-in `UNUserNotificationCenter` copy of a notice; permission asked only when the option is switched on. |
| `ShortcutManager.swift` | Carbon global hot keys (no Input Monitoring). |
| `NotesStore.swift` | Notes, drafts, session, external-file baselines, Trash. |
| `Confirmation.swift` | The modals as values: one wording, one presenter; no file builds an `NSAlert` by hand. |
| `StoredJSONFile.swift` | The JSON-file mechanics four stores repeated: the path, the atomic write, the quarantine of an unreadable file. |
| `NotesPanelViews.swift` | The note panel's leaf views: drop target, split and divider, toolbar buttons, table row. |
| `NotesMarkdownTable.swift` | One Markdown table renderer: the formatter and the rewrite serializer both use it, so they cannot disagree on widths again. |
| `NotesStore.swift` | Notes window, sidebar, toolbar, tabs-free navigation, anchoring. |
| `NotesEditor.swift` | TextKit 1 text view and line-number ruler. |
| `NotesSyntax.swift`, `NotesGrammarQueries.swift` | Syntax configuration, captures, colours, highlighter. |
| `ClipboardHistory.swift`, `ClipboardPanel.swift` | In-memory text and image history, pasteboard poll, image budget and pins, picker. |
| `ShelfController.swift`, `ShelfShake.swift` | Drag shelf, file promises, Quick Look, drag out, shake detector. |
| `ScreenshotLibrary.swift` | Screenshot inventory, Quick Look, native file drags, configurable grid, sorting, date groups and file operations. |
| `MarkupModel.swift` | Pure screenshot markup: arrow, rectangle, pen, highlighter, text label and pixel mosaic, rendered into pixels for both the preview and the saved file. |
| `MarkupCrop.swift` | Pure crop: the capture is replaced and every mark is mapped into the new space, dropped when it falls outside. |
| `ScreenshotAnnotationController.swift` | Area, window or whole-display capture → in-place annotation editor (marks, text, crop) → PNG on the shelf and on the clipboard. |
| `ScreenRecordingController.swift` | Area recording to an H.264 movie: `SCStream` → `AVAssetWriter`, pause with retimed frames, system audio, menu-bar control, `.mov` on the shelf. |
| `ShortcutsWindow.swift` | Searchable keyboard-shortcut reference. |
| `SettingsView.swift` | Tabbed settings, permissions, diagnostics, reset. |
| `SettingsKey.swift` | Every `UserDefaults` key, spelled once; a test fails on any literal written outside it. |
| `CommandRouter.swift` | The dispatcher's pure questions: ladder axis, logical frame, golden cycle, label. Tested without a window. |
| `MakiSignpost.swift` | The Instruments intervals: a frame write, a recognition request. Cheap when nobody is recording, no content in them. |
| `FloatingPanel.swift` | The panel base class: a subclass names its style (utility, keyOverlay, passive, readOnly) instead of overriding the same three members. |
| `HUDMessage.swift`, `HUDMessages.swift` | What a notice says, as a value; the capture family's sentences are written once and checked by a test. |
| `UtilityBarController.swift`, `UtilityBarView.swift` | The utility bar's panel and lifecycle: pointer reveal with a 10 Hz sample while enabled, pin, overflow menu, keyboard session, capture exclusion. |
| `BarReveal.swift`, `BarLayout.swift`, `BarItemCatalog.swift`, `BarConfiguration.swift`, `UtilityBarModel.swift` | Pure rules for when the bar opens and retreats, what fits, which commands it offers, the hand-editable buttons file, and the info text; no AppKit or Accessibility I/O. |
| `TerminalClient.swift` | The MakiDesk side of the terminal helper: launch, one Unix-socket connection, handshake, retries and notices; no socket work on the main thread. |
| `Settings.swift` | Typed reads and the declared defaults; `register(defaults:)` is built from the same table, so "unset" and "the default" are one value. |
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
  `fullSpan` (the ladder's full state on one axis, keeping the other),
  `gridFrames`, `goldenSpiralSlots` (capped at six) and
  `weightedFrames` (squarified treemap, deterministic, gap-inset).
- `LayoutAdvisor` classifies windows by app/title (`WindowKind`), reads the
  content measure and chooses grid/spiral/content. `LayoutAdvisor.weights`
  combines the per-kind priors with `0.7 + 0.6 × score/median`. The advisor is
  pure; all of its rules can be read off tests.
- `WorkspaceStore.applyFrame` is the only path that writes a frame, so a layout,
  a drag, a recall and a manual move all remember the same arrangement.
- `ArrowChord` is the two-arrow chord: a Carbon hot key carries one key, so the
  partner arrow's physical state (`CGEventSource.keyState`, no event tap and no
  extra permission) turns an ordinary step into the full span of that axis. The
  pair must still carry its default rows; a remapped or disabled arrow turns the
  chord off. The rule is pure and tested with an injected key state.

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

Opening an application is part of the search palette (R12), not a panel of its
own: the shelf under the field lists the installed applications. Ranking lives
in `ApplicationSearch.launcherResults` — name, then executable, then bundle id,
with recent use only ordering an empty field and breaking ties — and
`ApplicationUsageStore` keeps that history in one bounded JSON table in the
defaults, read when the palette opens and never polled. `ApplicationCatalog`
owns the coalesced scan and the `⌘Return` new-instance launch, which the palette
asks for instead of duplicating.

`CommandCatalog` (T38) is the typed form of the menu: phrases, a one-line
summary and the action each one runs, all values. `CommandBoxController` shows
them in a panel with an `NSTextField` that reports the arrows, Tab, Return and
Escape through `doCommandBy:`, so the palette's keys work while the field has the
keyboard. Running a command goes through the same `applyShortcut` the menu uses,
so a phrase and a menu row cannot diverge.

The utility bar (F1/F2) is a `FloatingPanel` in the `passive` style at
`.statusBar` level, placed at the top of the display's `visibleFrame` so it never
sits behind the menu bar and never reserves space. `BarReveal` is the whole
decision — a 250 ms dwell in the trigger band, a 400 ms linger, a dismissal that
waits for the pointer to leave, and a pin that suppresses the retreat and makes
an outside click leave the bar alone — as
a value with the pointer and clock injected, so the timing is tested without a
panel. The band is the whole menu bar where the display has one
(`frame.maxY - visibleFrame.maxY`), with a 12 pt minimum at the top edge
elsewhere; while the bar is open it counts as part of the bar, so the pointer
can rest at the top and move down in its own time. A screen change repositions a
pinned bar instead of closing it. `UtilityBarController` samples the pointer at
10 Hz through one
`RunLoop.common` timer that exists only while the setting is on, and stops it,
the click monitors and the `NSWorkspace` observers when it is turned off.
`BarItemCatalog` is the only list of controls: each entry names an existing
`ShortcutAction`, so a click runs the same `applyShortcut` as the key and the
menu. `BarConfiguration` (`Application Support/MakiDesk/utility-bar.json`) holds
the presentation the catalog does not: visibility, order inside each zone and an
optional title and symbol per button. It is the only hand-editable bar state,
loaded at start and re-read with one `stat` when the bar appears, so an edit
applies without a relaunch; a corrupt file is quarantined as `.bak` and a newer
one is used read-only. Ids missing from the file are appended visible, so a new
catalog button needs no migration; the old comma-separated hidden list is read
once and then removed. The right-hand controls never leave the bar. `BarLayout`
picks what fits from the widths the view also uses, badges included (least
important first, rightmost on a tie), and the remainder becomes an `NSMenu`
anchored under the chevron rather than at the pointer, because a passive panel
must not become key and a keyboard session can open it from another display. The Timer button carries the nearest countdown as
its badge; a second info control with the same name was removed. `⌃⌥B` is the one
keyboard session: the panel's `canBecomeKey` is true only then, arrows move the
selection, Esc closes, and `PanelFocusReturn` gives the keyboard back. Its
window number is passed to `SCContentFilter(display:excludingWindows:)` while it
is visible, so the bar stays out of screenshots, OCR and recordings.

### The terminal helper (F1)

The terminal is a second app, not a panel. `MakiDeskTerminal.app` lives in
`Contents/Applications/` with bundle id `com.makidesk.app.terminal`; it is
`.regular` while its window is open and is signed before the outer app. It links
GhosttyKit (a static xcframework, MIT) and lives in the separate `Terminal/`
SwiftPM package, so `swift build` at the repository root neither needs the
binary nor rebuilds the helper. `MakiShared` is the only code both apps link: the
message envelope, length-prefixed framing and the socket location. The workspace
model and its persistence live in `MakiTerminalCore`, which is free of AppKit.

MakiDesk talks to it over `~/Library/Application Support/MakiDesk/Terminal/terminal.sock`
(`0600`, directory `0700`). Frames are four big-endian length bytes plus JSON;
the kinds are a closed set (`hello`, `welcome`, `showMain`, `hideMain`,
`toggleQuake`, `ping`, `quit` and events, including `attention` for a shell
notification that becomes a MakiDesk notice). The helper accepts one client, checks
the peer pid and that it is MakiDesk (bundle id, or the development binary by
name), and replies to `hello` with its version and pid. `TerminalClient` keeps
the connection, retries a launch up to 30 times at 150 ms intervals, and reports
failure in a notice; none of it blocks the main thread. A development `swift run`
looks for `dist/MakiDeskTerminal.app`, because it has no app bundle to nest into.

Inside the helper, a workspace is one sidebar row and one binary split tree of
terminal panes; surfaces are reused across rebuilds, so switching workspaces
never restarts a shell. Keyboard pane focus (`⌘⌥` arrows) reads each visible
pane's frame from the live view hierarchy and asks
`TerminalPaneNavigation.neighbor` in `MakiTerminalCore` for the closest centre
in that direction, so unequal splits and divider positions are respected without
walking the tree. Zoom is a `zoomedPane` on the workspace: the rebuild shows
that one pane, splitting clears it, and closing the zoomed pane clears it too;
`equalizeSplits` rewrites every ratio to 0.5 in the tree. A pane may carry a command instead of the login shell:
an SSH profile in `settings.json` or the tmux preset becomes one, the sidebar's
`+` menu starts a workspace with it, and the layout remembers it. Every pane
receives `MAKIDESK_TERMINAL=1` and its workspace id through Ghostty's env-vars
field, so scripts can identify where they run. Workspace order, titles, split
ratios, the selection, the zoomed pane, each pane's last directory and its
command are written to
`Terminal/workspaces.json`, atomically and
with the usual quarantine/version rules; scrollback is not persisted. Closing the
last pane of the last workspace starts a fresh shell instead of leaving an empty
window. The main window's frame is saved (debounced) to
`Terminal/window.json` and restored only when at least a title-bar-sized part of
it still meets a `visibleFrame`; an unplugged display therefore yields a
centered window. The helper's surface callbacks forward title, cwd and close
events to the window controller; the focused surface answers clipboard requests.

`⌃⌥O` and the menu bar item call `TerminalController`, which sends `showMain` or
launches the helper; `⌃⌥Q` sends `toggleQuake`. The quake is a borderless
`NSPanel` at the floating level with its own scratch workspace, kept alive while
hidden and deliberately outside the saved layout. On each show it takes the
visible frame of the display under the pointer (falling back to the helper's
screen, then the main one) and is placed by the pure
`TerminalQuakePlacement.frame`, so negative display origins and a short
`visibleFrame` stay correct. It carries the Accessibility
identifier `com.makidesk.terminal.quake`; `WindowController`'s discovery drops a
helper window that reports it, so the quake never becomes a card in the switcher
or a tiling target while the helper's main window stays a normal window.

Search lives in the engine too: the find bar (`⌘F`, one per window) sends
Ghostty `search:<needle>` and `navigate_search:next|previous` binding actions,
and the `startSearch`/`endSearch`/`searchTotal`/`searchSelected` surface actions
feed its count. The bar is an AppKit overlay inside the pane host, so it follows
splits and the quake panel; the formatting and clamping of that state are a pure
`TerminalSearchState` in `MakiTerminalCore`. A search session ends when the
workspace is rebuilt, its pane closes or the bar is dismissed.

An image paste cannot reach the shell as a picture: when the clipboard has an
image and no text, `⌘V` writes a PNG under `Terminal/pasted-images/` on a
worker, then types its shell-quoted path at the cursor. `TerminalImagePaste`
owns the name, the quoting and the retention rule (newest 100, at most a week);
the helper prunes at launch and after each paste, and a paste whose encode
finishes after the keyboard moved to another surface is dropped. Text paste
still goes through Ghostty's `paste_from_clipboard`.

The pane is also an accessibility text area. `TerminalSurfaceView` answers
`AXValue` with the active screen read through `ghostty_surface_read_text`, and
`TerminalAccessibilityText` in `MakiTerminalCore` caches that snapshot for half
a second and remembers recently vended values. A client that writes back the
screen it read plus its phrase therefore types only the phrase; a value that is
not an edit is taken literally. A line break inside the text takes
`ghostty_surface_text` (the paste path), while a trailing newline becomes a
Return key press. Selected text and its range come from
`ghostty_surface_read_selection`; after an insertion the helper invalidates the
snapshot and posts `valueChanged`. None of this reads or stores text beyond the
screen snapshot in memory.

Rendering follows what is actually on screen. `TerminalSurfaceView.setRendererVisible`
forwards to `ghostty_surface_set_occlusion` — the C flag is **visible**, so
`false` pauses the renderer — and the window controller recomputes it after a
workspace switch, when the quake opens or closes and on
`windowDidChangeOcclusionState` plus key/main transitions. Panes of unselected
workspaces, a hidden quake, a minimized window and a hidden app stop drawing
while the shells and their output processing continue.
`TerminalRendererVisibility` in `MakiTerminalCore` holds the rule: an occlusion
verdict is honoured only after the window has reported `.visible` once, a key
window is always visible, and before that first report the ordinary on-screen
state is trusted (virtual displays may never raise the bit). A surface created
while the pane is off screen replays the flag on creation.

A terminal bell still beeps, and `GhosttyRuntime.onBell` gives the controller
the ringing surface: `markAttention` adds the workspace dot when that workspace
is not the one in front. It shares the dot and its clearing rule with shell
notifications and a failed or long command.

The helper also ships `Contents/Resources/bin/makidesk`, a one-shot client for
the same socket. `status working|waiting|done [--title …]` reads
`MAKIDESK_WORKSPACE_ID`, sends one `agentStatus` frame and exits; the server
accepts it by executable name and only updates a sidebar dot. `hook` is the same
message in a form that can never fail the caller — no pane, no helper or a
malformed environment all end with exit code 0 and no output, because an agent
hook must not block a prompt and `UserPromptSubmit` stdout would join the
model's context. `hooks status|install|uninstall` manages the opt-in Claude Code
hooks described below. Panes receive `MAKIDESK_CLI` with the stable link's path.

`AgentHooks` in `MakiShared` owns the installation for **Claude Code** and
**Codex**: it parses the agent's settings file as a JSON object
(`~/.claude/settings.json` or `~/.codex/hooks.json`), leaves every key it does
not own alone, and identifies its own handlers by the `hook` marker in their
`args`, so a moved app can replace stale paths and removal never takes a user's
handler with it. Claude Code maps `UserPromptSubmit` → `working`, a
`Notification` matcher (`permission_prompt`, the elicitation dialogs,
`agent_needs_input`) → `waiting`, and `Stop`, `StopFailure` and `SessionEnd` →
`done`. Codex has no notification event, so `PermissionRequest` is `waiting`,
`PreModelRequest` returns to `working` once the approval is answered, and
`Interrupt` joins `Stop` and `SessionEnd` as `done`; its `SessionEnd` ceiling
makes the handler timeout three seconds instead of five. Each is an exec-form
command with the stable CLI path. The first install copies the original file to
`<name>.makidesk-backup`; a file that is not valid JSON or whose `hooks` value
is not an object is refused and left untouched. Codex reviews non-managed hooks
before their first run, so its rows say to trust them with `/hooks`. Settings ▸
Terminal ▸ Agents gives each agent a row that reads that state off the main
thread and performs the merge on a background task.

`TerminalController` watches `NSWorkspace.didActivateApplicationNotification`.
While the helper is frontmost it calls `ShortcutManager.setSuspended(_:keeping:)`
with the two terminal rows, so every other table row and the peek's hold key are
unregistered and the shell receives those combinations. Losing focus puts them
back; the two exceptions stay global so the terminal can always be left.

Settings and theme travel as two JSON documents in
`Terminal/settings.json` and `Terminal/theme.json`, written by MakiDesk and read
by the helper. `TerminalController` owns the settings in memory for the
Settings ▸ Terminal page, writes them on every edit and tells the helper
`settingsChanged` through the socket after a short debounce; a theme change
regenerates `theme.json` from `PaletteTheme` and sends `themeChanged`. The helper
reloads both with `ghostty_app_update_config`, so an open terminal picks up the
font, cursor, selection copy, pointer hiding and colours without a restart; the
shell command and the scrollback limit apply to new panes. The generated configuration also disables
Ghostty's shell-integration cursor (`shell-integration-features = no-cursor`),
so the chosen shape is not replaced by a bar at the prompt. Each theme carries
its own sixteen ANSI colours and the surface/text/accent colours for the
helper's sidebar and title bar.

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

`NotesEditorView` (T20) adopts the system's Writing Tools (T64) instead of
writing prompts: the text view asks for a plain-text result, the delegate hands
the system the fenced code blocks of the note (`NotesWritingTools`, a pure scan
with tests) so an example is never rewritten, and the session's begin/end
suspends the syntax highlighter (`NotesHighlighter.setSuspended`) and the
automatic draft write, which then runs once for the whole rewrite.

`NotesStore` restores a note's metadata first and loads its body on demand, so an
unopened note has an empty placeholder editor for a moment. Text sent from the
shelf or OCR therefore becomes a **new note** (`NotesStore.addNote`): the draft
the user has open is never mutated. The clipboard panel's paste fallback still
inserts at the cursor through `NotesInsertionPolicy` / `NotesInsertionQueue`, so a
note whose body is still loading cannot publish its placeholder over the draft.

`NotesMarkdownFormat` (T65) turns the editor's formatting commands into values —
the range to replace, the replacement and where the selection goes — on UTF-16
ranges, so emoji never split a marker. The editor applies the result through
`shouldChangeText` / `didChangeText`, which keeps it one undoable edit and lets
the store and the syntax highlighter treat it as typing. The model never writes
Markdown: this pure code does, and T66 serialises into it.

`NotesIntelligence` (T66) asks the on-device model (Foundation Models, macOS 26,
behind `#if canImport` and `@available`) for a structure — `@Generable`: title,
summary, sections with paragraphs, bullets and table rows — and
`NotesMarkdownSerializer` writes the Markdown, so the model never emits a
marker and a fence or a table cannot come out broken. `NotesRewriteController`
runs one request at a time with a generation, streams partial drafts into the
preview panel, and drops whatever belongs to an older request; switching note or
closing the panel ends the session. Apply reaches the editor as one undoable
edit. The engine is a protocol, so the state machine is tested with a fake and
the real one only exists on a system that reports the model available.

`ClipboardHistory` polls `changeCount` and stores text entries directly. An image
is read as bytes on the main actor, then decoded, thumbnailed and hashed on a
worker; the generation and `changeCount` are checked at publication, so a copy
that arrives during the decode wins. The budget counts the original bytes plus
the thumbnail; pins are exempt from eviction and from *Clear*, and the list and
the pins stay in memory.

`TextRecognitionController` (T41) reads text with Vision from four sources —
the selected area (shared selector), the window under the pointer, the frontmost
window and the whole screen — and from an image the caller already has (shelf,
screenshot library) or copied on the clipboard (`ClipboardImageSource`, decoded
off the main actor and downscaled before Vision). One pipeline: take or receive
a picture, recognize once, deliver once, with the generation checked at
publication. `TextRecognitionController.windowUnderPointer` is the pure rule for
the window source and is tested without a desktop.

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
wall clock. `TimerStore` writes the same structs to `timers.json` from a serial
queue on every change and again on termination, and `TimerRestore` is the pure
rule a launch applies to them: a running timer carries on with what its deadline
leaves (the time the app was closed is part of the subtraction), a paused one
comes back paused, and one whose deadline passed while the app was closed is
reported once instead of being dropped. `TimerProximity` is the pure hysteresis
behind the card stepping aside: hidden within 70 pt of the pointer, back only
beyond 140 pt and after 0.4 s, so a pointer resting on the boundary cannot make
it flicker. A global `mouseMoved` monitor covers the moving pointer while the
card is on screen, and the same 1 Hz beat samples `NSEvent.mouseLocation` as the
fallback; both stop with the last timer.

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

## Pointer effects

`PointerEffectController` owns three things that share one surface per display:
a one-shot pulse (`⌃⌥⇧P`), a selected presentation style that follows the pointer
while the mode is on (`⌃⌥⇧X`; five minutes by default, or no deadline when the
length is `0`), and a ripple on click. `PointerEffect.swift` holds the decisions
as values — pulse timing and ring stagger, a bounded/de-duplicated trail, display
choice for a point (including the gap between displays), the local point on a
negative-origin display, radius clamping, the follow factor, and the particle/orbit
tuning (a count turned into an emitter birth rate, a size turned into a sprite
scale, dot sizes and the radius that leaves room for them) — so they are tested
without a window server.

The surface is one borderless, non-activating `FloatingPanel` per `NSScreen`,
at `statusBar + 1`, `ignoresMouseEvents` for its whole life, in every space and
over full-screen windows. The ring is a `CAShapeLayer` and radial glow; the
ribbon is a short filled path (at most 26 samples); particles use one
`CAEmitterLayer`; orbit dots rotate as a single child layer; spotlight is a
static dark layer with an even-odd circular mask. The click ripple and pulse
are transient Core Animation layers. Only the spotlight shades the full display;
the others update small layer properties and do not redraw a full-screen view.
The follower samples the pointer at 60 Hz only while it is moving (or while a
button is held, because a native drag can swallow `mouseMoved`), and stops about
a second after the pointer settles. The global and local mouse monitors exist
only while presentation mode is on; a pulse installs no monitor at all, and a
generation counter stops a late pulse from clearing a newer one. Reduce Motion
replaces the ribbon/particles with a static ring and pauses orbit rotation. Sleep,
screen sleep, screen lock and a display parameter change tear the surfaces down
instead of leaving a transparent high-level window behind; the panel is
excluded from the app's still captures by window number, while recordings keep
the cursor and the effect.

No Accessibility, Input Monitoring or Screen Recording is involved: only
`NSEvent.mouseLocation`, and a panel that never takes a click. The pointer is
never logged or persisted.

## System monitor

`SystemMonitor` is separate from `WorkspaceStore`: it changes on its own clock
and the menu-bar label must not be rebuilt under an open menu. One utility
queue reads the start-up volume once a minute (`URLResourceValues` first, which
supplies the purgeable allowance Finder counts, then `statfs`) and, while CPU
alerts are on, samples every 15 seconds: cumulative `host_statistics` ticks for
the machine and `proc_listpids`/`proc_pid_rusage`/`proc_pid_bsdinfo` for each
process. A full scan of a few hundred processes measured about 0.15 ms. Only
value types cross to the main actor. A lifecycle counter and a CPU-timer
generation make late results unpublishable after a restart or a wake; waking
also drops the tick and per-process baselines and resets the policy, so a
slept-through gap cannot look like sustained load.

`ListeningPortsReader` runs `/usr/sbin/lsof -nP -iTCP -sTCP:LISTEN -Fpcn` with a
fixed argv, no shell and a three-second ceiling; stdout is drained on its own
queue so a long list cannot fill the pipe. `ListeningPortsParser` turns the
records into values (pid, port, process, deduplicated addresses) and is tested
without a process. The window reads on open and on Refresh only; termination is
a confirmed `SIGTERM`, never `SIGKILL` and never `sudo`.

`SystemAlertPolicy` turns two samples into at most one notice. A process is
sustained when it has been at or above the threshold for the window (10 minutes
by default) with at least three consecutive samples; two quiet samples reset
the episode; one notice per process per cooldown (30 minutes), five minutes
between different processes; a snooze keeps the episode alive. Per-process
percentages are shares of one core; the machine figure comes from the tick
delta. Root-owned processes answer `EPERM` to `proc_pid_rusage` and are never
named: when the machine total is high and the readable processes explain less
than half of it, the notice is attributed to "System processes". The policy is
pure and tested at arbitrary clock speeds without a real process.

The menu-bar label keeps the last disk figure while
`NSMenu.didBeginTrackingNotification` holds; the newest value is flushed on
`didEndTracking`, because replacing the label's view under an open menu closes
it. Notices go through `HUDController`; the optional second copy is posted by
`SystemNotifier`, whose `UNUserNotificationCenter` is created only for a bundled
app so `swift run` and the test runner never touch it. No process name, path or
command line is logged.

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
behaviour, focus-border placement, timers (formats, deadlines, the launch
restore rule) and the shortcut catalogue. At the time of writing: **801 tests**.

## Design notes

- `NSSplitView` was replaced by a small custom split for the notes sidebar: the
  split view ignored its divider position once the panes used Auto Layout.
- Notes panes use TextKit 1 deliberately: the line-number ruler reads the layout
  manager, and a whole-document parse with a 120 ms debounce is enough for a
  scratchpad.
- A note draft is replaced by writing a temporary file, flushing it, renaming it
  over the old one and flushing the directory entry. The cycle runs on the
  persistence queue behind the 400 ms debounce, so durability does not touch the
  main thread; the panel flushes again when it loses key focus, which is what
  makes autosave have no explicit save step.
- The app never stores window thumbnails or clipboard content on disk.

## Known constraints

- Layout commands act on the main screen; window moves follow the window's
  screen. There is no multi-monitor layout command yet.
- macOS has no public API to move a window between Spaces.
- Accessibility support varies by app; some windows reject frames or expose no
  title. The app reports a refusal instead of silently leaving a gap.
- The current release binary is arm64-only and locally signed; see
  [Distribution](DISTRIBUTION.md) for the notarized release path.
