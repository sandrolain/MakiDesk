# MakiDesk — privacy and permissions

MakiDesk is a local desktop utility. It has **no account, no server, no
analytics, no crash uploader and no telemetry**, and it does not send window
titles, previews, notes, clipboard contents, recognized text or files anywhere.

- [Permissions](#permissions)
- [What is read](#what-is-read)
- [What is stored](#what-is-stored)
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
- **A copied image**, only when you ask for its text: the bytes are read from
  the pasteboard, downscaled in memory and passed to Vision. That action does not
  write the image to disk or add it to the clipboard history.
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
| Notes and drafts | `…/MakiDesk/Note/note-<id>.txt` and `session.json` | Until you delete them or reset |
| Checklist items | `…/MakiDesk/checklist.json` | Until you delete them; a factory reset leaves them |
| Preferences | `UserDefaults` (theme, layout weights, shelf shake, screenshot folder/view, animations, switcher settings, disk label and CPU watch, date of the last disk warning) | Until reset |
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
deadline (or, while paused, the time left).

## Clipboard

The history is **text only, in memory, and never persisted**. It keeps at most
50 distinct texts. It **does not record** while macOS reports secure input
(password fields, some password managers), and it skips pasteboard items marked
`org.nspasteboard.ConcealedType`, `TransientType` or `AutoGeneratedType`. The
panel itself does not open while secure input is active.

Pasting writes the chosen text to the system pasteboard and, when Accessibility
is granted, sends `⌘V` to the app you were using. That is the only synthetic key
the app sends.

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
cards, the overlay and the content score. They stay in memory, are never
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
file paths and screenshots are **not** logged, so a log excerpt can be shared.

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
