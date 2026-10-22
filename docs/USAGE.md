# MakiDesk — usage guide

MakiDesk is a menu-bar app that works on the windows you already have. There is
no separate canvas and no fake desktop: every command moves a real macOS window
through Accessibility.

- [Getting started](#getting-started)
- [Window tiling](#window-tiling)
- [Focus border](#focus-border)
- [Layouts](#layouts)
- [Window switcher and search](#window-switcher-and-search)
- [Groups](#groups)
- [Focus](#focus)
- [Peek](#peek)
- [Notes](#notes)
- [Clipboard history](#clipboard-history)
- [Shelf](#shelf)
- [Settings](#settings)
- [Keyboard shortcuts](#keyboard-shortcuts)
- [Troubleshooting](#troubleshooting)

## Getting started

1. Launch MakiDesk. It appears in the menu bar, not in the Dock.
2. Open the menu-bar icon and choose **Settings** (or accept the first-run
   setup window). Grant **Accessibility** so MakiDesk can read and move other
   apps' windows, and **Screen Recording** for live previews and the
   content-weighted layout.
3. Press `⌥⇥` for the window switcher, `⌥N` for notes, or use the window
   shortcuts below from any app.

The permissions are standard macOS TCC permissions: MakiDesk cannot grant them
itself, and you can revoke them at any time in **System Settings ▸ Privacy &
Security**. The app is not sandboxed; see [Privacy](PRIVACY.md).

If a shortcut is taken by another app, Settings ▸ General shows how many were
registered and how many were blocked. Close the other app or change its
shortcut; MakiDesk cannot override it.

## Window tiling

These shortcuts act on the frontmost window and are global (they do not require
MakiDesk to be focused):

| Action | Shortcut |
|---|---|
| Left / right half | `⌃⌥←` / `⌃⌥→` |
| Top / bottom half | `⌃⌥↑` / `⌃⌥↓` |
| Top-left / top-right quarter | `⌃⌥U` / `⌃⌥I` |
| Bottom-left / bottom-right quarter | `⌃⌥J` / `⌃⌥K` |
| Center → full screen → golden (cycle) | `⌃⌥↩` |
| Center | `⌃⌥C` |
| Golden ratio | `⌃⌥P` |
| Toggle full screen | `⌃⌥F` |
| Minimize | `⌃⌥M` |

**The arrow keys walk a ladder.** `⌃⌥←`/`→` step the window horizontally and
`⌃⌥↑`/`↓` vertically through the golden/half/full positions. Horizontal steps
change only the width and x, vertical steps only the height and y, so a window
can be resized inside a corner without touching its other dimension. Each press
applies one position directly, and the focus border follows it immediately. Past the
horizontal ends, another press moves the window to the nearest display in that
direction when one is connected. Once the window reaches minimum height, another
up/down press moves it to the nearest display above/below. If there is no display
in the requested direction, the ladder keeps its previous edge behavior; past
the bottom it minimizes the window. On the destination display the window uses
the smallest width or height for the edge where it enters.

**Drag to snap.** Hold the snap key while dragging a window (⌥ by default) and
an overlay previews the frame the window will take. It snaps to the same
half/golden positions the keyboard uses. Choose the combination, or turn the gesture
off, in **Settings ▸ Windows** (Placement): six combinations are offered, with
⌥ as the default. Control is not offered because `⌃`-click is macOS's secondary
click.

The mini-map shows connected displays in their relative positions and sizes.
Window boxes use solid outlines and translucent fills; the focused window has a
more opaque fill and the theme accent around it. In the switcher, the selected
window card also highlights its matching box in the mini-map, and its title is
shown below the display overview.

**macOS tiling.** macOS also tiles a window dragged with ⌥. Settings ▸ Windows
detects that system switch and lets you turn it off so only MakiDesk reacts, or
leave both on if you prefer. The macOS option lives in System Settings ▸ Desktop
& Dock ▸ Windows.

The **gap** setting (Settings ▸ Windows) is the space kept between tiled
windows and at the screen edges. Layout commands act on the windows in view on
the main screen; a window's own shortcuts follow the screen it is on. macOS
does not let an app move a window to another Space, so MakiDesk never pretends
to.

## Focus border

MakiDesk can outline the focused window in the theme accent, so the window
receiving your keys is obvious even when several windows look alike.

- **Settings ▸ Windows ▸ Focus border** turns it on or off and sets its width
  (1–8 pt). The **Window** menu has the same on/off switch.
- The border follows the window while it is moved or resized, and covers
  MakiDesk's own windows too: Settings, Notes, Clipboard, Shelf and Keyboard
  Shortcuts. Transient overlays such as the switcher keep their own look.
- It is hidden for full-screen windows, when the desktop is focused, and for
  windows that cannot take keyboard focus.
- It uses the Accessibility permission only; no extra grant is needed.

## Layouts

With three or more windows in view, MakiDesk can lay them out as a set:

| Layout | Shortcut | What it does |
|---|---|---|
| Grid | `⌃⌥G` | Equal cells. |
| Golden spiral | `⌃⌥S` | A lead window in the widest slot, the rest around it. |
| Suggested | `⌃⌥A` | The advisor chooses grid or spiral from the number of windows, the content measure, the kind of app and the window sizes, and says why. |
| Content-weighted | `⌃⌥W` | A squarified treemap whose areas follow each window's weight. |

The same commands are in the menu **Layout**, and as **Tile / Golden / Content /
Auto** buttons in the window switcher. When windows are ticked in the switcher,
the command applies only to those; otherwise it applies to every window in view.
The **selected windows** variants are in the menu.

**Suggested layout.** Settings ▸ Layouts has *Ask before using the suggested
layout*. With it on, `⌃⌥A` shows the advice and its reason and waits; running it
again (or applying it from the menu) accepts. With it off, it applies at once.
Without Screen Recording there is no content measure and the advisor falls back
to a grid.

**Content-weighted layout.** Each weight is
`prior(app kind) × clamp(0.7 + 0.6 × score / median, 0.5…2.0)`, where the score
is the same edge-energy measure used for the golden spiral and the median is
over the measured windows. A window that could not be measured keeps factor 1,
so without Screen Recording the layout follows the priors alone. The priors are
the seven sliders in Settings ▸ Layouts: editor, terminal, browser, chat,
document, video and other (0.5–2.0). The command needs at least three windows;
it says so in the HUD below that.

The advisor proposes Content only when at least one window is measured and the
spread is clear: the busiest window has twice the score of the runner-up, or
the heaviest weight is 1.6× the lightest. It never proposes Content for two
windows or without a measurement.

## Window switcher and search

| Action | Shortcut |
|---|---|
| Switcher (browse) | `⌥⇥` |
| Switcher backwards | `⌥⇧⇥` |
| Search | `⌥Space` |

The switcher is a grid of **live previews** of every window, with a groups
column on the left. Automatic columns follow the window count in the compact
panel. The full-screen layout uses the same card sizing and adds as many columns
as the display has room for (up to 8), so a wide screen shows more cards instead
of a small grid in the middle; cards never get smaller than in the compact
switcher, and a larger maximum card size can make them bigger. A fixed column
count is always honoured, and maximum card size still caps how large a card may
get.

- Move with the arrows; **release ⌥** or press `↩` to open the highlighted
  window. `Esc` closes (if a group is being edited, it leaves the group first).
- **Space** turns the switcher into a search with the text field focused. Type
  to filter; `↩` opens the highlighted result.
- **⌘1…9** picks a group from the column; clicking a group does the same and
  ticks its members. **⌥1…9** adds or removes the highlighted card from the
  group being edited. With a group selected, **Return** recalls it (`⌘↩` while
  searching).
- With a group being edited, clicking a card toggles it too. The footer's
  **Tile / Golden / Content / Auto** buttons act on the ticked windows (all in
  view when none is ticked).
- While browsing, `⌥Q` closes the highlighted window, `⌥⇧Q` quits its app
  (unforced, so save prompts appear) and `⌥M` minimizes it. **⌫** resets the
  selected group, with a confirming second press.
- Picking a minimized or off-screen window brings it back on screen.

Settings ▸ Panels controls the switcher: live previews, per-app colours, the
theme, columns (Automatic or 2–8), maximum card size, opacity and the full-screen
layout. Previews need **Screen Recording**; without it the cards fall back to
app icons. The full-screen switcher uses the same `⌥⇥` / `⌥Space` keys.

## Groups

A group is a saved set of windows. It remembers the arrangement you gave its
windows — it does not invent a layout.

| Action | Shortcut |
|---|---|
| Recall group 1…9 | `⌃⌥1…9` |
| Add / remove the front window from group 1…9 | `⌃⌥⌘1…9` |

Recalling a group brings its members back where they were and puts the windows
outside the group away (a hidden app, or a minimized window). The **Groups**
menu has the same commands plus *Leave Group*, *Rename*, *Empty Group* and the
flat recall list. The switcher's groups column edits the same groups.

The arrangement a group restores is the last arrangement its windows had — move
them by hand or run a layout while the group is on screen and that is what comes
back. Groups are stored locally in `groups.json`; they are not shared or uploaded.

## Focus

Focus keeps only the windows in use and puts the rest away:

| Action | Shortcut |
|---|---|
| Send the front window away | `⌃⌥V` |
| Everything back | `⌃⌥⇧A` |
| Undo one step | `⌃⌥Z` |

**Focus Selected Windows** is in the menu: it uses the windows last selected in
the switcher. What leaves the screen is per window and always reversible; the
*Everything back* command restores the whole scene. The Focus menu shows what is
currently in use.

## Peek

Designate one window and hold a key to see it while you work:

| Action | Shortcut |
|---|---|
| Designate / undesignate the front window | `⌃⌥⌘P` |
| Peek while held | `hold ⌃⌥H` |

Designating puts the window away (the app hidden, or the window minimized) and
`⌃⌥H` shows a live overlay until you release. If the window is already on
screen, the HUD says so; if it was closed, the last in-memory image is shown as
*no longer open*. The **Peek** menu clears the designation. Nothing about the
peek is written to disk.

## Notes

`⌥N` opens the notes panel. It is a plain-text scratchpad that keeps your work
even when you never save it to a file.

- **The sidebar is the only list.** It shows every note with a search field.
  The current note has an accent tint and a left bar; a file with unsaved
  changes shows an orange dot that becomes the close × on hover.
- **The toolbar** has New, Open, Save, Save As, Reveal, Close, Float, Left and
  Right. **Drafts** are written automatically; an external file is always a
  draft until you press `⌘S` (Save As is `⇧⌘S`). Close a note with × or `⌘W`:
  a draft goes to the Trash, an external file is left untouched, and a file
  with unsaved changes (or a missing file) asks first.
- **Find** `⌘F`, new `⌘T`, open `⌘O`, switch with `⌘1…9`, change the font with
  `⌘+` / `⌘−`.
- **Languages**: Plain Text, Swift, JSON, Markdown, Shell, Python, JavaScript,
  TypeScript, HTML and CSS. The language popup in the status bar changes it. An unknown
  file opens as plain text, never as an error.
- **Anchoring**: the Float, Left and Right buttons set it. An anchored panel fills
  the screen height on that edge and cannot be moved until you choose Float;
  it stays anchored on the next launch.
- **External files** opened as drafts survive a restart; if the file moves or
  disappears, the draft stays and is marked *Not available* / *file missing*.
- Notes and drafts live in `~/Library/Application Support/MakiDesk/Note/`.
  The factory reset has a **Notes** tick that removes them.

## Clipboard history

`⌥V` opens a list of the last texts you copied. It is **in memory only** and
disappears when MakiDesk quits.

- Up/Down, Page Up/Down and Home/End move the selection; `↩` or a click pastes
  the selected text into the app you were using. `Esc` closes.
- **To Shelf** sends the selected text to the shelf (also in the row's context
  menu); **Clear** empties the history.
- The history keeps at most 50 distinct texts, newest first, and skips the
  copy's private/concealed types. **Secure input** (password fields) is never
  recorded, and the panel does not open while secure input is active.
- Pasting into another app uses Accessibility and a synthetic `⌘V`. Without the
  permission the text is still put on the clipboard and a HUD tells you.

## Shelf

`⌃⌥D` opens a temporary shelf near the pointer; **shake while dragging** opens
it too (Settings ▸ Panels). It holds files, folders, links, text and images:

- Drop items onto it. File promises from Photos, Safari and Mail are received
  as real temporary files. Each row shows an icon or image thumbnail, a name and
  a detail; × removes it, Delete removes the selection, the header clears all.
- **Quick Look** with `Space` or a double-click (files and links directly; text
  and images through a readable temporary preview).
- **Drag all out** (the handle) or drag a row/selection into Finder or any app.
  A selected row can be dragged alone; `⌘A` selects every item. Dragging a file
  lets the destination move it — Finder moves the original on the same volume
  and the row leaves the shelf; hold Option (or drag to another volume) to copy
  it and keep the row. Text, links and images are always copied.
- **Save…** and the context menu copy or move everything to a folder. Text
  becomes a `.txt`, an image a `.png`, a link a `.webloc`; files keep their
  names, with a numeric suffix if needed.
- **To Notes** inserts the selected text into the open note at the cursor.
- A file that moved or disappeared while on the shelf shows **Not available**
  and is skipped when you drag.
- The shelf is temporary: closing it (Esc, ×, `⌃⌥D`) empties it and removes the
  staging folder. With `⌃⌥D` it takes the keyboard; a shake opens it without
  stealing focus, and a second shake moves the open shelf to the pointer.

Settings ▸ Panels has the shake switch, sensitivity (low/medium/high) and
excluded bundle IDs. If you had a shelf opened by a shake and the drag ends
without a drop, it closes itself; a shelf opened with `⌃⌥D` stays until you
close it.

## Settings

The Settings window is split into tabs:

- **General** — permissions, build, animations, keyboard shortcuts, licensing,
  reset and finish setup.
- **Windows** — gap, drag-to-snap key, macOS tiling, focus border, overlay.
- **Layouts** — suggested layout behaviour and the seven content weights.
- **Panels** — shelf shake settings and the window switcher/search appearance.
- **Groups** — rename, empty and inspect the nine groups.

The selected tab is remembered. The window is painted with the selected
palette theme — background, cards, accent and a matching light or dark
appearance for the native controls — and takes keyboard focus when it opens.
**Reset to defaults** asks whether groups,
notes and clipboard history should go too; settings always reset.

## Keyboard shortcuts

The full list is in the **Keyboard Shortcuts…** window (menu or Settings ▸
General): 58 commands in groups, searchable by name or key, with the current
theme. The main global keys:

| Area | Shortcuts |
|---|---|
| Window | `⌃⌥← → ↑ ↓`, `⌃⌥U I J K`, `⌃⌥↩`, `⌃⌥C`, `⌃⌥P`, `⌃⌥F`, `⌃⌥M` |
| Layouts | `⌃⌥G`, `⌃⌥S`, `⌃⌥A`, `⌃⌥W` |
| Panels | `⌥⇥`, `⌥⇧⇥`, `⌥Space`, `⌥N`, `⌥V`, `⌃⌥D` |
| Groups | `⌃⌥1…9`, `⌃⌥⌘1…9` |
| Focus | `⌃⌥V`, `⌃⌥⇧A`, `⌃⌥Z` |
| Peek | `⌃⌥⌘P`, hold `⌃⌥H` |

Pressing `⌥⇥` / `⌥Space` shows the switcher even if MakiDesk is not the active
app. The palette's own keys are listed in the same window (arrows, `↩`, Space,
`Esc`, `⌘1…9`, `⌥1…9`, `⌥Q`, `⌥⇧Q`, `⌥M`, `⌫`).

## Troubleshooting

**Accessibility is required after a rebuild.** macOS ties the permission to the
app's code identity. Build and sign with `task open` (stable local identity) and
re-add MakiDesk if the entry is stale. `task reset-permission` clears the old
entry. See [Development](DEVELOPMENT.md).

**No live previews.** Grant **Screen Recording** in System Settings. Without it
the switcher shows app icons and the content-weighted layout uses the priors
only; everything else works.

**A shortcut does nothing.** Another app may own it; Settings ▸ General shows
the count. Quit the other app or change its shortcut.

**A window refuses to resize.** Some apps (panels, dialogs, some Electron apps)
do not expose a writable frame; MakiDesk reports it in the status line/HUD
instead of leaving a hole. Note and Safari are retried specially.

**A window is on another Space.** macOS does not provide a public API to move a
window between Spaces. MakiDesk only moves windows on the current desktop.

**Where is my data?** Notes in `~/Library/Application Support/MakiDesk/Note/`;
groups in `groups.json` in the same Support folder; clipboard and shelf are
memory/temporary. The reset sheet can remove them.

**Uninstall.** Quit MakiDesk, drag it to the Trash, then remove
`~/Library/Application Support/MakiDesk/` if you do not want the data. Revoke
the permissions in System Settings.
