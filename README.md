# MakiDesk

Native macOS app for managing application windows in an infinite spatial canvas.

## Requirements
- macOS 14+
- Xcode 15+ (or Swift 5.9 toolchain)

## Run
Open `Package.swift` in Xcode and run the `MakiDesk` executable target, or from Terminal:

```sh
swift run
```

MakiDesk is live-only: it discovers and controls real application windows through Accessibility.
MakiDesk runs as a menu-bar app; it does not open a fake or mirrored window canvas.
Real application windows remain in their own macOS windows and are moved directly.
First launch opens Setup with permission status, instructions, and link to Accessibility settings.
The Preferences window is resizable and its layout reflows to the window width (fields stretch,
long captions wrap, and the permission buttons stack when the window is narrow).

## Taskfile commands

Install [go-task](https://taskfile.dev/) if needed, then run commands from project root:

```sh
task cert     # create a stable signing identity (run once, see below)
task build    # debug build
task run      # build and run SwiftPM executable
task release  # optimized release build
task bundle   # create dist/MakiDesk.app
task sign     # sign the app bundle (stable identity if present, else ad-hoc)
task open     # build, sign, and launch .app
task install  # copy signed app to ~/Applications
task clean    # remove build products and dist/
```

Use `task open` or `task install` before configuring Accessibility. A raw `swift run`
executable is not a selectable `.app` in System Settings.

### Keep the Accessibility permission across rebuilds

By default an ad-hoc signature has no stable identity, so macOS treats every rebuild as a
new app and resets the Accessibility permission. Run this **once**:

```sh
task cert
```

It creates a self-signed code-signing certificate (`MakiDesk Local Signing`) in a dedicated
keychain. From then on `task sign` uses it, giving the app a stable Designated Requirement
(`identifier "com.makidesk.app"` + the certificate), so the permission survives rebuilds.

The **first** build after switching from ad-hoc to the certificate needs the permission
granted once more, because TCC keys the grant on the code identity (ad-hoc grants are pinned
to the binary's cdhash, which changes on every build). Do this once:

```sh
task reset-permission   # clear the stale ad-hoc entry (optional but clean)
task open               # rebuild, sign with the certificate, launch
```

Then enable MakiDesk in **System Settings → Privacy & Security → Accessibility** (remove any
duplicate entry first). After that, rebuilds keep the permission — no re-granting. Trusting
the certificate in the system trust store is **not** required for this; TCC only needs a
stable anchor. `task cert` is idempotent — running it again does nothing.

## Controls
- Drag empty canvas: pan
- Scroll / trackpad scroll: pan
- `+` / `-`: zoom
- `0`: reset viewport
- Arrow keys: move selected window
- Double-click a window card: select it
- Connect: request Accessibility permission and discover real windows
- Refresh: update the list of real windows
- Tile: divide windows across the main screen
- Grid: align windows to the canvas grid
- Gap: configure spacing used by Tile and Grid

## Global shortcuts

Shortcuts act on the frontmost real application window, like Rectangle. MakiDesk must
have Accessibility permission; the app does not need to be focused.

- `⌥⌘←` / `⌥⌘→`: left/right half
- `⌃⌥←` / `⌃⌥→`: step the window horizontally (width + x) through the golden/half/full ladder
- `⌃⌥↑` / `⌃⌥↓`: step the window vertically (height + y) through the golden/half/full ladder
- `⌃⌥U` / `⌃⌥I`: top-left/top-right quarter
- `⌃⌥J` / `⌃⌥K`: bottom-left/bottom-right quarter
- `⌃⌥D` / `⌃⌥F` / `⌃⌥G`: first/center/last third
- `⌃⌥E` / `⌃⌥T`: first/last two thirds
- `⌃⌥P`: golden-ratio (`phi`) layout
- `⌥⌘F` / `⌃⌥↩`: maximize
- `⌃⌥C`: center window
- `⌥⇥` / `⌥⇧⇥`: window switcher — a grid of live previews of every window
- `⌥Space`: search windows and bring the selected one back on screen

The shortcuts are registered when MakiDesk opens and apply to the frontmost window.
The switcher/search thumbnails are cached in memory: reopening the grid shows the last
previews immediately (they never blink empty), and they are refreshed when the grid opens
and every couple of seconds while it stays open, so they stay current.
Mini-map overlay appears above other windows during movement when enabled in Settings.
It shows every window (including parked/off-screen ones) with a rectangle for the on-screen
area, colours each app differently, draws an evident border around the focused window and
respects the real stacking order. It also appears when you switch the active window. It is
non-interactive and disappears after two seconds.

Every overlay follows the theme chosen in Settings: the mini-map, the drag-to-snap preview
rectangle and the parking-zone highlight all use the theme's accent (and the per-app window
colours are derived from that accent).

## Window placement

Everything works on the single screen. Positions never depend on the other windows, so a
command is never blocked by an overlap.

- **Arrow keys walk a position ladder.** `⌃⌥←`/`⌃⌥→` step the window horizontally and
  `⌃⌥↑`/`⌃⌥↓` vertically through seven states that sweep from one edge to the other:
  golden-minor, half, golden-major, **full**, golden-major, half, golden-minor. Horizontal
  steps only change the width and x; vertical steps only change the height and y — so a
  window can be resized inside a corner (e.g. within the top half) without its other
  dimension being touched. The step is taken **from wherever the window currently is**, so
  the command is progressive rather than always restarting.
- **Past the ends.** Horizontally, one more step past golden-minor **parks** the window off
  the side, leaving the strip macOS reserves visible (and bringing it back on the next step
  the other way). Vertically, past the top it shrinks to the **minimum height**; past the
  bottom it **minimises** the window.
- **Drag with the activator keys held** to place a window with the mouse. While you drag,
  an overlay shows the frame the window will take on release. The overlay **snaps to the
  nearest half / golden position** — the same ladder the keyboard walks — so you land on a
  real position instead of a free-form box. Dragging to the far left/right parks the window.
  You can press and release the activator at any time during the drag: hold to snap, let go
  to move freely. The activator defaults to **⌥** and is configurable in Settings ▸
  Placement (with a master **Enable drag to snap** switch); **Control is not offered**
  because `⌃`-click is macOS's secondary click and would open a context menu instead of
  dragging.
- **MakiDesk's ⌥-drag replaces the macOS one.** Since macOS Sequoia the system also tiles a
  window dragged with `⌥` (“Hold ⌥ key while dragging windows to tile”). Settings ▸ macOS
  integration detects that switch, flags it when it is on and lets you turn it off right
  there, so only MakiDesk reacts — no double overlay.
- **Opt+Tab** opens a grid of live previews of every window of every app; `⌥⇧⇥` cycles
  backwards. Releasing Option (or Return) activates the highlighted window, Esc cancels.
  While the grid is open, `⌥Q` closes the highlighted window, `⌥⇧Q` quits its app
  (unforced, so save prompts still appear) and `⌥M` minimises it (it stays in the grid so
  you can bring it back). Each card shows the app's icon; minimised and parked windows are
  hatched and carry a state badge (top-right), and when there is no live thumbnail the
  app's real icon is shown large. Every app gets its own colour. Picking a parked window
  brings it back where it was. Previews need the **Screen Recording** permission; without
  it cards fall back to icons.
- **Opt+Space** opens a search field. Type to filter; Return brings the window back on
  screen (un-minimising it or pulling it inside the visible area) and focuses it, or just
  focuses it if it is already on screen.
- **Full screen switcher.** Settings ▸ *Window switcher & search* has *Open the switcher
  full screen*: the palette then fills the visible frame (menu bar and Dock respected) with
  larger cards, thumbnails and text, and captures previews at a higher resolution. It uses
  the same `⌥⇥` / `⌥Space` shortcuts — no separate hotkey. The grid keeps the same columns
  and rows as the compact list; only the size changes.
- **Columns and maximum size.** *Window switcher & search* also has a *Columns* picker
  (*Automatic*, which picks 2–4 by window count, or a fixed 2–8) and a *Max size* slider
  (160–480 pt) for the largest a card may get, in both layouts. A fixed count never makes more
  columns than there are windows, and if the columns would overflow the screen's width the
  cards shrink below the maximum so the whole grid still fits.
- **Screen-shaped previews.** Every preview box keeps the screen's own width/height ratio, so
  a card is never an over-wide or over-tall ribbon; a maximised window's thumbnail fills its
  box exactly.
- **Neutral previews.** *Colour previews with the app colour* (same section) turns the
  per-app tint off, leaving the cards on the theme's neutral surface; selection, state badges
  and real thumbnails are unchanged. The mini-map still uses the per-app colours.
- **Layout from the switcher.** In browse mode, `space` ticks the highlighted card, `⌘`-click
  ticks a card, and `⌘A` (or the *All* / *None* buttons) selects all or none. The footer's
  *Tile* and *Golden* buttons then lay out **only the ticked windows** (all of them when
  nothing is ticked) and close the palette. The **golden spiral** now serves up to **six**
  windows — later slots would be sliver thin, so extra windows are left where they are. The
  Layout menu also has *Tile Selected Windows* / *Auto Layout Selected Windows* for the last
  selection.
- **Reset.** Settings ▸ *Reset all settings to defaults* (with a confirmation) puts every
  option back to its default. It keeps the onboarding completion and leaves the macOS
  ⌥-tiling preference alone, since that one is a system-wide setting.

## Real window control

Build the selectable app bundle with:

```sh
task open
```

Then allow `dist/MakiDesk.app` in **System Settings > Privacy & Security > Accessibility**.
If installed, select `~/Applications/MakiDesk.app` instead.
After permission is granted, MakiDesk automatically discovers windows. Use **Refresh** after
opening or closing applications.
Global shortcuts, **Tile**, **Grid**, and **Phi** update real window position and size through macOS Accessibility APIs.
Configured gap applies to screen edges and between layout regions.

If MakiDesk keeps reopening Accessibility settings after a rebuild, run `task cert` once
and rebuild (`task open`) so the app gets a stable identity. When switching from an old
ad-hoc build, remove the previous MakiDesk entry in **Accessibility** with “−” and add the
new one; after that the permission persists across rebuilds.

Some applications reject Accessibility commands, and minimized/full-screen windows may not expose writable frames.

## Architecture
- `CanvasCore.swift`: workspace model and layout geometry
- `TilingEngine.swift`: single-screen ladder and region geometry
- `WindowIndex.swift`: cached window index plus AX/workspace/screen observers
- `WindowCapture.swift`: ScreenCaptureKit previews and Screen Recording permission
- `MiniMapController.swift`: transient real-window map overlay
- `WindowPalette.swift`: Opt+Tab / Opt+Space preview palette (browse + search)
- `WorkspaceStore.swift`: window discovery, tiling and shortcut orchestration
- `WindowController.swift`: Accessibility discovery and frame control
- `SettingsView.swift`: first-run setup and preferences

## Important limitation
macOS does not provide a public general-purpose API for moving other apps' windows between Spaces. Accessibility support varies per application. MakiDesk controls position and size for windows exposed by Accessibility; it does not switch Spaces or guarantee persistence across application restarts.

## Next milestones
1. Improve stable window identity across application restarts.
2. Add explicit multi-monitor layout selection.
3. Add dry-run preview before applying large layouts.
4. Test application-specific Accessibility failures and Spaces behavior.

## Distribution

The source is MIT-licensed and every runtime dependency is permissive (MIT or
BSD-3); no GPL or AGPL code is linked. `task dmg` packages
`dist/MakiDesk-<version>.dmg` with the app, an `/Applications` link,
`LICENSE`, `THIRD_PARTY_NOTICES.md` and this README.

That DMG is **not distribution-ready as it is**: the current build is
**arm64-only** and signed with a local self-signed identity (`MakiDesk Local
Signing`), so Gatekeeper rejects it on another Mac (`spctl -a` says
“rejected”). For a clean GitHub download:

1. Join the Apple Developer Program and create a **Developer ID Application**
   certificate. The Mac App Store is not an option for this design: MakiDesk
   needs Accessibility and is not sandboxed.
2. Build **arm64 + x86_64** (universal) with Xcode or SwiftPM’s multi-arch
   build, then sign the app with the hardened runtime:
   ```sh
   task bundle        # or build the universal app yourself
   codesign --force --options runtime --timestamp \
     --sign "Developer ID Application: Your Name (TEAMID)" dist/MakiDesk.app
   ```
3. Package and sign the DMG, then notarize and staple it:
   ```sh
   task dmg-only
   codesign --force --timestamp --sign "Developer ID Application: …" \
     dist/MakiDesk-0.2.0.dmg
   xcrun notarytool submit dist/MakiDesk-0.2.0.dmg \
     --keychain-profile "notary" --wait
   xcrun stapler staple dist/MakiDesk-0.2.0.dmg
   spctl -a -vv dist/MakiDesk.app
   ```
   `notarytool` needs an app-specific password or API key stored once in a
   keychain profile. `task dmg` (without `-only`) is the convenience path for
   a local DMG: it re-signs with the local identity, so do not use it after
   the Developer ID signature.
4. Publish a GitHub Release with the DMG, its SHA-256 and a source tag. Keep
   `refs/` out of the repository (it contains third-party checkouts used for
   analysis and is git-ignored), and include `Package.resolved` for a
   reproducible dependency set.

Without notarization the source is still usable (`task build` / `task open`);
only the convenience binary needs the paid identity. The build needs macOS 14
or later and, at runtime, **Accessibility** (window control, clipboard paste,
shelf shake) and **Screen Recording** (window previews and content-weighted
layout). Permissions survive updates only while the bundle identifier and the
signing identity stay the same.

The project name is not a trademark clearance: check that “MakiDesk” is free in
your jurisdiction before publishing a binary.

## Privacy and permissions

- **No network, no telemetry.** There are no analytics, crash uploaders or
  accounts. The only URLs the app opens are ones you drag onto the shelf, a
  file you ask Finder to reveal, or the licence files in Settings.
- **No sandbox.** MakiDesk needs Accessibility to read and move other apps’
  windows and to paste into them, and Screen Recording for previews and the
  content measure. Both are granted and revoked by the user in System Settings.
- **Local data.** Notes and drafts live in
  `~/Library/Application Support/MakiDesk/Note/`; window groups live beside
  them. Shelf items are references to your files, with a temporary staging
  folder for file promises that is removed when the shelf closes. The
  clipboard history is **in memory only** and disappears when the app quits.
- Window titles, previews, notes and clipboard contents are never uploaded.

## Credits
The colour presets in `Theme.swift` follow the palettes published by
[Catppuccin](https://github.com/catppuccin/catppuccin),
[Dracula](https://draculatheme.com),
[Nord](https://www.nordtheme.com),
[Tokyo Night](https://github.com/folke/tokyonight.nvim),
[Gruvbox](https://github.com/morhetz/gruvbox) and
[One Dark](https://github.com/atom/one-dark-syntax). Only colour values are
used; no code from those projects is included.

The shelf's shake presets and drag-and-drop ordering are inspired by
[OpenYoink](https://github.com/weijue/OpenYoink) (MIT, © 2026 weijue); the
detector is rewritten here, no code is copied. The shelf itself is inspired by
[Dropover](https://dropoverapp.com); no name, icon or interface text is taken
from it.

The notes editor highlights code with
[tree-sitter](https://github.com/tree-sitter/tree-sitter) and
[SwiftTreeSitter](https://github.com/ChimeHQ/SwiftTreeSitter), plus the
tree-sitter grammars for Swift, JSON, Markdown, shell, Python, JavaScript,
TypeScript, HTML and CSS. Their licences and copyright notices are listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). The scanner sources for
JavaScript, Python and CSS are vendored in `Sources/GrammarScanners` because
the upstream SwiftPM manifests leave them out of a normal build.

## License

MakiDesk is released under the [MIT License](LICENSE).
