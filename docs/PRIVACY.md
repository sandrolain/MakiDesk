# MakiDesk — privacy and permissions

MakiDesk is a local desktop utility. It has **no account, no server, no
analytics, no crash uploader and no telemetry**, and it does not send window
titles, previews, notes, clipboard contents, recognized text or files anywhere.

- [Permissions](#permissions)
- [What is read](#what-is-read)
- [What is stored](#what-is-stored)
- [Docker](#docker)
- [Clipboard](#clipboard)
- [Shelf](#shelf)
- [Dropzones](#dropzones)
- [Window previews](#window-previews)
- [System monitor](#system-monitor)
- [Logs and diagnostics](#logs-and-diagnostics)
- [Revoking and removing](#revoking-and-removing)

## Permissions

MakiDesk is not sandboxed and is distributed outside the Mac App Store. It asks
for two macOS TCC permissions:

| Permission | Why |
|---|---|
| **Accessibility** | Read and move other apps' windows, paste into the front app, and listen for the shake gesture. |
| **Apple Intelligence** | Rewriting notes uses the on-device model only: no network, no account, no content in logs. The notice under Settings ▸ Panels ▸ Tools says when it is unavailable. |
| **Screen Recording** | Live window previews, the content measure used by the suggested/content-weighted layouts, the area selected for text recognition, the annotated captures and screen recordings (T40). A recording can include the system's own sound; the microphone is never used. |

Both are granted by you in **System Settings ▸ Privacy & Security** and can be
revoked there at any time. The app does not request Input Monitoring, Full Disk
Access, Contacts, Calendar, Microphone, Camera or Automation.

The pointer effects add no permission at all: `⌃⌥⇧P` and `⌃⌥⇧X` read the pointer
through AppKit's mouse events and draw their own transparent panels, so they
keep working with every TCC permission off.

The optional **system notification** copy of a CPU notice is not a TCC
permission: macOS asks once, when you switch the option on in Settings ▸ System,
and the app posts nothing to Notification Center until you allow it. The in-app
notice needs no permission at all.

TCC attaches the grant to the app's code identity. With a stable bundle id and
signing identity the grant survives updates; an ad-hoc build or a changed
identity asks again. A Developer ID-signed public release behaves best here.

## What is read

- **Window metadata** through Accessibility: app, title, frame, minimized/full
  screen state and the accessible element used to set a frame. This is needed
  to list windows and move them.
- **The pointer position**, while the utility bar is enabled: sampled ten
  times a second to decide whether the pointer is resting in the strip under the
  menu bar and whether it is still on the open bar. Nothing is recorded or
  logged, and the sampling stops the moment the feature is turned off.
- **The pointer position**, from a global mouse-move monitor, to know which
  display is active: the cards and panels that follow the last window focus or
  pointer move need the display, not the coordinates. Only the display changes
  are remembered in memory; the position is never recorded, logged or written,
  and it is not used for anything else.
- **The pointer position**, while the pointer effects are in use: read once for
  `⌃⌥⇧P`, and through the same global mouse events while a presentation effect
  is on, to place a transparent panel around the pointer. It is used in memory
  only; the position is never recorded, logged or written, and nothing samples
  the pointer or stays on screen once the feature is off.
- **Window images** through ScreenCaptureKit, only while previews or the
  content measure are in use. The images are downscaled and kept **in memory**;
  they are used for the switcher cards, the overlay and the edge-energy score,
  and are not written to disk.
- **The area you select for text recognition**, only when you press `⌃⌥O`. The
  image is processed locally by Vision, kept in memory for the recognition and
  not written to disk. The recognized text goes to the system clipboard, to the
  in-memory clipboard history, or both, as chosen in Settings; “History only”
  never touches the system pasteboard. An OCR request is explicit, so it is
  recorded even while secure input is active; the history panel itself still
  refuses to open in that state. While secure input is active, text copied to
  the system clipboard is also marked `org.nspasteboard.ConcealedType`, so
  clipboard managers that honour the convention skip it. Vision's language
  models stay resident in memory after the first use.
- **Text on the pasteboard**, only through the clipboard-history poll, and only
  while secure input is off and the copy is not marked concealed/transient.
- **A copied image**, through the clipboard-history poll while images are
  enabled: the original bytes and a small thumbnail stay in memory under the
  budget, and are dropped when images are turned off or the app quits. When you
  ask for its text, the same bytes are downscaled in memory for Vision. Neither
  path writes the image to disk.
- **Listening TCP ports and process names**, only when the Ports window is opened
  or refreshed: read locally with `lsof`, kept in memory for the list, and never
  logged or sent anywhere. Terminate sends `SIGTERM` to the chosen process.
- Files and URLs **only when you drop them on the shelf or open them in Notes**.
  The app keeps references to those files, not copies (the exception is a file
  promise from another app, which must be materialized in a temporary folder).
- **Dropped content for a dropzone**, only when you drop it on a zone: the app
  prepares the files, images, text or links in the run folder and passes their
  paths or the text to the command you configured. The command itself decides
  what to read and whether to use the network; MakiDesk does not upload it.
- The links you drag onto the shelf or ask Finder to reveal are opened with the
  default app; the app does not fetch them itself.
- **Installed application bundles** in `/Applications`, `/System/Applications`
  and `~/Applications` when the palette is searching: only
  `Info.plist` names, the executable name, the bundle id and the bundle path,
  plus the icon the system returns for the path. The list stays in memory and is
  not written to disk or uploaded.
- **Disk capacity** of the start-up volume, read once a minute and when you ask
  for a refresh: total space, free space and the purgeable allowance macOS
  reports. No file names, folder contents or other volumes are read.
- **Running processes**, only while CPU alerts are on: every 15 seconds, the
  process id, start time, executable path and name, and cumulative CPU time of
  the processes your user may inspect, plus the machine's own CPU counters.
  The busiest names are what the System menu and a notice show; the readings
  live in memory. Root-owned daemons cannot be read and are covered only by the
  machine's total, which is why an unexplained load is reported as *System
  processes*.

## What is stored

All paths are under your user account:

| Data | Location | Lifetime |
|---|---|---|
| Window groups | `~/Library/Application Support/MakiDesk/groups.json` | Until you delete them or reset |
| Dropzones and icons | `…/MakiDesk/dropzones.json` (0600) and `…/MakiDesk/DropzoneIcons/` | Until you delete them or reset |
| Dropzone runs | `~/Library/Caches/MakiDesk/DropzoneRuns/<run>/` | Removed when the run ends unless kept or revealed |
| Notes and drafts | `…/MakiDesk/Note/note-<id>.txt` and `session.json` (including a SHA-256 digest of each linked external file's last known text) | Until you delete them or reset |
| Checklist items | `…/MakiDesk/checklist.json` | Until you delete them; a factory reset leaves them |
| Utility bar buttons | `…/MakiDesk/utility-bar.json`: button ids, shown or not, optional titles and symbols | Until you delete them or reset |
| Terminal layout | `…/MakiDesk/Terminal/workspaces.json`: workspace titles, split tree, selection, zoomed pane, last directory per pane | Until you delete it; a factory reset does not remove it |
| Terminal window frame | `…/MakiDesk/Terminal/window.json`: the helper's main window position and size | Until you delete it; a factory reset does not remove it |
| Terminal settings and theme | `…/MakiDesk/Terminal/settings.json` (font, cursor, scrollback, selection copy, pointer hiding, shell command, quake height, SSH profiles) and `theme.json` (colours) | Until you delete them |
| Terminal pasted images | `…/MakiDesk/Terminal/pasted-images/paste-*.png`: an image you pasted into a terminal pane, as its own PNG | Until a week old or beyond the newest 100, pruned at helper launch and after each paste |
| Docker window state | `…/MakiDesk/Docker/window.json`: the helper's window position and size | Until you delete it |
| Docker settings | `…/MakiDesk/Docker/settings.json`: refresh/stats intervals, default shell, confirmation and log preferences, optional docker path and context | Until you delete it |
| Docker theme | `…/MakiDesk/Docker/theme.json`: the MakiDesk palette colours | Until you delete it |
| Claude Code and Codex hooks (opt-in) | `~/.claude/settings.json` or `~/.codex/hooks.json` gains five handlers; a one-time `<name>.makidesk-backup` sits next to it | The handlers until you switch them off; the backup until you delete it |
| Preferences | `UserDefaults` (theme, layout weights, shelf shake, screenshot folder/view, animations, switcher settings, utility bar on/height/labels, disk label and CPU watch, date of the last disk warning) | Until reset |
| Timers | `…/MakiDesk/timers.json` | Until you delete them; a factory reset leaves them |
| Clipboard history | RAM | Until MakiDesk quits |
| Shelf | RAM + a temporary staging folder | Until the shelf closes |
| Peek designation | RAM | Until the app quits |
| Installed applications | RAM | Until the 2-minute cache refreshes or the app quits |
| Applications opened from the shelf | `UserDefaults` (`applicationLauncherUsage`): bundle id, number of openings, last opening | Until reset; one entry per app, the 80 most recent |
| Window previews/measure | RAM | Replaced/evicted while running |
| Screenshot previews | RAM | While the screenshot window is open |
| Screen recordings | `~/Library/Application Support/MakiDesk/Recordings` | Until you delete them: they outlive the shelf |
| Notes rewriting | RAM only | The note excerpt is sent to the on-device model and the proposal is discarded unless you Apply |

Deleting a note moves its draft to the Trash (recoverable). The factory reset
can remove groups, notes, clipboard history and dropzones; settings always
reset. The timers file holds only a label, where the timer came from and its
deadline (or, while paused, the time left). The utility bar's file holds only
button ids, whether each is shown, and an optional renamed title or symbol; the
old hidden-buttons preference is read once, migrated there and then removed.

## Terminal

The terminal is a separate helper app (`com.makidesk.app.terminal`). Its shell
output, scrollback, selection and environment stay **in the helper's memory**;
none of it is written to disk or to a log. The layout file holds workspace
titles, the split tree, the selection and each pane's last directory; an SSH
pane also saves the command that started it, which includes its host, user and
key path. Passwords are never stored: `ssh` handles them, and keys and
`known_hosts` remain in `~/.ssh`.

While the helper runs it listens on
`~/Library/Application Support/MakiDesk/Terminal/terminal.sock` (`0600` in a
`0700` directory). The socket carries only the closed command/event set between
the two apps, is local to the user, and the helper rejects a peer that is not
MakiDesk. It is removed when the helper quits.

Desktop notifications emitted by the shell (OSC 9/777) are forwarded to
MakiDesk and shown as notices; their title and body live in the notice history
in memory, like every other notice, and are never written to disk. Agent
statuses sent by the bundled `makidesk` CLI (working, waiting, done, optional
title) also live only in the helper's memory and are shown as a sidebar dot.

An image pasted into a pane (when the clipboard holds no text) is written as a
PNG under `…/MakiDesk/Terminal/pasted-images/`, because a terminal can only send
text: the quoted path is typed at the cursor instead. Files older than a week or
past the newest 100 are removed when the helper starts and after each new paste.
Nothing is sent anywhere.

Agent hooks are **opt-in** and **local**. Only when you switch them on in
Settings ▸ Terminal ▸ Agents does MakiDesk add a handful of handlers to
`~/.claude/settings.json` or `~/.codex/hooks.json`; the rest of that file is
preserved, and the first change keeps a copy next to it as
`settings.json.makidesk-backup` or `hooks.json.makidesk-backup`. A handler runs
the bundled `makidesk hook working|waiting|done`, which sends only the workspace
id, the state and the fixed agent name to the local socket and exits; MakiDesk
never reads the prompt, the transcript, the working directory or the model's
output. A session outside a MakiDesk pane produces no message. Turning the
switch off removes only the handlers that call `makidesk hook`; the backup is
yours to keep or delete. Codex additionally asks you to review and trust new
hooks once (with `/hooks`) before it runs them.

The helper starts your login shell, so macOS attributes whatever that shell reads
or connects to (shell startup files, tools it launches, `ssh`) to the helper, not
to MakiDesk. That is why the first launch can ask for access to folders such as
`~/Downloads` or for a network connection when your shell's own files do. The
request comes from the shell's configuration, not from MakiDesk or libghostty;
starting the shell with `--no-rcs` avoids both in the development spike.

The terminal pane is an accessibility text area: its value is the text on the
active screen, kept in a half-second in-memory snapshot for VoiceOver and
dictation tools. Accessibility writes are inserted into the shell at the cursor;
selected text comes from the terminal's own selection. The snapshot is never
written to disk and is dropped when the pane goes away.

## Docker

The Docker window is a separate helper app (`com.makidesk.app.docker`). It talks
to the Docker daemon only through the `docker` CLI, using the user's own
`DOCKER_HOST`, context and `~/.docker` configuration; it does not open a network
server or listen on a port. User-requested pull and push actions use the Docker
CLI's configured registry credentials and contact the configured registry;
commands also reach the daemon selected by the current context. Building sends
the selected build context to that daemon; file-copy actions transfer the
selected files through the Docker CLI. MakiDesk and the helper meet on
`~/Library/Application Support/MakiDesk/Docker/docker-control.sock` (`0600` in a
`0700` directory); the helper rejects a peer that is not MakiDesk.

Docker access is privilege-equivalent: the socket can control containers and
host resources. The helper never executes a command received over IPC. The one
cross-app request, **Terminal**, carries a validated container reference and an
allow-listed shell; the terminal composes `docker exec -it` itself. Container
environment variables and log contents can contain secrets. They are shown
only in the window; environment variables are visible in the Overview table
and collapsed in Inspect until expanded. Neither is written to disk or to a
log. A copied `docker run` command can include environment values and is placed
on the system clipboard only after an explicit copy action and confirmation.
The file transfer actions copy user-selected local files to a container or
container files to a user-selected local path through `docker cp`; the helper
does not retain those files. Container CPU, memory, network and block I/O, and
PID samples are read while the relevant view is visible and kept only in memory.
Docker names, images, volumes, networks, Compose paths and disk usage are read
to render the window and are not sent to a separate MakiDesk service.

The helper stores only its window frame, local preferences and the theme. It
does not persist logs, inspect output, environment values, container IDs or
command output. A remote Docker context is marked in the window and every
destructive confirmation names the context and endpoint; the app never runs
`docker context use` on your behalf. No new TCC permission is requested:
Accessibility, Screen Recording and Full Disk Access are not needed for this
window.

## Browser

MakiDesk Browser is a separate regular app (`com.makidesk.app.browser`) bundled
inside MakiDesk. Pages are loaded by WebKit's own WebContent and Networking
processes; cookies, local storage, cache and the website data store are handled
by WebKit and stored under the user's WebKit data directory. MakiDesk does not
add analytics, telemetry or a remote history service. The tab list, pin state,
last-use timestamps, favicon colour and blocker exceptions are stored in
`~/Library/Application Support/MakiDesk/browser-tabs.json` and
`browser-settings.json`. The address suggestions use
`browser-history.json`: a bounded local list of URLs and titles of pages that
finished loading, kept only to suggest addresses already visited. There is no
browsing-history screen and no "recently closed" archive. Page content, form
values, cookies and summaries are not written to those files.

The favicon is requested directly from the site's icon URL in an ephemeral
`URLSession` with no shared cookies, a five-second timeout and a 512 KB cap.
That request goes to the site you are already visiting; no favicon service is
used. The icon and its extracted colour are cached in memory; the colour is
persisted with the tab. The ad blocker is a WebKit content-rule list; it
evaluates on the device and does not report page URLs to MakiDesk or to a
server. The built-in starter list contains domain patterns only. Disabling the
blocker for a site or a tab is stored as described above; the per-tab override
is discarded when the tab navigates.

Page summarization uses Apple's Foundation Models on the device. The readable
text of the current page is extracted in the WebKit view, capped at 12,000
characters, and passed to the local model; it is not uploaded, not written to
disk and not logged. The resulting summary is kept in memory for the current
view and is discarded on navigation or when the panel closes. If Apple
Intelligence is unavailable, the browser shows that fact and does not fall back
to a cloud model. The extension host is not active in this version; when it is
added, extension permissions and storage will be documented here before they
ship.

Passwords saved from the browser's key panel are Internet Password items in
the user's login Keychain, under the server's registrable domain and the chosen
username. MakiDesk reads only its own items; Safari's saved passwords are a
separate protected store and are neither imported nor read. The password is
never written to the browser JSON files and never logged. Deleting an item from
the panel removes it from the Keychain.

The browser requests no Accessibility or Screen Recording permission. It uses
the network as any WebKit page does, and downloads use `WKDownload` with a
destination chosen by the user.

## Clipboard

The history is **text and images, in memory, and never persisted**. It keeps at
most 50 entries (pinned ones can exceed the limit). An image is stored as its
original bytes plus a 96 px thumbnail, under a 16/32/64 MB budget (32 MB by
default); the oldest unpinned images are evicted, and an image that cannot fit
is reported and not kept. Pins are in memory only as well. It **does not record**
while macOS reports secure input (password fields, some password managers), and
it skips pasteboard items marked `org.nspasteboard.ConcealedType`,
`TransientType` or `AutoGeneratedType`. The panel itself does not open while
secure input is active.

Pasting writes the chosen text or the image's original bytes to the system
pasteboard and, when Accessibility is granted, sends `⌘V` to the app you were
using. That is the only synthetic key the app sends.

## Shelf

Files and folders are **references**: moving or deleting the original is
reflected in the shelf (the row says *Not available*). Text, images and links
are kept in memory. File promises from Photos/Safari/Mail are the only items
that require a temporary copy; the staging folder lives under the system
temporary directory, is used only for the current shelf, and is deleted when
the shelf closes. The shelf is one at a time and never persists.

## Dropzones

Dropzones are **commands you write**, not scripts shipped with MakiDesk. The
app runs them with your user privileges and does not sandbox them: a command
can read anything you can, start other programs, and use the network exactly as
the same line would in Terminal. Before the first run, and after any change to
the command, mode, stdin, environment or working directory, MakiDesk shows the
line and asks for confirmation.

The configuration is a private (`0600`) file under Application Support; a
symlinked or group-writable file is shown but never run, and a file written by a
newer version is read-only. Dropped items are materialized under the run folder
in `~/Library/Caches/MakiDesk/`, which also holds stdout, stderr and `output/`;
it is removed when the run ends unless you keep or reveal it. The Shortcuts
picker only reads `shortcuts list` to prefill a command; it does not run or
inspect the shortcut's actions.

## Screenshot library

The screenshot window lists image and PDF files with common macOS screenshot
filename prefixes from the selected folder. It starts with Desktop; choosing a
different folder stores that folder path in preferences. Thumbnails are created
locally on demand and kept only in memory. Opening or revealing a file, moving
it to another folder, and sending it to the Trash happen only after you choose
that action; the library does not copy or upload screenshots on its own.

## Window previews

ScreenCaptureKit frames are requested for visible windows to draw the switcher
cards, the overlay and the content score. The utility bar's own window is passed
to ScreenCaptureKit as an excluded window while it is visible, so neither it nor
the selection overlays appear in a capture, an OCR pass or a recording. They stay in memory, are never
uploaded, and are not part of the notes/groups data. Without Screen Recording
the switcher falls back to app icons and the content-weighted layout uses the
per-kind weights only.

## System monitor

The menu-bar space figure and the CPU watch are local readings. The volume is
the start-up disk; other disks are not scanned. The process table is read with
`libproc` for the processes your user can inspect, and the machine total comes
from the kernel's CPU counters. Neither the process table nor the disk figures
are written to disk, and no process name, executable path or command line is
logged or sent anywhere.

**Settings ▸ System** keeps the disk label mode and format, the warning level,
the last day a disk warning was shown (so reopening the app does not repeat it),
whether CPU alerts are on, the threshold and window, and whether the optional
system notification is on. The date of the last warning and the preference
values are the only state that survives a restart; process readings and the
sustained-load episodes do not.

## Logs and diagnostics

MakiDesk writes to the system log (`com.makidesk.app`, one category per part:
`app`, `index`, `capture`, `palette`, `notes`, `ocr`, `shortcuts`, `store`).
What goes there is deliberately narrow: durations, counts, revisions and ids the
app chose itself. Window titles, note text, clipboard content, recognised text,
file paths, screenshots and pointer coordinates are **not** logged, so a log
excerpt can be shared.

**Copy diagnostics** in Settings ▸ General ▸ Permissions puts a short report on
the clipboard: the app and macOS versions, which permission is on, how many
shortcuts are active, taken or customised, the state of `shortcuts.json` (never
its path) and how many windows and groups are known. Nothing else is read and
nothing is sent: it is text on the clipboard, and you choose where it goes.

## Revoking and removing

- Revoke Accessibility or Screen Recording in System Settings at any time; the
  corresponding features stop working, the rest of the app remains usable.
- **Uninstall**: quit MakiDesk, drag it to the Trash, then remove
  `~/Library/Application Support/MakiDesk/` (groups, notes, dropzones and their
  icons) and `~/Library/Caches/MakiDesk/` (kept dropzone run folders) if you do
  not want them. The factory reset is in Settings ▸ General.
- For a security report, open an issue in the repository or contact the
  maintainer listed in the README.
