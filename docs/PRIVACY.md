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
- [Revoking and removing](#revoking-and-removing)

## Permissions

MakiDesk is not sandboxed and is distributed outside the Mac App Store. It asks
for two macOS TCC permissions:

| Permission | Why |
|---|---|
| **Accessibility** | Read and move other apps' windows, paste into the front app, and listen for the shake gesture. |
| **Screen Recording** | Live window previews, the content measure used by the suggested/content-weighted layouts, and the area selected for text recognition. |

Both are granted by you in **System Settings ▸ Privacy & Security** and can be
revoked there at any time. The app does not request Input Monitoring, Full Disk
Access, Contacts, Calendar, Microphone, Camera or Automation.

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
  refuses to open in that state. Vision's language models stay resident in
  memory after the first use.
- **Text on the pasteboard**, only through the clipboard-history poll, and only
  while secure input is off and the copy is not marked concealed/transient.
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
  and `~/Applications` when the palette is searching: only `Info.plist` names,
  the executable name, the bundle id and the bundle path, plus the icon the
  system returns for the path. The list stays in memory and is not written to
  disk or uploaded.

## What is stored

All paths are under your user account:

| Data | Location | Lifetime |
|---|---|---|
| Window groups | `~/Library/Application Support/MakiDesk/groups.json` | Until you delete them or reset |
| Dropzones and icons | `…/MakiDesk/dropzones.json` (0600) and `…/MakiDesk/DropzoneIcons/` | Until you delete them or reset |
| Dropzone runs | `~/Library/Caches/MakiDesk/DropzoneRuns/<run>/` | Removed when the run ends unless kept or revealed |
| Notes and drafts | `…/MakiDesk/Note/note-<id>.txt` and `session.json` | Until you delete them or reset |
| Preferences | `UserDefaults` (theme, layout weights, shelf shake, screenshot folder/view, animations, switcher settings) | Until reset |
| Clipboard history | RAM | Until MakiDesk quits |
| Shelf | RAM + a temporary staging folder | Until the shelf closes |
| Peek designation | RAM | Until the app quits |
| Installed applications | RAM | Until the 2-minute cache refreshes or the app quits |
| Window previews/measure | RAM | Replaced/evicted while running |
| Screenshot previews | RAM | While the screenshot window is open |

Deleting a note moves its draft to the Trash (recoverable). The factory reset
can remove groups, notes, clipboard history and dropzones; settings always
reset.

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

## Revoking and removing

- Revoke Accessibility or Screen Recording in System Settings at any time; the
  corresponding features stop working, the rest of the app remains usable.
- **Uninstall**: quit MakiDesk, drag it to the Trash, then remove
  `~/Library/Application Support/MakiDesk/` (groups, notes, dropzones and their
  icons) and `~/Library/Caches/MakiDesk/` (kept dropzone run folders) if you do
  not want them. The factory reset is in Settings ▸ General.
- For a security report, open an issue in the repository or contact the
  maintainer listed in the README.
