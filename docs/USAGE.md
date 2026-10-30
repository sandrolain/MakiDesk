# MakiDesk — usage guide

MakiDesk is a menu-bar app that works on the windows you already have. There is
no separate canvas and no fake desktop: every command moves a real macOS window
through Accessibility.

- [Getting started](#getting-started)
- [Window tiling](#window-tiling)
- [Focus border](#focus-border)
- [Focus dim](#focus-dim)
- [Layouts](#layouts)
- [Window switcher and search](#window-switcher-and-search)
- [Groups](#groups)
- [Focus](#focus)
- [Peek](#peek)
- [Notes](#notes)
- [Checklist](#checklist)
- [Timers](#timers)
- [Application launcher](#application-launcher)
- [Command box](#command-box)
- [Clipboard history](#clipboard-history)
- [Shelf](#shelf)
- [Dropzones](#dropzones)
- [Screenshots](#screenshots)
- [Annotated screenshots](#annotated-screenshots)
- [Text from the screen](#text-from-the-screen)
- [Colour picker](#colour-picker)
- [Measure](#measure)
- [Notifications](#notifications)
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

Windows opened by a shortcut or the menu — Notes, Screenshots, Keyboard
Shortcuts, Notification History — appear on the display where the focused
window is. If they were last used on another display, they open centered on
the active one; otherwise they keep their last position.

The permissions are standard macOS TCC permissions: MakiDesk cannot grant them
itself, and you can revoke them at any time in **System Settings ▸ Privacy &
Security**. The app is not sandboxed; see [Privacy](PRIVACY.md).

If a shortcut is taken by another app, Settings ▸ General shows how many were
registered and how many were blocked. Record a different combination in
**Keyboard Shortcuts…** (or close the other app); MakiDesk cannot override it.

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
shown below the display overview. If the checklist card already sits in the
corner the mini-map would use, the map steps below it (or above, in a lower
corner) with a small margin, and only moves beside it when there is no room
that way.

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

## Focus dim

Where the border marks the window, the focus dim takes the rest of the screen
away: a dark veil covers everything stacked **below** the focused window, which
itself and everything above it stay clear. Off by default.

- `⌃⌥⇧D` toggles it; the **Window** menu has the same switch. **Settings ▸
  Windows ▸ Focus dim** sets opacity (10–80%), fade, colour, what stays sharp
  (the focused window, the whole app, or a set of **selected windows**), whether
  every display is lit or only the active one, whether clicking the desktop dims
  everything, and whether switching apps ends it.
- Nothing is measured per window: the veil is a full-display panel ordered under
  the target, so moving or resizing it needs no update. Menu bar, Dock and
  MakiDesk's own panels sit at higher levels and stay bright; the veil is left
  out of screenshots, recordings and screen sharing.
- **Selected windows**: open the switcher (`⌥Tab`) and **⌥-click** each window
  that must stay sharp — or move with the arrows and press **⌥K**. Every pick
  gets an eye badge and the veil behind the palette follows at once, so the
  palette stays open until you have the set you want. Then choose *Selected
  windows* under **Keep sharp**; if the veil is already up, the first pick
  switches it for you. No group and no layout command is involved.
  When the switcher closes, the picked windows are brought forward — macOS only
  lets a background window come on top by activating its app, so the apps are
  activated in reverse pick order and the first pick ends in front, with the
  keyboard on it. If instead you activate a window from the switcher, that
  window keeps the keyboard: the set is brought forward first and the window you
  chose goes above it, so the set stays sharp right under the window you are
  using. The veil then sits under the lowest of them on each display,
  so the whole set stays clear and everything below it is dimmed. Moving or
  resizing a picked window needs no update: it stays above the veil. The set is
  brought forward once per pick, not again when you later choose another app.
  It lives for the session: a minimised window is skipped while it sits in the
  Dock and rejoins the set when it comes back, a closed one drops out, and when
  nothing is left the veil comes down. In *Only the active display*, only the
  first window you picked stays lit and the other displays go fully dark.
- A full-screen window covers the veil, so the effect is simply absent there.
  Reduce Transparency turns the veil solid; Reduce Motion removes the fade.
- It needs Accessibility to know the focused window, and falls back to the
  frontmost app's topmost window when it is unavailable. No Screen Recording
  permission is involved.

## Layouts

With three or more windows in view, MakiDesk can lay them out as a set:

| Layout | Shortcut | What it does |
|---|---|---|
| Grid | `⌃⌥G` | Equal cells. |
| Golden spiral | `⌃⌥S` | A lead window in the widest slot, the rest around it. |
| Suggested | `⌃⌥A` | The advisor chooses grid or spiral from the number of windows, the content measure, the kind of app and the window sizes, and says why. |
| Content-weighted | `⌃⌥W` | A squarified treemap whose areas follow each window's weight. |

The same commands are in the menu **Layout** and in the **Actions** column on
the right of the window switcher — **Tile / Golden / Content / Auto / Focus**.
When windows are ticked in the switcher, the command applies only to those;
otherwise it applies to every window in view. The **selected windows** variants
are in the menu.

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
column on the left (hide it in Settings ▸ Panels). Each card puts the preview on
top and, underneath, the app's icon beside the window title and the app name,
with the name a little larger than the title. Automatic columns follow the
window count in the compact panel. The full-screen layout uses the same card
sizing and adds as many columns as the display has room for (up to 8), so a wide
screen shows more cards instead of a small grid in the middle; cards never get
smaller than in the compact switcher, and a larger maximum card size can make
them bigger. A fixed column count is always honoured, and maximum card size
still caps how large a card may get.

- Move with the arrows; **release ⌥** or press `↩` to open the highlighted
  window. `Esc` closes (if a group is being edited, it leaves the group first).
- **Space** turns the switcher into a search with the text field focused. Type
  to filter; `↩` opens the highlighted result.
- **Search also finds applications.** The same text filters the `.app` bundles
  installed in `/Applications`, `/System/Applications` and `~/Applications`.
  Matches appear in an **Applications** shelf between the field and the windows,
  with the app icon, its name and the executable name. `↑` from the first window
  row steps into the shelf, `←`/`→` choose an app, `↩` or a click launches it, and
  `↓` returns to the windows. When no window matches, the first application is
  selected already, so `↩` launches it. The inventory is read locally, kept in
  memory and refreshed after a couple of minutes; nothing about it is stored.
- **⌘1…9** picks a group from the column; clicking a group does the same and
  ticks its members. **⌥1…9** adds or removes the highlighted card from the
  group being edited. With a group selected, **Return** recalls it (`⌘↩` while
  searching).
- The **Actions** column on the right lists the keys of the current mode and
  the layout buttons; with a group being edited they act on the ticked windows
  (all in view when none is ticked). Its width never changes, so switching
  between browsing, searching and choosing an application does not move the
  grid; on a screen too narrow for the words it becomes a strip of icons and
  the words move to the tooltips.
- While browsing, `⌥Q` closes the highlighted window, `⌥⇧Q` quits its app
  (unforced, so save prompts appear) and `⌥M` minimizes it. **⌫** resets the
  selected group, with a confirming second press.
- Picking a minimized or off-screen window brings it back on screen.

Settings ▸ Panels controls the switcher: live previews, per-app colours, the
theme, columns (Automatic or 2–8), maximum card size, opacity and the full-screen
layout. **Size follows the number of windows** makes the previews larger when
few windows are open: one window takes the whole maximum, two a little less, and
from nine windows on about 70% of it. The count is the windows open when the
switcher opens, not the search filter, so typing does not resize the panel; the
profile never goes above the maximum or below 80 pt, and a fixed column count
still decides the grid. Previews need **Screen Recording**; without it the cards
fall back to app icons. The full-screen switcher uses the same `⌥⇥` / `⌥Space`
keys.

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
flat recall list. The switcher's groups column edits the same groups: click a
group to tick its members, `⌘1…9` picks one, `⌥1…9` adds or removes the
highlighted card.

If you do not use groups, **Settings ▸ Panels ▸ Window switcher** turns the
column off: the palette narrows to the cards, the badges on the thumbnails go
with it, and the informative notices (added, removed, recalled, left, cleared)
fall silent. A group that is empty, or whose windows are gone, is still reported
when you ask for it, and `⌃⌥1…9`, `⌃⌥⌘1…9` and the menu keep working. The same
section can hide just the groups with no windows while keeping the column.

The arrangement a group restores is the last arrangement its windows had — move
them by hand or run a layout while the group is on screen and that is what comes
back. Groups are stored locally in `groups.json`; they are not shared or uploaded.

## Focus

Focus keeps only the windows in use and puts the rest away:

| Action | Shortcut |
|---|---|
| Send the front window away | `⌃⌥⇧V` |
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

## Checklist

`⌃⌥L` shows or hides a small card with the things you mean to do. It stays over
the other apps, in the corner chosen in **Settings ▸ Panels** (top right by
default), at the same distance from the edges as a tiled window — half the
**Gap** in Settings ▸ Windows — and at the opacity you set (30–100%). That
opacity is the **resting**
value: pointing at the card or typing in it brings it to 100% until the pointer
leaves, so it can stay faint in the corner and become readable the moment you
use it.

- Type an item and press Return; click the circle to tick it (the text gets a
  line through), the arrows to move it and the ✕ to delete it. **Clear
  completed** takes every ticked item away. Items hold up to 200 characters and
  keep the line breaks you type; the list stops at 50.
- Ticking does not take the keyboard from the app you are in: the card only
  takes the keys when you click the add field, and `Esc` gives them straight
  back. The card is as big as its content — height follows the list — and
  nothing outside it is covered, so clicks on the app under it still reach the
  app.
- The mini-map keeps out of the card's way: when both belong in the same
  corner, the map appears below the card instead of on top of it.
- The items are written to `~/Library/Application Support/MakiDesk/checklist.json`
  after each change and come back on the next launch; a factory reset leaves
  them alone while the card's settings go back to their defaults. The card is
  left out of screenshots and recordings, and Reduce Transparency makes it
  solid.

## Timers

`⌃⌥⇧T` or the **Timers** menu starts a countdown. The menu has 1, 5, 10 and 25
minutes one click away; the field takes anything else:

| Input | Means |
|---|---|
| `25` or `25m` | 25 minutes |
| `1h 30m`, `90s`, `2m 30s` | A length, with its unit or as words (`1 hour 30 minutes`) |
| `8:30` | The **next** half past eight — today if it is still ahead, tomorrow otherwise |
| `fino a 8:30`, `until 8:30` | The same, said out loud |

A colon always means a **time of day**: `1:30` is half past one at night, not
ninety minutes. A length written with a colon is refused instead of guessed.

The card also has an optional **label** — *Tea*, *Focus*, *Stand up* — which the
card and the menu show instead of the length. Leave it empty and the timer is
named after what it is (`25m`, `8:30`).

- Several timers run at once, nearest first on the card. The **Timers** menu
  lists them by label with Pause/Resume and Delete; the remaining time is on the
  card, so the menu keeps still while it is open.
- The card sits in the corner chosen in **Settings ▸ Panels ▸ Timers**, on the
  same edge margin as a tiled window, above the other apps and clear of the
  checklist. It is not clickable: bringing the pointer near makes it fade away,
  and it comes back once the pointer is well clear of it, so it never covers
  what you are reading. Pause, resume and delete from the timers menu.
- When a timer runs out it posts a notice that stays until you click it away,
  even if the card was hidden, and plays a system sound. The notice offers **5
  more minutes** as a one-click action. **Settings ▸ Panels ▸
  Timers** chooses the sound (Glass by default, *Try* to hear it) or turns it
  off; the Mac's own volume and mute still apply.
- The count is read from the deadline, not from a count of ticks: sleeping,
  changing the hour or the time zone cannot make it drift, and a timer whose
  time passed while the Mac slept is over when it wakes.
- Timers live for the session only — nothing is written to disk and nothing
  survives a restart, because a timer that runs out while MakiDesk is closed
  could not announce itself.

## Application launcher

`⌃⌥Space` (or **Open an Application…** in the menu) is the fast app launcher: a
field, the installed applications, and nothing else. It is not the window
switcher — there are no thumbnails, and every key belongs to opening an app.

- The field starts on the applications opened most recently from here, then the
  rest of the installed ones in alphabetical order.
- Typing matches the **name first** (exact, then prefix, then a word), then the
  executable and the bundle id; recent use breaks ties inside a match of the same
  quality, so it never lifts a worse match over a better one.
- `↑`/`↓` choose, **Return** opens (or brings an already running app forward),
  **`⌘`Return** asks for a **new instance**, `Esc` closes. A click on a row opens
  it without another key.
- The scan covers `/Applications`, `/System/Applications` and `~/Applications`
  and runs off the main thread; no Accessibility or Screen Recording is needed.
- Applications that only allow one instance ignore `⌘`Return and simply come to
  the front. What the launcher remembers is only the order of that empty field:
  one entry per app, the 80 most recent.

## Command box

`⌃Space` (or **Run a Command…** in the menu) opens a field where a command is
written in words. It is the menu and the shortcuts, typed:

| What you type | What it does |
|---|---|
| `tile left`, `tile right`, `tile top`, `tile bottom` | The front window on that half |
| `tile top left`, `tile bottom right`, … | The four quarters |
| `center`, `golden`, `full screen`, `minimize` | The same actions as the keys |
| `layout grid` / `spiral` / `suggested` / `content` | Lay out every window in view |
| `group 3`, `add group 3` | Recall a group, or put the front window in it |
| `leave group`, `everything back`, `undo`, `focus selection` | The focus commands |
| `notes`, `clipboard`, `shelf`, `switcher`, `search`, `checklist` | Open a panel |
| `settings`, `shortcuts`, `screenshots`, `screenshot`, `ocr`, `measure`, `colour` | The app commands |
| `minimap`, `focus border`, `focus dim`, `peek`, `clear peek` | Presentation |
| `timer 25m`, `timer 8:30` | Start a timer with the same syntax as the timer field |
| `dismiss notices` | Take every notice away |

- The list under the field filters as you type; `↑`/`↓` choose, **Tab** completes
  the phrase (and leaves a space for its argument), **Return** runs, `Esc` closes.
  A click on a row with no argument runs it at once; one that needs an argument
  completes the field instead.
- A phrase that takes no argument refuses one, and a wrong argument says what was
  expected: the box stays open with the reason instead of running something else.
- Every row is one of the commands already in the menu, so the two cannot drift.
- A command acts on the app you were in, not on the box: it closes first, gives
  the keys back and only then runs, so `tile right` moves the window the
  shortcut would have moved. That is also why nothing happens while the field is
  still open.
- macOS also gives `⌃Space` to the input source: if that takes the combination,
  the keyboard-shortcut window (or Settings ▸ General) shows it as blocked and
  **Keyboard Shortcuts…** records another one for the command box.

## Clipboard history

`⌥V` opens a list of the last texts you copied. It is **in memory only** and
disappears when MakiDesk quits.

- Up/Down, Page Up/Down and Home/End move the selection; `↩` or a click pastes
  the selected text into the app you were using. `Esc` closes.
- **To Shelf** sends the selected text to the shelf (also in the row's context
  menu); **Clear** empties the history.
- A row shows a small preview of what it holds: a **colour swatch** when the
  text is a colour (`#RRGGBB`, `rgb()`, `hsl()`…), an image **thumbnail** when it
  is a local path or `file://` URL to an image, the text icon otherwise. Remote
  links are not fetched.
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
  it and keep the row. Text, links and images are always copied. When the last
  item leaves that way the shelf closes by itself, without taking the focus back
  from where you dropped it.
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

## Dropzones

A dropzone is a command you write, run on what you drop on its tile. The strip
appears under the shelf when the drag reaches it, already filtered to the zones
that accept the current items — incompatible zones are not shown at all (if none
match, the strip says so). Releasing outside a visible tile cancels the drop.
Dropping on a zone runs the command and does not keep the items on the shelf
unless the shelf was empty. Configure the zones in **Settings ▸ Dropzones** (or
**Dropzones…** in the menu).

- **Run without dragging.** Select items in the shelf and press `⌘D` (or the
  bolt button in the footer): the strip appears with the zones that accept the
  selection and the first one highlighted. `←`/`→` choose, `↩` runs, `↑` returns
  to the list, `Esc` closes the strip. The same zones are in the menu bar under
  **Dropzones**, each running on the selection; they are disabled when the shelf
  is closed, nothing is selected, or the file is read-only. Every tile is an
  accessibility element that reads its name and what it will receive.
- **Progress and Stop.** While a command runs, the shelf footer shows its name
  and elapsed seconds with a **Stop** button; stopping ends the whole process
  group, not just the wait. The result appears in a notice, or in the chosen
  destination below.
- **Where the output goes.** *Feedback ▸ Send the output to* chooses the notice
  (stdout excerpt), the clipboard, or the Shelf. Clipboard and Shelf receive the
  files the command produced (or stdout when it wrote none), and the run folder
  is kept because they point at those files.
- **Last run.** The detail view remembers the last run in memory: outcome, exit
  code, duration, the first stderr line and the declared output path. It is
  never written to disk.
- **No `sudo`.** A command whose first step asks for an administrator password
  is refused before a process starts; remove `sudo` to run it.

- **Name and icon.** The icon can be an SF Symbol chosen from a searchable
  preview list, an emoji chosen from a grid, or an image file copied into
  `Application Support/MakiDesk/DropzoneIcons/`.
- **What it accepts.** Files and folders, images (pixel data dragged from apps),
  text, links; optional UTIs such as `public.image` or `com.adobe.pdf`, a
  minimum/maximum item count, and whether a partly matching drop is refused or
  filtered to the matching items.
- **The command.** *Arguments* mode tokenizes the line and runs it without a
  shell: pipes and redirects are plain text. *Shell* mode runs it with
  `/bin/zsh -lc`; placeholders are quoted for you, and quotes around a
  placeholder are refused.
- **Presets.** *Presets…* offers starting points for files (Reveal in Finder,
  Open, ZIP next to the first file, Unzip, Terminal), images (PNG, JPEG, resize
  to 1600 px), the clipboard (copy paths, names or dropped text), and inspection
  (SHA-256, line count, paths, manifest). Applying one replaces the command line,
  the timeout and the output settings, leaves the accepted kinds and limits
  unchanged, and runs nothing. Image conversions allow 300 seconds instead of
  60. The ZIP preset writes `archive.zip` next to the first dropped file and asks
  before replacing it if it already exists.
- **Placeholders.** `{paths}`, `{path}`, `{parent}`, `{text}`, `{textfile}`,
  `{urls}`, `{urlsfile}`, `{manifest}`, `{workdir}`, `{outdir}`, `{name}`,
  `{count}`. `{parent}` is the folder containing the first dropped item, handy
  for writing output next to the source. `{paths}` and `{urls}` expand to one
  argument per item and must be a whole argument; unknown braces stay literal,
  so `awk '{print $1}'` and `jq '{title}'` work. *Preview Resolution* shows the
  final command with sample items.
- **Runtime.** Standard input can be nothing, the dropped text as a file, or
  the JSON manifest. Set a timeout, a working directory and `KEY=VALUE`
  environment variables; `MAKIDESK_*` variables describe the run.
- **Results.** Output goes to `output/` inside the run folder; a notice reports
  the exit code, stderr and a short stdout excerpt, and can reveal the folder.
  Each log file is capped at 256 MiB: a command that writes more is stopped and
  reported as such. When stdout is longer than the 64 KiB excerpt, the clipboard
  and the Shelf receive its log file rather than text cut mid-way.
  The run folder lives under `~/Library/Caches/MakiDesk/DropzoneRuns/` and is
  removed when the command ends unless you keep it, reveal it, or send the
  output to the clipboard or the Shelf (those point at its files). Stopping ends
  the process group MakiDesk started; an app it launched separately, or a
  Shortcut running inside Shortcuts, may keep running.
- **Existing output.** The optional *Check an output path before running* field
  (Runtime) makes the run ask **Run Anyway / Cancel** when that path already
  exists. The ZIP preset fills it with `{parent}/archive.zip`. MakiDesk can only
  guard the path you declare: a custom command that writes somewhere else is
  not intercepted, so for those use a shell `[ -e … ]` guard or a unique name.
- **Confirmation.** The first run, and the first run after the command, mode,
  stdin, environment or working directory changes, asks before executing.
  *Shortcuts…* only fills the line with `shortcuts run <UUID>` and an
  `--input-path` for the zone; it never runs anything by itself.
- *Test with a File…* saves valid changes and runs the command on a chosen file
  (or image) exactly like a drop. *Duplicate* makes a new zone that asks for
  confirmation again.

The zones live in `~/Library/Application Support/MakiDesk/dropzones.json`
(mode 0600). A symlinked or group-writable file is shown but never run; a file
written by a newer MakiDesk is read-only. **Reset to defaults** can delete the
dropzones with their own tick.

## Screenshots

Choose **Screenshots** in the menu-bar menu to open the screenshot library in a
floating window that stays above other windows. It follows the folder macOS
saves screenshots in (Desktop by default) and picks up a change made in System
Settings at the next launch. **Folder…** browses another directory and remembers
it; **Use System Folder** returns to following macOS. Captures are matched by
name and through Spotlight's screen-capture attribute, so renamed files stay
listed; when Spotlight has not indexed the folder, a hint says the list is
name-based and the list keeps working. The list refreshes when its contents
change.

Search by filename, click to select, Command-click to add or remove items, or
drag a selection rectangle from empty space across multiple cards. Clicking
empty space clears the selection. **Select All** and **Clear Selection** apply
to the current search results. Press **Space** or click **Preview** for Quick
Look; Space closes the preview, and Escape dismisses it. Double-click opens an
image in its default app; **Show in Finder** reveals it. Drag a card or a multi-selection to another
app or Finder: the destination can move the original file or copy it. Use
**Move…** to choose a folder, or **Move to Trash** to delete the selection
recoverably. If a destination already has the same name, MakiDesk adds a number
to the moved filename.

The segmented controls sort captures newest-first or oldest-first and group
them as one grid, by month, or by week. The thumbnail-size slider changes the
card size; sort order, grouping and size are remembered. Thumbnails are decoded
off the main thread and kept in a 32 MiB cache, released when the library
closes.

**Recognize Text** in the toolbar reads the selected screenshot without taking a
new capture — no Screen Recording beyond the file already on disk.

**Announce new screenshots** (Settings ▸ Panels ▸ Screenshot, off by default)
puts a notice on screen when macOS saves a capture with `⌘⇧3`, `⌘⇧4` or `⌘⇧5`:
the file name, **Shelf** and **Copy text**. It never takes the focus, stays
silent while a password field has the keyboard, and follows the library's
folder. The notice stays until you use one of its buttons or dismiss it.

**Videos** in the same toolbar also lists screen recordings (`.mov`, `.mp4`):
they get a film badge and their length, Quick Look plays them, and the same
move, trash and drag actions apply. It is off by default. If macOS has not
granted access to the folder (Desktop, Documents, external volumes), the empty
state explains it and offers **Open Privacy Settings**.

## Annotated screenshots

`⌃⌥⇧S`, or **Capture Area…** in the menu, opens the shared area selector — the
same snapping, loupe and `Esc` as text recognition — and then a small editor on
the capture:

| Tool | What it does |
|---|---|
| Arrow | Points at something: drag from the tail to the head. |
| Rectangle | Draws attention to a region without covering it. |
| Pen | Free hand. |
| Highlighter | A wide, translucent stroke that keeps what is under it readable. |
| Hide details | Replaces the region with a mosaic of its own pixels — for names, tokens, faces. |

- Four colours (red, yellow, blue, black). **⌘Z** undoes the last mark, `Esc`
  throws the capture away, **Return** saves.
- The result is a PNG on the **shelf**, ready to drag into a chat, a note or a
  folder. **Settings ▸ Panels ▸ Screenshot** also copies it to the clipboard.
  The file lives in the shelf's temporary folder and goes away with it.
- Annotations are made on the capture itself, at the selection's own size, and
  the saved image is rendered at the capture's pixel size, so a Retina capture
  stays sharp.
- It needs Screen Recording, like the previews; Accessibility is not involved.
- Window and whole-screen captures are drags over the selector (it snaps to
  window edges). **Video recording is not implemented.**

## Text from the screen

Press `⌃⌥O` and drag over the text you want. MakiDesk recognizes it locally with
Vision, copies the result to the clipboard and shows a short preview. `Esc`, or
a click without dragging, cancels without copying anything.

- The same reading is in the **Text & Color** menu without dragging: **from the
  window under the pointer**, **from the frontmost window** and **from the whole
  screen**. The first two read the window itself, so overlapping windows do not
  get in the way.
- A picture you already have needs no capture and no permission: **Recognize
  Text** is in a shelf row's context menu for an image (or an image file) and in
  the screenshot library's toolbar for the selected screenshot.
- The notice that reports the result also offers **Send to Note**, **Send to
  Shelf** and, when the text was not copied, **Copy** — so the text can go
  straight where it is needed.
- A **Reading text…** notice stays on screen while Vision works — a large area
  can take a couple of seconds — and goes away on its own when the result or the
  error arrives. It is excluded from screenshots and recordings, like every
  notice.
- The area is captured at native resolution; an image longer than 3000 px on
  one side is downscaled before recognition.
- **Settings ▸ Panels ▸ Text recognition** chooses where the text goes:
  **clipboard**, **clipboard and history** (the default, what used to happen by
  accident) or **history only**, which leaves the system pasteboard untouched.
  It also chooses whether the clipboard panel opens after recognizing: never
  (default), only when the text is not copied, or always. The panel never opens
  for a stale result or after you have switched to another app. The clipboard
  history lives in memory only, so “history only” keeps no copy after MakiDesk
  quits; the same section chooses fast or accurate recognition and language
  correction, and the language is detected automatically.
- Screen Recording is required by the sources that take a picture (area, window,
  screen). Reading a shelf image or a screenshot file needs no permission at
  all. The image is not written to disk and nothing is uploaded. The first use loads Vision's models (about
  100 MB), which stay in memory while MakiDesk runs.
- If no text is found, the clipboard is left untouched.

## Colour picker

Press `⌃⌥E`, move the loupe over the point you want and click. The loupe shows
a square with the colour under the pointer and its hex value; the click copies
that colour in the chosen format and the notice shows hex, RGB and alpha.
Point mode is a click, not a selection: dragging only moves the loupe, and a
rectangle is never drawn.

- **Settings ▸ Panels ▸ Colour picker** chooses the format copied: `#RRGGBB`,
  `#RRGGBBAA`, `rgb(r, g, b)`, `rgba(r, g, b, a)`, `hsl(h, s%, l%)`,
  `hsla(h, s%, l%, a)`, or an `NSColor` snippet for Swift.
- Values are converted to sRGB, so they match other colour tools; a display
  that is not colour-calibrated can still show a different colour from another
  one.
- Screen Recording is required, like OCR. The capture is read in memory and
  never written to disk. `Esc` cancels. With the clipboard history on, the
  colour is kept there like any other copy, and the row shows its swatch.

## Measure

Press `⌃⌥R` and drag over anything on screen. While you drag, the overlay shows
width × height, ΔX/ΔY, the diagonal, its angle and the area; releasing pins the
measurement in place with a small badge that copies the values or dismisses it.

- `⇧` keeps a square, `⌥` measures out from the centre (both can combine).
- Values snap within 6 pt to window and display edges **and centres**; the
  badge says which axis snapped. A dashed accent guide with a magnet dot shows
  the candidate as the pointer approaches it, before the drag, and stays on the
  snapped side while dragging. The other sides of the window that produced the
  snap are outlined faintly, so the whole window is readable.
- The snap is sticky: once a side catches an edge it stays there until the
  pointer pulls it about 10 pt away, which avoids flicker on the tolerance
  boundary. Only the sides you are dragging snap; the starting corner stays
  where you pressed.
- Pressing locks the guide that is visible: if the pointer is on a dashed line,
  the measurement starts exactly on that edge or centre, so the first movement
  cannot miss it.
- A measurement stays until its ✕ or **Measure ▸ Clear Measurements**; up to
  eight at once. Nothing is written to disk.
- **Settings ▸ Panels ▸ Measure** or **Measure ▸ Units** chooses points (exact),
  device pixels, or millimetres and inches estimated from the display's reported
  physical size.
- Geometry needs no permission. The loupe appears only when Screen Recording is
  granted; without it, measuring works the same.
- `Esc` cancels while dragging. The badge's **Copy** button puts the values on
  the clipboard (the clipboard history keeps them when it is on).

## Notifications

MakiDesk reports results with a small notice. Each one carries a state that
tints its icon and border: grey for information, the theme accent for a
confirmation, green for success, orange for a warning and red for an error.
Notices appear on the display and in the corner chosen in
**Settings ▸ Notifications**, and are excluded from screenshots and recordings.

- Up to two notices are visible at once; the rest wait in a queue, so two
  results in a row are both readable. Errors stay twice as long as
  confirmations (with a three-second floor); progress notices such as
  *Receiving files…* or *Transferring shelf items…* update in place and
  disappear when the work ends.
- **Sticky notices.** With *Keep errors until I dismiss them* on, an error has
  no timer and waits until you take it away: **click anywhere on the notice**
  (the ✕ in its corner only says so). **Dismiss All Notices** in the menu closes
  everything at once. Sticky notices sit in their own lane, so they never hold
  back the notices that close by themselves, and the newest three are kept. Off
  (the default), nothing changes: every notice closes after its duration.
- A notice can carry **actions**: the timer's *Time's up* offers **5 more
  minutes**, and using an action closes the notice.
- **Settings ▸ Notifications** sets placement (bottom or top, centre or right),
  the display (focused window or pointer), the base duration, the text size
  (the icon, padding and corners grow with it), compact mode, the VoiceOver
  announcement, sticky errors and whether to keep a history. One **Preview**
  button per state shows it with the current placement, size and theme; the
  error one follows the sticky option. With *Reduce Motion* on, notices appear
  without the short fade.
- **Notification History…** in the menu (or from Settings) lists the last 50
  notices. Search, press Return to copy the selected message, or Clear to empty
  the list. History lives **in memory only** and disappears when MakiDesk quits:
  messages can name windows, zones and paths.

## Settings

The Settings window has a **sidebar** on the left; the section you pick is
remembered for the next time, and opening **Dropzones…** from the menu goes
straight to that section. Pages that hold several groups of options — General,
Windows, Panels and Notifications — begin with a **strip of sub-sections**
(Permissions · Behaviour · About, Placement · Focus · Overlay · macOS, and so
on), so nothing is buried at the bottom of a long scroll. The sub-section is a
place inside the page, not a preference: reopening Settings starts at the
first one.

- **General** — permissions, build, animations, keyboard shortcuts, licensing,
  reset and finish setup.
- **Windows** — gap, drag-to-snap key, macOS tiling, focus border, overlay.
- **Layouts** — suggested layout behaviour and the seven content weights.
- **Panels** — shelf shake settings, the checklist card (visibility, opacity,
  width, corner and display), the countdown card (visibility, opacity, corner
  and display), the window switcher/search appearance (including the groups
  column and its announcements), the annotated screenshot's clipboard copy, the
  notice for screenshots macOS saves, and text recognition quality and
  correction.
- **Groups** — rename, empty and inspect the nine groups.
- **Dropzones** — the commands run by dropping on the shelf strip: accepted
  kinds, command and placeholders, runtime, feedback, and *Test*.

The window is a normal macOS window — its own title bar, with close, minimise and
zoom — and opens at 800 × 580 or larger, so nothing is clipped beside the
sidebar. The window is painted with the selected
palette theme — background, cards, accent and a matching light or dark
appearance for the native controls — and takes keyboard focus when it opens.
The theme accent also paints the text caret and the selection in every field of
the app, Notes included, instead of leaving them system blue.
**Reset to defaults** asks whether groups, notes, clipboard history and
dropzones should go too; settings always reset.

## Keyboard shortcuts

The full list is in the **Keyboard Shortcuts…** window (menu or Settings ▸
General), searchable by name or key, with the current theme. Two modifier
families keep it predictable: **`⌥` opens a panel** (`⌥⇥`, `⌥Space`, `⌥N`,
`⌥V`) and **`⌃⌥` acts on windows and the desktop** (`⌃⌥←`, `⌃⌥G`, `⌃⌥⇧V`,
`⌃⌥1…9`); `⇧` marks an alternate action. The main global keys:

| Area | Shortcuts |
|---|---|
| Window | `⌃⌥← → ↑ ↓`, `⌃⌥U I J K`, `⌃⌥↩`, `⌃⌥C`, `⌃⌥P`, `⌃⌥F`, `⌃⌥M` |
| Layouts | `⌃⌥G`, `⌃⌥S`, `⌃⌥A`, `⌃⌥W` |
| Panels | `⌥⇥`, `⌥⇧⇥`, `⌥Space`, `⌥N`, `⌥V`, `⌃⌥D`, `⌃⌥L` |
| Focus dim | `⌃⌥⇧D` |
| Timers | `⌃⌥⇧T` |
| Screenshots | `⌃⌥⇧S` |
| Application launcher | `⌃⌥Space` |
| Command box | `⌃Space` |
| Groups | `⌃⌥1…9`, `⌃⌥⌘1…9` |
| Focus | `⌃⌥⇧V`, `⌃⌥⇧A`, `⌃⌥Z` |
| Peek | `⌃⌥⌘P`, hold `⌃⌥H` |

Pressing `⌥⇥` / `⌥Space` shows the switcher even if MakiDesk is not the active
app. The palette's own keys are listed in the same window (arrows, `↑`/`↓` into
the Applications shelf, `↩`, Space, `Esc`, `⌘1…9`, `⌥1…9`, `⌥Q`, `⌥⇧Q`, `⌥M`,
`⌫`).

### Changing a shortcut

Click the key next to a global command (or its `⋯` menu ▸ **Record new
shortcut…**) and press the combination you want. **Esc** cancels, `⌫` turns the
command off without closing the window. A combination needs `⌃` or `⌥`: `⌘`
alone would take a standard shortcut from the front app, and `⇧` alone would
take ordinary typing.

MakiDesk refuses a combination that another command already uses and names the
row that owns it, and it refuses `⌃⌥H`, which is held for the peek. A row
another app owns is marked *In use by another app*: record a different
combination for it. On any refusal the previous shortcut stays in force.

The `⋯` menu also has **Turn off** and **Restore default**; the arrow on a
changed row restores that one, and **Restore all** at the top puts every
shortcut back. Changes take effect immediately and are stored in
`shortcuts.json` in the Application Support folder; a file that cannot be read
is set aside as `shortcuts.json.bak` and the defaults are used, so a bad file
never leaves the app without shortcuts.

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
groups in `groups.json` and remapped shortcuts in `shortcuts.json` in the same
Support folder; clipboard and shelf are memory/temporary. The reset sheet can
remove them.

**Uninstall.** Quit MakiDesk, drag it to the Trash, then remove
`~/Library/Application Support/MakiDesk/` if you do not want the data. Revoke
the permissions in System Settings.
