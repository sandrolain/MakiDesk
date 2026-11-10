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
- [Opening applications](#opening-applications)
- [Command box](#command-box)
- [Clipboard history](#clipboard-history)
- [Shelf](#shelf)
- [Dropzones](#dropzones)
- [Screenshots](#screenshots)
- [Annotated screenshots](#annotated-screenshots)
- [Text from the screen](#text-from-the-screen)
- [Colour picker](#colour-picker)
- [Measure](#measure)
- [Disk and CPU](#disk-and-cpu)
- [Ports](#ports)
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
Shortcuts, Notification History — appear on the active display. The cards that
stay on screen (checklist, countdowns, mini map) and the panels that open on
demand (switcher, search, notices) follow the **active display** too: the
monitor of the last window focus or pointer move, so moving to a display and
clicking or pointing there is enough to bring them along. If they were last
used on another display, they open centered on the active one; otherwise they
keep their last position.

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
| Whole height / whole width (both arrows held) | `⌃⌥↑`+`↓` / `⌃⌥←`+`→` |
| Top-left / top-right quarter | `⌃⌥U` / `⌃⌥I` |
| Bottom-left / bottom-right quarter | `⌃⌥J` / `⌃⌥K` |
| Center → full screen → golden (cycle) | `⌃⌥↩` |
| Center | `⌃⌥C` |
| Golden ratio | `⌃⌥P` |
| Toggle full screen | `⌃⌥F` |
| Minimize | `⌃⌥M` |

**Both arrows at once: the whole axis.** Hold `⌃⌥` and press `↑` and `↓`
together — the window takes the whole height of the screen and keeps its width
and horizontal position; `←` and `→` together do the same for the width, keeping
the height. The second arrow of the pair completes the chord: one arrow alone is
still the single step below. Remapping or turning off either arrow of a pair
turns its chord off, so no unexpected key can stretch a window.

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
each screen, one display at a time; a window's own shortcuts follow the screen
it is on. Unplugging a monitor rescues its windows to a remaining screen without
overwriting the group's layout; plugging it back restores the arrangement saved
for that display set. macOS does not let an app move a window to another Space,
so MakiDesk never pretends
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

- `⌃⌥⌘D` toggles it; the **Window** menu has the same switch. **Settings ▸
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

## Pointer effects

Two overlays MakiDesk draws itself, for finding the pointer and for showing it
to someone else. Neither asks for a permission: the pointer is read in memory
through the same global mouse events the utility bar already uses, and nothing
is captured, written or logged.

- `⌃⌥⇧P` — **Locate pointer**. Three rings expand from the pointer for about a
  second, on the display it is on, then disappear. It installs nothing that
  outlives the effect, and it works while MakiDesk is not the active app.
- `⌃⌥⇧X` — **Pointer effects**. The selected style follows the pointer for five
  minutes, or until the shortcut is pressed again; with **No time limit** on it
  stays on until you stop it. The **Window** menu has the same switch and a style
  submenu, a notice confirms it, and a timed presentation stops by itself at the
  deadline, so it cannot be left running by accident. A click leaves a ripple.
- **Settings ▸ Panels ▸ Pointer** chooses the presentation style: **Ring** (an
  accent-colour halo), **Ribbon** (a short tapered trail), **Particles** (small
  sparks, brighter while moving), **Orbit** (dots circling the pointer) or
  **Spotlight** (the screen dimmed around a clear circle). It also sets size
  (24–80 pt), intensity, pulse duration, presentation length (1–30 min, or no
  time limit), click ripple and whether capture apps that honour the window
  sharing type see the effect. Particles have their own count (10–160) and size
  (3–14 pt); orbit has a dot count (1–8) and dot size (3–16 pt). **Test pulse**
  previews the current size and intensity.
- The effect stays on the display the pointer is on; it is not carried across the
  gap between two screens. A resolution change rebuilds it, a sleep closes it,
  and the monitors exist only while the mode is on.
- The system pointer stays above every window and is never replaced: effects
  are drawn around it, not over it. Its size and colour remain the ones in
  macOS's Accessibility ▸ Display ▸ Pointer.
- Still captures taken by MakiDesk leave the effect out: the capture is made
  without the system cursor, and an effect alone would be a ghost. Recordings keep
  the cursor and the effect. The capture option above covers other pipelines
  only when they honour the window's sharing type; some recorders ignore it.
- Reduce Motion turns pulse and ripple into fades, shows a static ring instead
  of a moving ribbon or particles, and stops the orbit rotation. The spotlight
  remains a static dim with a clear circle.
- Off means off: with no presentation running, nothing samples the pointer and no
  monitor or timer exists.

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

Every layout is applied **per display**: windows stay on the display they are
on, and each display gets its own cells, spiral slots or treemap. The golden
spiral's six-slot cap is per display too. A window can still be moved to another
display with the arrow ladder, but a layout command never does it.

Layouts respect the size floor an app has already shown. A window that cannot
fit a cell is left where it is, and the rest are placed without it; the status
line says when some did not fit. The keyboard ladder stops at that floor instead
of asking for a size the app will refuse, and a half or quarter that is smaller
than the floor is still reported rather than silently shrunk.

A layout command reports once, after every window has answered: how many took
their frame, how many kept their size, and whether any frames overlap, come
closer than the gap or fall outside the display. A newer command replaces the
waiting verdict.

For a few seconds after a layout, if an app moves a window off its slot,
MakiDesk puts it back once. If the app does it again straight away, MakiDesk
stops and leaves the window alone instead of trading writes with the app. A
press, a drag, a display change or a new command ends that watch immediately.

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
- **The field also calculates.** An expression shows a `= …` chip before the
  applications: `12 * 3`, `15% of 80`, `12 cm in in`, `30 °C in °F`, `2 GB in
  MB`. `↑` from the windows reaches it (and it is selected already when nothing
  else matches), then `↩` copies the result, unit included. A `%` after a number
  is a percentage; `mod` is the remainder. Currency conversion is deliberately
  absent: exchange rates need the network, and MakiDesk does not use one.
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
| Send the front window away | `⌃⌥⌘V` |
| Everything back | `⌃⌥⌘A` |
| Undo one step | `⌃⌥⌘Z` |

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
- **Markdown without a model**: the Format button (or `⌘B` bold, `⌘I` italic,
  `⇧⌘K` code, `⌘K` link) wraps the selection or the word under the cursor and
  toggles it again. The menu adds bulleted, numbered and checkbox lists, quotes,
  indent/outdent, a code block closed with the note's own language, and a table
  whose columns are aligned on their content. Each command is one edit: `⌘Z`
  takes it back in one step.
- **Rewrite with Apple Intelligence** (macOS 26, on-device): the last section
  of the Format menu offers **Improve wording**, **Format as Markdown** and
  **Summarize** on the selection or the whole note. The proposal streams into a
  preview with **Apply**, **Copy** and **Cancel**: nothing is written until
  Apply, and Apply is one `⌘Z` away. The model fills a structure, the Markdown
  is written by the editor's own serializer. **Settings ▸ Panels ▸ Tools ▸ Notes
  rewriting** says whether the model is available and why.
- **Writing Tools** (macOS 15.1 and later) is the system's own, in the text's
  context menu: Proofread, Rewrite, Summarise and the rest. The note stays plain
  text, so the result is plain text; fenced code blocks are left alone; while the
  session runs the syntax colours and the automatic save wait, and the rewrite is
  a single `⌘Z` away. Nothing leaves the Mac and no prompt of ours is involved.
- **Languages**: Plain Text, Swift, JSON, Markdown, Shell, Python, JavaScript,
  TypeScript, HTML and CSS. The language popup in the status bar changes it. An unknown
  file opens as plain text, never as an error.
- **Anchoring**: the Float, Left and Right buttons set it. An anchored panel fills
  the screen height on that edge and cannot be moved until you choose Float;
  it stays anchored on the next launch.
- **External files** opened as drafts survive a restart; if the file moves or
  disappears, the draft stays and is marked *Not available* / *file missing*.
- **Text sent to Notes** from OCR or the shelf arrives as a **new note** and
  opens the panel; the note you were editing is left untouched, and empty text
  creates nothing. The clipboard panel's paste fallback still goes at the
  cursor, and a note restored at launch waits for its body instead of being
  overwritten.
- **Nothing is saved by asking.** A draft is written a fraction of a second
  after you stop typing, again when the panel loses focus or closes, and each
  write is flushed to the disk before it replaces the old copy: a crash or a
  sudden power cut costs at most the last keystroke. Closing a note writes its
  latest text to the Trash first, and a note whose file cannot be read stays in
  the list marked *Could not load note* instead of vanishing.
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

- Type an item and press Return; the add field appears only while the card has
  the keys, so the resting card keeps a single line of height. Click anywhere on
  the list to take the keys and open it. Click the circle to tick an item (the
  text gets a line through), drag the row itself to reorder it, and the ✕ on the
  row to delete it. When something is ticked, the trash appears in the add row
  and clears only the completed items. Items hold up to 200 characters and keep
  the line breaks you type; the list stops at 50.
- The text of an item can be copied from its right-click menu with **Copy
  Item**, or the whole list at once with **Copy All Items**. Dragging a row onto
  another moves it to that slot, and the same moves are in the row's context
  menu and in the VoiceOver actions.
- Ticking does not take the keyboard from the app you are in: clicking the list
  does, and `Esc` closes the card (or hides it with `⌃⌥L`, the menu or the
  toolbar). The keys go back to the app you came from. The card is as big as its
  content — height follows the list — and nothing outside it is covered, so
  clicks on the app under it still reach the app.
- The card follows the **active display**, like the countdown card, the mini map,
  the switcher and the search box: it opens on the monitor of the last window
  focus or pointer move and moves there when that changes. The corner in
  **Settings ▸ Panels** is kept on whichever display is active.
- The mini-map keeps out of the card's way: when both belong in the same
  corner, the map appears below the card instead of on top of it.
- The items are written to `~/Library/Application Support/MakiDesk/checklist.json`
  after each change and come back on the next launch; a factory reset leaves
  them alone while the card's settings go back to their defaults. The card is
  left out of screenshots and recordings, and Reduce Transparency makes it
  solid.

## Timers

`⌃⌥T` or the **Timers** menu starts a countdown. The menu has 1, 5, 10 and 25
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
  checklist. It follows the active display (the last window focus or pointer
  move), like the checklist and the mini map. It is not clickable: bringing the
  pointer near makes it fade away, and it comes back once the pointer is well
  clear of it, so it never covers what you are reading. Pause, resume and delete
  from the timers menu.
- When a timer runs out it posts a notice that stays until you click it away,
  even if the card was hidden, and plays a system sound. The notice offers **5
  more minutes** as a one-click action. **Settings ▸ Panels ▸
  Timers** chooses the sound (Glass by default, *Try* to hear it) or turns it
  off; the Mac's own volume and mute still apply.
- The count is read from the deadline, not from a count of ticks: sleeping,
  changing the hour or the time zone cannot make it drift, and a timer whose
  time passed while the Mac slept is over when it wakes.
- Timers survive a quit and a crash. They are kept in
  `~/Library/Application Support/MakiDesk/timers.json` as absolute deadlines: a
  running one carries on at the next launch with what is actually left — the
  time MakiDesk was closed is already subtracted — a paused one comes back
  paused with the same remainder, and one that ran out while the app was closed
  is announced once, with the moment it was due, so it is never silently lost.
  Deleting the last timer removes the file.

## Opening applications

The applications are in the **search palette** (`⌥Space`), in the shelf under
the field. There is no separate launcher window: the switcher already knows the
installed applications, and one panel with one key is easier to remember.

- The shelf starts on an empty field and shows the applications opened most
  recently from here, then the rest of the installed ones in alphabetical order.
- Typing matches the **name first** (exact, then prefix, then a word), then the
  executable and the bundle id; recent use breaks ties inside a match of the same
  quality, so it never lifts a worse match over a better one.
- `↑`/`↓` walk the shelf and the window grid as one column, **Return** opens (or
  brings an already running app forward), **`⌘`Return** asks for a **new
  instance**, `Esc` closes. A click on a row opens it without another key.
- The scan covers `/Applications`, `/System/Applications` and `~/Applications`
  and runs off the main thread; no Accessibility or Screen Recording is needed.
- Applications that only allow one instance ignore `⌘`Return and simply come to
  the front. What is remembered is only the order of that empty field: one entry
  per app, the 80 most recent.

## Command box

`⌃⌥R` (or **Run a Command…** in the menu) opens a field where a command is
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
| `settings`, `shortcuts`, `screenshots`, `screenshot`, `capture window`, `capture screen`, `record`, `ocr`, `measure`, `colour` | The app commands |
| `minimap`, `focus border`, `focus dim`, `peek`, `clear peek` | Presentation |
| `utility bar`, `bar show`, `bar hide`, `bar pin` | Open, close or pin the utility bar |
| `terminal`, `terminal quake` | Open the terminal or toggle its quake panel |
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
- The box used to be on `⌃Space`, which macOS gives to the input source when
  more than one language is enabled; it moved to `⌃⌥R` so it cannot be taken.

## Utility bar

A strip of commands and figures that comes down from the menu bar when you need
it, and leaves no room behind.

- **Opening it.** Rest the pointer on the menu bar for a quarter of a second.
  The whole menu bar is the trigger — fling the pointer to the top edge and it
  is already inside — and the bar drops down just below it. On a display without
  a menu bar the top edge works the same way. It stays while the pointer is on
  the bar or on the menu bar, and retreats when the pointer leaves or you click
  elsewhere. `⌃⌥B` opens it
  from the keyboard, and the same key closes it. The menu bar's **Utility Bar**
  item does the same, and the command box has `utility bar`, `bar show`,
  `bar hide` and `bar pin`.
- **What is on it.** On the left the everyday panels and tools — Notes,
  Clipboard, Shelf, Timer, the command box, the Terminal and its Quake, then
  screenshots, text from the screen, colour, measure and the Ports window. The Timer button carries the
  nearest running countdown as a badge, so one Timer is both the command and the
  figure. In the middle the presentation toggles — focus
  border, focus dim, mini map — lit in the accent while on. On the right the
  figures: free disk, CPU and the number of windows in the switcher. A click runs
  the same action as the shortcut and the menu.
- **The pin.** The pin on the right keeps the bar open. It lasts for the session:
  quitting MakiDesk clears it, and so does clicking it again. A pinned bar ignores
  clicks elsewhere and display changes — close it with the pin, `⌃⌥B` or the menu.
  The bar still takes no space from windows — it is drawn over the top of the
  screen, never reserved.
- **How it is drawn.** With the **System** theme the bar borrows the system
  material — Liquid Glass on macOS 26 and later — so it follows the desktop
  underneath. Every custom palette keeps its own solid colour. **Reduce
  Transparency** always gives a solid bar, and **Increase Contrast** strengthens
  its edge.
- **From the keyboard.** `⌃⌥B` gives the bar the keyboard and draws a
  selection; `→`/`←` (or `↑`/`↓`) move it, **Return** runs the choice, and
  **Esc** closes and gives the keyboard back.
- **When it does not fit.** Narrow displays show icons only; the words appear on
  wide ones, or when Settings says so. Anything that does not fit moves under
  the chevron, whose menu opens just below it. Untick the buttons you never use
  and everything fits.
- **Settings ▸ Panels ▸ Utility bar** turns the pointer reveal off, sets the
  height (28–64 pt, 46 by default), chooses whether the labels follow the
  display, are always shown or never shown, and lists every button with a tick.
  The pin and the Settings button always stay; the chevron appears when
  something does not fit. The buttons grow with
  the height, so a taller bar is easier to hit, not just more padded. With the
  reveal off, only `⌃⌥B`, the menu and the command box open it.
- **The buttons file.** Visibility and order also live in
  `~/Library/Application Support/MakiDesk/utility-bar.json`: each entry names a
  button id, says whether it is shown, and may set its own `title` and `symbol`.
  Order applies inside a zone — the three zones keep their places — unknown ids
  are ignored, and a new button appears on its own after an update. Edit it by
  hand and the bar reads it the next time it appears, or use **Reveal buttons
  file…** in Settings. A file that cannot be read is set aside as
  `utility-bar.json.bak` and the default buttons are used; one written by a newer
  MakiDesk is shown read-only. A factory reset deletes the file.
- The bar is left out of screenshots and recordings, takes no Accessibility
  permission of its own, and does nothing while it is hidden: the pointer is
  sampled only while the feature is on.

## Terminal

A real terminal lives beside MakiDesk rather than inside it. `⌃⌥O`, or **Terminal**
in the menu bar's menu, launches the embedded **MakiDesk Terminal** helper and
brings its window forward. The helper is a separate app: quitting MakiDesk leaves
it running, so its shells keep working.

- **Workspaces.** The sidebar lists them. **+** adds one, **−** closes the
  selected one, and the last one cannot be closed. `⌘T` adds a workspace too.
  The row currently on screen has an accent bar and a brighter title; a
  workspace with more than one pane shows how many at its right. Drag a row to
  reorder, or use `⌃⌘↑` / `⌃⌘↓`; the order is saved with the layout and the
  selected shell stays selected. `⌘1`…`⌘9` select a workspace
  directly, and `⌃⌘←` / `⌃⌘→` step to the previous or next one, wrapping at
  the ends.
- **Splits.** `⌘D` splits the focused pane side by side, `⇧⌘D` stacks a second
  one; `⌘W` closes the focused pane, or the whole workspace when it holds a
  single terminal, and hides the window when it is also the last workspace.
  `⇧⌘W` closes the workspace. Closing a pane or workspace with a running
  command asks first (SSH and tmux count as running); Cancel is the default.
  Every pane is a real shell
  with its own scrollback, copy/paste, links and Option-as-Meta. `⌘⌥←`, `⌘⌥→`,
  `⌘⌥↑` and `⌘⌥↓` move the focus between panes; at an edge the shortcut beeps.
  `⇧⌘↩` fills the workspace with the focused pane and the same shortcut restores
  the splits; `⌃⌘E` puts every divider back in the middle. A zoom is saved with
  the workspace.
- **Restore.** Workspace titles, split trees, the selection, each pane's last
  directory and a pane's command (an SSH session, for instance) are saved in
  `~/Library/Application Support/MakiDesk/Terminal/workspaces.json` and restored
  on the next launch. The main window reopens at its last size and position
  (`Terminal/window.json`) when enough of that frame still meets a display;
  otherwise it is centered. Scrollback is not saved.
- **Quake.** `⌃⌥Q` drops a scratch terminal from the top of the screen; the
  same key hides it. It appears on the display under the pointer, spans that
  display's visible frame and leaves the menu bar and Dock alone. It is a
  separate session, not part of the saved workspace layout, and it stays alive
  while hidden. MakiDesk's window switcher leaves the quake panel out, since it
  is toggled with its own shortcut; the helper's main window is still listed
  there.
- **Closing and quitting.** The red close button hides the window; it does
  not close the app or the shells. Running commands keep going, the Dock icon
  disappears, and `⌃⌥O` brings the same window and sessions back. Quitting
  **MakiDesk Terminal** (`⌘Q`) is the only action that ends them, and it asks
  for confirmation first.
- **Hidden means not drawn.** Workspaces you are not looking at, a hidden
  quake, a minimized window or an app that macOS has hidden stop rendering;
  their shells keep running and consuming output, and drawing resumes when they
  come back.
- **While the terminal is in front.** MakiDesk suspends its panel, screen and
  desktop shortcuts, so the shell receives them. `⌃⌥O` and `⌃⌥Q` stay active, so
  you can always come back or hide the quake. With **Settings ▸ Terminal ▸ Keep
  window shortcuts while the terminal is in front** on (the default), the
  `⌃⌥` window rows stay active too: `⌃⌥←`/`→`/`↑`/`↓` and the other Window
  commands still arrange the helper window. The helper appears in the Dock and in
  ⌘Tab while its window is open.
- **Find in the scrollback.** `⌘F` opens a find bar over the focused pane, or
  puts the keyboard back in it. Typing searches as you go and the bar reports
  the matches (`3 of 17`, or `No results`); `Return` or `⌘G` moves to the next
  match, `⇧Return` or `⇧⌘G` to the previous one, and `Esc` closes the bar and
  gives the keyboard back to the shell. The search covers Ghostty's scrollback
  and is not saved; each pane remembers its last query while the helper runs.
- **Images on the clipboard.** When the clipboard holds an image and no text,
  `⌘V` writes it as a PNG under
  `~/Library/Application Support/MakiDesk/Terminal/pasted-images/` and types
  its quoted path at the cursor — ready for an agent or a command that takes a
  file. Files older than a week or beyond the newest 100 are removed when the
  helper starts and after each paste; nothing leaves the Mac.
- **VoiceOver and dictation.** The focused pane is an accessibility text area:
  its value is the text on the active screen, with selected text and its range,
  so VoiceOver can read the terminal while you move through it. A dictation or
  accessibility tool that writes text inserts at the shell's cursor — one line
  is typed, a multi-line value goes through the paste path as one block, and a
  trailing newline presses Return. The value is a short cached snapshot and is
  refreshed after an insertion.
- **Links.** Plain URLs are recognized: hold `⌘` while hovering to see the
  underline and the pointing hand, then `⌘`-click to open one in the default
  app. OSC 8 hyperlinks behave the same way; file paths are not turned into
  links.
- **Notifications and attention.** A desktop notification sent by a program in
  the shell (OSC 9/777) appears as a MakiDesk notice, with the terminal's icon,
  instead of a bare system alert. The workspace also gets a dot in the sidebar;
  selecting it, or bringing the window back, clears the dot. A command that
  fails or runs for two seconds or more leaves the same dot when the shell
  reports command boundaries (OSC 133). A terminal bell beeps; if the workspace that
  rang is not in front, it gets the dot too. If MakiDesk is
  not running, the HUD notice is simply skipped.
- **Agent status.** The helper ships a tiny `makidesk` CLI, exposed as
  `$MAKIDESK_CLI` (a stable link at
  `~/Library/Application Support/MakiDesk/Terminal/bin/makidesk`). A hook or
  script can run `"$MAKIDESK_CLI" status working`,
  `… waiting --title "Needs input"` or `… done`; the workspace id comes from
  `MAKIDESK_WORKSPACE_ID`. The sidebar shows a blue dot while working, orange
  while waiting and green when done; selecting the workspace clears the green
  one. Nothing is written to disk. **After updating MakiDesk, quit the terminal
  helper (⌘Q) and reopen it**: a helper that was already running keeps its old
  environment, and an existing pane does not gain the new variables.
- **Automatic agent hooks.** **Settings ▸ Terminal ▸ Agents** switches on
  lifecycle hooks for **Claude Code** and **Codex**: a submitted prompt marks
  the workspace as working, a permission or input prompt as waiting, and a
  finished turn, an interruption or a closed session as done. It is off until
  you turn it on, and turning it on merges a few small handlers into that agent's
  own settings — `~/.claude/settings.json` or `~/.codex/hooks.json` — leaving
  the rest of the file alone and keeping a one-time copy as the file name plus
  `.makidesk-backup`. Turning it off removes only the handlers that call
  `makidesk hook`. From a pane the same thing is
  `"$MAKIDESK_CLI" hooks status|install|uninstall [--agent claude|codex]`.
  Codex asks you to review and trust new hooks once with `/hooks` before they
  run. It also reads inline `[hooks]` tables from `config.toml`: MakiDesk only
  writes `hooks.json` and leaves that file untouched, so an existing inline set
  stays and Codex warns that the layer has both forms. The hooks stay quiet
  outside a MakiDesk pane: a session that did not inherit `MAKIDESK_WORKSPACE_ID` (started elsewhere, or a tmux server started
  before the pane) reports nothing rather than failing. Agents read hooks when
  a session starts, so a session that was already open may need a restart before
  its dot moves.
- **tmux.** **New tmux Session** in the sidebar's **+** menu runs
  `tmux new-session -A -s makidesk-…`: it attaches to that workspace's session
  or creates it. Closing the pane detaches; the tmux server keeps the session,
  and reopening the same pane reattaches. The shell also receives
  `MAKIDESK_TERMINAL=1` and `MAKIDESK_WORKSPACE_ID`. The item is disabled and
  says so when tmux is not installed (`brew install tmux`).
- **SSH profiles.** Add them in **Settings ▸ Terminal ▸ SSH profiles** (name,
  host, user, port, optional key, remote command, agent forwarding), then pick
  **New SSH: …** from the sidebar's **+** menu. The pane runs `ssh` with those
  arguments; passwords are never stored, and keys and `known_hosts` remain
  ssh's own. The command is saved with the layout, so a restored pane tries to
  reconnect.
- **MakiDesk menu.** While the helper is in front, its own menu bar has
  **Open MakiDesk** and **Terminal Settings…**. The second opens Settings ▸
  Terminal directly, or offers to launch MakiDesk when it is not running.
- **Settings ▸ Terminal.** Font family and size, the cursor shape and blink,
  the scrollback size per pane, copying selected text, hiding the pointer while
  typing, the shell command (empty starts your login shell), the quake height
  (30–60% of the screen), the SSH profiles and the opt-in agent hooks. The terminal, its sidebar and its title bar follow the
  MakiDesk theme, and a change reaches the helper without a restart; a new
  scrollback size applies to panes created afterwards. Each theme brings its
  own sixteen ANSI colours;
  the named MakiDesk themes reuse the palette they were drawn from (Plum is
  Dracula, Arctic is Nord, Midnight is Tokyo Night, Caramel is Gruvbox,
  Graphite is One Dark).
- **Not there yet.** tabs inside a pane, hooks for agents other than Claude Code
  and Codex, and a verified IME.

The helper is embedded when the app is bundled (`task bundle`); a development
`swift run` looks for `dist/MakiDeskTerminal.app`. If it is missing, the shortcut
says so in a notice instead of failing silently.

## Clipboard history

`⌥V` opens the last **texts and images** you copied. It is **in memory only** and
disappears when MakiDesk quits.

- Up/Down, Page Up/Down and Home/End move the selection; `↩` or a click pastes
  the selected item into the app you were using. `Esc` closes.
- **To Shelf** sends the selected item to the shelf (also in the row's context
  menu); an image is decoded from its stored bytes.
- A row shows a small preview of what it holds: a **colour swatch** when the
  text is a colour (`#RRGGBB`, `rgb()`, `hsl()`…), a **thumbnail** for a stored
  image or for a local path/`file://` URL, the text icon otherwise. Remote links
  are not fetched.
- **Images** are kept as their original bytes plus a 96 px thumbnail. The
  budget is **16, 32 or 64 MB** (default 32); when it is exceeded the oldest
  unpinned images go first, and an image that cannot fit is reported instead of
  being kept.
- **Pin** an entry from its context menu: it survives *Clear*, the image budget
  and the 50-item limit. *Clear* removes only the unpinned entries; **Clear
  All…** removes everything after a confirmation. Pins are in memory too, so
  they disappear when MakiDesk quits.
- The history keeps at most 50 distinct entries, newest first, and skips the
  copy's private/concealed types. **Secure input** (password fields) is never
  recorded, and the panel does not open while secure input is active.
- Pasting into another app uses Accessibility and a synthetic `⌘V`. Without the
  permission the item is still put on the clipboard and a HUD tells you.

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
- **New Note** sends the selected text to a new note, leaving the open one as it is.
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
| Text | Click where the label goes and type it; Return commits it in the current colour. |
| Crop | Drag the part you want to keep and confirm; the marks move with the image and the editor follows its new size. |

- Four colours (red, yellow, blue, black). **⌘Z** undoes the last mark, `Esc`
  throws the capture away, **Return** saves.
- The result is a PNG on the **shelf**, ready to drag into a chat, a note or a
  folder. **Settings ▸ Panels ▸ Screenshot** also copies it to the clipboard.
  The file lives in the shelf's temporary folder and goes away with it.
- Annotations are made on the capture itself, at the selection's own size, and
  the saved image is rendered at the capture's pixel size, so a Retina capture
  stays sharp.
- It needs Screen Recording, like the previews; Accessibility is not involved.
- **⌃⌥⇧W** captures the window in front and **⌃⌥⇧C** the display under the
  pointer, both in the same editor (**Capture Window…** and **Capture Screen…**
  in the menu). Dragging over the selector still snaps to window edges.

### Recording an area

**⌃⌥⇧R**, or **Record Area…** in the menu, opens the same selector; drag the
area to record. The recording starts at once and runs from the menu bar:
**Pause**, **Resume** and **Stop** in the menu, and the menu-bar icon turns into
a red record dot while it runs. The same key stops it.

- The movie is H.264 at 30 fps and lands on the **shelf** when you stop, ready
  to drag into a chat, a note or a folder. The stop notice says how long it ran.
- **Settings ▸ Panels ▸ Screenshot ▸ Record the system's sound too** includes
  what the Mac plays in the movie. The microphone is not used, so no
  microphone permission is involved. A paused stretch is cut out of the movie
  instead of freezing on the last frame.
- A recording that captured nothing (no frames) is discarded instead of leaving
  an empty file; the notice says why.
- Files are written to `~/Library/Application Support/MakiDesk/Recordings` and
  stay there after they leave the shelf.

## Text from the screen

Press `⌃⌥⇧O` and drag over the text you want. MakiDesk recognizes it locally with
Vision, copies the result to the clipboard and shows a short preview. `Esc`, or
a click without dragging, cancels without copying anything.

- The same reading is in the **Text & Color** menu without dragging: **from the
  window under the pointer**, **from the frontmost window** and **from the whole
  screen**. The first two read the window itself, so overlapping windows do not
  get in the way.
- A picture you already have needs no capture and no permission: **Recognize
  Text** is in a shelf row's context menu for an image (or an image file) and in
  the screenshot library's toolbar for the selected screenshot.
- **An image on the clipboard** needs no capture either: **Recognize Text from
  the Copied Image** in the same menu reads it directly, downscales it if it is
  larger than 4000 px on one side, and sends it to Vision. A copy that the app
  marked private (`org.nspasteboard.ConcealedType`) is refused instead of read.
- The notice that reports the result also offers **New Note**, **Send to
  Shelf** and, when the text was not copied, **Copy** — so the text can go
  straight where it is needed.
- A **Reading text…** notice stays on screen while Vision works — a large area
  can take a couple of seconds — and goes away on its own when the result or the
  error arrives. It is excluded from screenshots and recordings, like every
  notice.
- The area is captured at native resolution; an image longer than 3000 px on
  one side is downscaled before recognition.
- Vision's text detector can fail to start (the framework reports an E5RT
  compile error, typically after a long uptime or a wake): MakiDesk retries once
  and then says so instead of showing a raw error code. Restarting the app
  usually clears it; if it persists, restart the Mac. The failure is logged as
  `ocr failed attempt=… domain=… code=…` without any of the text read.
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

Press `⌃⌥⇧E`, move the loupe over the point you want and click. The loupe shows
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

Press `⌃⌥⇧M` and drag over anything on screen. While you drag, the overlay shows
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

## Disk and CPU

The free space on the start-up disk sits beside the menu-bar icon, and the
**System** menu reports the same figures next to the CPU watch.

- The figure is what Finder calls available: the free blocks plus the space
  macOS can purge. The **System** menu repeats it with the total and the share,
  and adds the strict count when the purgeable allowance is worth naming. Units
  are decimal, so the number matches Finder and Storage settings.
- **Settings ▸ System ▸ Menu bar** chooses *Always*, *Only below the warning
  level* or *Never*, a size or percentage format, and the warning level (10 GB
  by default; 0 turns the warning off). Below it the label turns orange and one
  notice a day offers Storage settings.
- The space is read once a minute on a worker, and the label keeps its last
  value while a menu is open, so the menu cannot close under the pointer. A
  mount, an unmount, waking from sleep or **System ▸ Refresh Disk Now** reads it
  immediately.
- **CPU alerts** watch the processes MakiDesk can inspect, every 15 seconds, and
  report one that stays above the threshold (100% of a core by default) for the
  whole window (10 minutes). Three samples in a row arm the rule and two quiet
  samples reset it, so a single dip does not restart the window. The notice
  names the process and its share, shows what else is busy, and offers
  **Activity Monitor** and **Snooze 1 hour**.
- One process is named at a time, at most once every 30 minutes per episode; a
  different hot process waits five minutes. A process that restarts, even with
  the same PID, starts a new episode.
- Root-owned daemons cannot be read from a user app. When the machine total is
  high and the readable processes do not explain it, the notice says **System
  processes** rather than naming the wrong one.
- **Settings ▸ System ▸ CPU alerts** sets the threshold (50–800% of a core), the
  window (1–60 minutes) and whether a second copy also goes to Notification
  Center. That copy is opt-in: macOS asks for permission when you switch it on,
  and the in-app notice works without it. The **System** menu shows the current
  total and the three busiest processes, and turns the watch back on if it is
  off.
- Nothing is polled while CPU alerts are off. Waking from sleep forgets the
  baselines, so a slept-through gap is never reported as sustained load, and no
  process name or path is written to a log.

## Ports

**System ▸ Ports…** (or the `ports` command) lists the TCP sockets in `LISTEN`,
with the port, the process and its pid, and the addresses. It reads `lsof` when
the window opens and on **Refresh**; nothing polls while it is closed.

- Type in the field to filter by port, process, pid or address.
- **Terminate** asks first, naming the process, pid and port; it then sends
  `SIGTERM` (never `SIGKILL`, never `sudo`). A process of another user is
  reported as a permission error. A process that ignores `SIGTERM` stays in the
  list after the refresh.
- lsof normally sees the ports of the current user; system daemons it cannot
  inspect are simply absent.

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
  the display (active display or pointer), the base duration, the text size
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

- **General** — permissions and **Copy diagnostics** (a short report on the
  clipboard for a bug report), build, animations, keyboard shortcuts,
  licensing, reset and finish setup.
- **Windows** — gap, drag-to-snap key, macOS tiling, focus border, overlay.
- **Layouts** — suggested layout behaviour and the seven content weights.
- **Panels** — shelf shake settings, the checklist card (visibility, opacity,
  width, corner and display), the countdown card (visibility, opacity, corner
  and display), the window switcher/search appearance (including the groups
  column and its announcements), the utility bar (pointer reveal, height,
  labels and the buttons file), the annotated screenshot's clipboard copy, the notice for screenshots
  macOS saves, and text recognition quality and correction. The display choice
  *Active display* is the monitor of the last window focus or pointer move;
  *Mouse pointer* pins a card to wherever the pointer is at that moment.
- **Terminal** — font family and size, shell command, quake height and SSH
  profiles; the terminal follows the theme chosen in Panels ▸ Look and applies
  changes without a restart.
- **Groups** — rename, empty and inspect the nine groups.
- **System** — the free space beside the icon (when to show it, its format, the
  warning level) and the CPU watch (on or off, the threshold and window, the
  optional system-notification copy).
- **Dropzones** — the commands run by dropping on the shelf strip: accepted
  kinds, command and placeholders, runtime, feedback, and *Test*.

The window is a normal macOS window — its own title bar, with close, minimise and
zoom — and opens at 800 × 580 or larger, so nothing is clipped beside the
sidebar. The window is painted with the selected
palette theme — background, cards, accent and a matching light or dark
appearance for the native controls — and takes keyboard focus when it opens.
The theme accent also paints the text caret and the selection in every field of
the app, Notes included, instead of leaving them system blue.
**System** may use native materials where they add depth: the utility bar and
the floating command box and timer field follow the desktop, while the
checklist and the countdown card stay solid so their text remains readable.
Every custom palette is painted with its exact colours; when a palette's card
and window colours are very close and the text keeps enough contrast, the cards
take a slightly lifted tone derived from the same palette. **Reduce Transparency**
turns any material into a solid surface.
**Reset to defaults** asks whether groups, notes, clipboard history and
dropzones should go too; settings always reset.

## Keyboard shortcuts

The full list is in the **Keyboard Shortcuts…** window (menu or Settings ▸
General), searchable by name or key, with the current theme. Four prefixes say
where a key acts: **`⌥`** the five panels opened all day (`⌥⇥`, `⌥Space`, `⌥N`,
`⌥V`), **`⌃⌥`** the window and the layouts (`⌃⌥←`, `⌃⌥G`), **`⌃⌥⇧`** the screen
(`⌃⌥⇧S`, `⌃⌥⇧O`, `⌃⌥⇧M`), **`⌃⌥⌘`** the desktop (`⌃⌥⌘V`, `⌃⌥⌘A`, `⌃⌥⌘Z`). The
same letter may appear under two prefixes, because the prefix says where. The
main global keys:

| Area | Shortcuts |
|---|---|
| Window | `⌃⌥← → ↑ ↓`, `⌃⌥U I J K`, `⌃⌥↩`, `⌃⌥C`, `⌃⌥P`, `⌃⌥F`, `⌃⌥M` |
| Layouts | `⌃⌥G`, `⌃⌥S`, `⌃⌥A`, `⌃⌥W` |
| Panels | `⌥⇥`, `⌥⇧⇥`, `⌥Space`, `⌥N`, `⌥V`, `⌃⌥D`, `⌃⌥L` |
| Timers | `⌃⌥T` |
| Screenshots | `⌃⌥⇧S`, `⌃⌥⇧W`, `⌃⌥⇧C`, `⌃⌥⇧R` |
| Text from the screen | `⌃⌥⇧O` |
| Colour picker | `⌃⌥⇧E` |
| Measure | `⌃⌥⇧M` |
| Command box | `⌃⌥R` |
| Groups | `⌃⌥1…9`, `⌃⌥⌘1…9` |
| Focus | `⌃⌥⌘V`, `⌃⌥⌘A`, `⌃⌥⌘Z` |
| Focus dim, focus border | `⌃⌥⌘D`, `⌃⌥⌘B` |
| Pointer effects | `⌃⌥⇧P`, `⌃⌥⇧X` |
| Peek | `⌃⌥⌘P`, hold `⌃⌥H`, clear `⌃⌥⌘H` |

The mini-map has no global key: it is in the menu and in Settings ▸ Panels.

Pressing `⌥⇥` / `⌥Space` shows the switcher even if MakiDesk is not the active
app. The palette's own keys are listed in the same window (arrows, `↑`/`↓` into
the Applications shelf, `↩`, Space, `Esc`, `⌘1…9`, `⌥1…9`, `⌥Q`, `⌥⇧Q`, `⌥M`,
`⌫`).

### Every key

The table below is generated from the app's own table, with
`task docs:shortcuts`; a test fails when it falls behind.

<!-- shortcuts:begin -->

**Window**

| Command | Keys | Where |
|---|---|---|
| Left column | `⌃⌥←` | Window |
| Right column | `⌃⌥→` | Window |
| Top row | `⌃⌥↑` | Window |
| Bottom row | `⌃⌥↓` | Window |
| Full height — both vertical arrows | ⌃⌥↑ + ↓ | Gesture |
| Full width — both horizontal arrows | ⌃⌥← + → | Gesture |
| Top-left quarter | `⌃⌥U` | Window |
| Top-right quarter | `⌃⌥I` | Window |
| Bottom-left quarter | `⌃⌥J` | Window |
| Bottom-right quarter | `⌃⌥K` | Window |
| Center / full / golden — cycle | `⌃⌥↩` | Window |
| Center | `⌃⌥C` | Window |
| Golden ratio (φ) | `⌃⌥P` | Window |
| Toggle full screen | `⌃⌥F` | Window |
| Minimize | `⌃⌥M` | Window |
| Snap while dragging | ⌥ + drag | Gesture |

**Layouts**

| Command | Keys | Where |
|---|---|---|
| Grid — every window in view | `⌃⌥G` | Window |
| Golden spiral — every window in view | `⌃⌥S` | Window |
| Suggested layout | `⌃⌥A` | Window |
| Content-weighted — areas follow the content | `⌃⌥W` | Window |

**Panels**

| Command | Keys | Where |
|---|---|---|
| Window switcher | `⌥⇥` | Panel |
| Window switcher — backwards | `⌥⇧⇥` | Panel |
| Search windows and applications | `⌥Space` | Panel |
| Notes | `⌥N` | Panel |
| Clipboard history | `⌥V` | Panel |
| Shelf | `⌃⌥D` | Window |
| Checklist | `⌃⌥L` | Window |

**Focus**

| Command | Keys | Where |
|---|---|---|
| Send the front window away | `⌃⌥⌘V` | Desktop |
| Everything back | `⌃⌥⌘A` | Desktop |
| Undo one step | `⌃⌥⌘Z` | Desktop |

**Groups**

| Command | Keys | Where |
|---|---|---|
| Recall group 1 | `⌃⌥1` | Window |
| Add / remove the front window from group 1 | `⌃⌥⌘1` | Desktop |
| Recall group 2 | `⌃⌥2` | Window |
| Add / remove the front window from group 2 | `⌃⌥⌘2` | Desktop |
| Recall group 3 | `⌃⌥3` | Window |
| Add / remove the front window from group 3 | `⌃⌥⌘3` | Desktop |
| Recall group 4 | `⌃⌥4` | Window |
| Add / remove the front window from group 4 | `⌃⌥⌘4` | Desktop |
| Recall group 5 | `⌃⌥6` | Window |
| Add / remove the front window from group 5 | `⌃⌥⌘6` | Desktop |
| Recall group 6 | `⌃⌥5` | Window |
| Add / remove the front window from group 6 | `⌃⌥⌘5` | Desktop |
| Recall group 7 | `⌃⌥=` | Window |
| Add / remove the front window from group 7 | `⌃⌥⌘=` | Desktop |
| Recall group 8 | `⌃⌥9` | Window |
| Add / remove the front window from group 8 | `⌃⌥⌘9` | Desktop |
| Recall group 9 | `⌃⌥7` | Window |
| Add / remove the front window from group 9 | `⌃⌥⌘7` | Desktop |

**Timers**

| Command | Keys | Where |
|---|---|---|
| New timer… | `⌃⌥T` | Window |

**Peek**

| Command | Keys | Where |
|---|---|---|
| Designate / undesignate the front window | `⌃⌥⌘P` | Desktop |
| Peek at it while held | hold ⌃⌥H | Gesture |

**Text & colour**

| Command | Keys | Where |
|---|---|---|
| Recognize text from a selected area | `⌃⌥⇧O` | Screen |
| Pick a colour from the screen | `⌃⌥⇧E` | Screen |

**Screenshots**

| Command | Keys | Where |
|---|---|---|
| Annotate a screenshot | `⌃⌥⇧S` | Screen |
| Annotate a window | `⌃⌥⇧W` | Screen |
| Annotate the whole display | `⌃⌥⇧C` | Screen |
| Record an area | `⌃⌥⇧R` | Screen |

**Measure**

| Command | Keys | Where |
|---|---|---|
| Measure an area | `⌃⌥⇧M` | Screen |
| Keep a square | ⇧ + drag | Gesture |
| Measure from the centre | ⌥ + drag | Gesture |
| Snap to windows and displays | auto | Gesture |

**Pointer**

| Command | Keys | Where |
|---|---|---|
| Locate pointer | `⌃⌥⇧P` | Screen |
| Pointer effects on / off | `⌃⌥⇧X` | Screen |

**App**

| Command | Keys | Where |
|---|---|---|
| Settings… | `⌃⌥,` | Window |
| Keyboard Shortcuts… | `⌃⌥/` | Window |
| Screenshots | `⌃⌥Y` | Window |
| Run a command… | `⌃⌥R` | Window |
| Show / hide the focus border | `⌃⌥⌘B` | Desktop |
| Dim everything but the focused window | `⌃⌥⌘D` | Desktop |
| Focus the selected windows | `⌃⌥⌘F` | Desktop |
| Leave the group in use | `⌃⌥⌘L` | Desktop |
| Clear the peek designation | `⌃⌥⌘H` | Desktop |
| Apply the suggested layout | `⌃⌥⌘↩` | Desktop |
| Utility bar | `⌃⌥B` | Window |
| Terminal | `⌃⌥O` | Window |
| Terminal quake | `⌃⌥Q` | Window |

<!-- shortcuts:end -->

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
do not accept a frame. A size that differs only by the app's own rounding (a
character cell, a title bar) is accepted silently; a real refusal is reported
once, in the status line/HUD, instead of writing the same frame again. The floor
that window showed is remembered for the rest of the session.

**A window is on another Space.** macOS does not provide a public API to move a
window between Spaces. MakiDesk only moves windows on the current desktop.

**Where is my data?** Notes in `~/Library/Application Support/MakiDesk/Note/`;
groups in `groups.json`, remapped shortcuts in `shortcuts.json` and the timers
in `timers.json` in the same Support folder; clipboard and shelf are
memory/temporary. The reset sheet can remove notes and groups; a timer goes
when you delete it.

**Uninstall.** Quit MakiDesk, drag it to the Trash, then remove
`~/Library/Application Support/MakiDesk/` if you do not want the data. Revoke
the permissions in System Settings.
