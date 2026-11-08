# MakiDesk Terminal — F0 spike and F1 work in progress

The terminal helper: a separate app that owns shells, workspaces and split panes
while MakiDesk launches it and configures it. The design lives in
`refs/docs/analisi-terminale-2026-11-07.md`; this file records what the code
actually does.

The package is deliberately apart from the root package: `swift build` at the
repository root must keep working without the GhosttyKit binary.

## Try it

```sh
task terminal:fetch     # once: downloads and verifies the pinned GhosttyKit
task terminal:bundle    # builds and assembles dist/MakiDeskTerminal.app
open dist/MakiDeskTerminal.app
```

`task terminal:run` does both and opens the app. From a bundled MakiDesk, `⌃⌥O`
or the menu bar's **Terminal** item launches the same helper from
`Contents/Applications/`. A development `swift run` looks for
`dist/MakiDeskTerminal.app`.

To run without the user's zsh startup files (useful when they ask for
`~/Downloads` or network access):

```sh
MAKIDESK_SPIKE_CLEAN_SHELL=1 dist/MakiDeskTerminal.app/Contents/MacOS/MakiTerminal
```

The bundle is ad-hoc signed by the script; `task sign` signs it with the project
identity before the outer app.

## What is there

- **GhosttyKit engine:** a login shell in a PTY, Metal rendering, keyboard and
  `NSTextInputClient`, mouse, clipboard, Option-as-Meta, resize/reflow, title and
  cwd actions.
- **Workspaces in a sidebar:** add/close, selection, drag-free for now; each
  workspace owns a binary split tree.
- **Splits:** side-by-side and stacked, draggable dividers, focus border, close
  pane, close workspace; surfaces are reused across rebuilds, so switching
  workspaces never restarts a shell.
- **Persistence:** `Terminal/workspaces.json` holds titles, split tree, ratios,
  selection, each pane's last directory and its command (SSH included); it is
  atomic and versioned, and a corrupt file is quarantined. Scrollback is not
  saved.
- **SSH profiles:** settings.json entries become `ssh` command lines in a new
  workspace from the sidebar's + menu; keys and prompts stay with ssh.
- **tmux:** a preset runs `tmux new-session -A -s makidesk-…`, reattaching to the
  workspace's session after a restore. The menu item is disabled when tmux is
  not installed (common paths are checked before PATH). Panes also get
  `MAKIDESK_TERMINAL=1` and `MAKIDESK_WORKSPACE_ID` in their environment.
- **Settings and theme:** `Terminal/settings.json` (font, shell command, quake
  height) and `Terminal/theme.json` (MakiDesk palette plus the theme's sixteen
  ANSI colours, plus the surface/text/accent colours for the helper's own
  sidebar and title bar) are written by MakiDesk; the helper reloads them on
  `settingsChanged` and `themeChanged`.
- **Agent status CLI:** `Contents/Resources/bin/makidesk status working`,
  `waiting` or `done` connects to the helper socket, reads
  `MAKIDESK_WORKSPACE_ID` and only updates a sidebar dot. The helper recreates a
  stable link at `~/Library/Application Support/MakiDesk/Terminal/bin/makidesk`
  and exports its path as `MAKIDESK_CLI` in each pane; quote it in the shell.
  A helper started before an update does not have the new variables: quit and
  reopen it.
- **Automatic agent hooks:** `makidesk hooks install` (or the opt-in switch in
  Settings ▸ Terminal ▸ Agents) merges five lifecycle handlers into
  `~/.claude/settings.json`: `UserPromptSubmit` is working, a permission or
  input notification is waiting, and `Stop`, `StopFailure` and `SessionEnd` are
  done. `AgentHooks` in `MakiShared` owns the merge, the marker that identifies
  MakiDesk's handlers, and the one-time `.makidesk-backup`; `uninstall` removes
  only those handlers. The handlers call `makidesk hook`, which exits 0 and
  prints nothing when the session is not inside a MakiDesk pane.
- **Notifications and attention:** OSC 9/777 desktop notifications are
  forwarded over the socket (`attention`) and shown as MakiDesk notices; the
  workspace gets a dot in the sidebar, cleared by selecting it or returning to
  the window. A failed or long command (OSC 133) marks it too. Nothing is
  written to disk.
- **Two-app boundary:** `MakiShared` (framing and messages) and a Unix socket
  (`0600`) with a handshake, peer pid check, retries and notices. The helper is
  `.regular` while its window is open; signing is inside-out.
- **Menus:** New Workspace `⌘T`, New Split Right `⌘D`, New Split Down `⇧⌘D`,
  Close Pane `⌘W`, Close Workspace `⇧⌘W`, Find `⌘F` (next `⌘G`, previous `⇧⌘G`),
  Show Quake in View.
- **Find bar:** one per window, over the focused pane; the needle is sent to
  Ghostty as a `search:` binding action and the match total and selection come
  back as surface actions. `Esc` ends the session and returns the keyboard to
  the shell; each pane keeps its last needle for the run.
- **Image paste:** an image with no text on the clipboard is encoded to PNG on a
  worker under `Terminal/pasted-images/` and its shell-quoted path is typed at
  the cursor; the files are pruned to the newest 100 and a week at launch and
  after each paste.
- **Quake:** a borderless floating panel with its own scratch shell, toggled by
  IPC; it stays alive while hidden and is not part of the saved layout. The
  panel carries an Accessibility identifier, so MakiDesk's window switcher
  leaves it out while the helper's main window stays listed.
- **Shortcut handover:** while the helper is frontmost, MakiDesk suspends its
  other global rows (and the peek hold key) and keeps only `⌃⌥O` and `⌃⌥Q`.

## What is not there yet

- hooks for agents other than Claude Code; tmux control mode (L3).
- **IME composition** with a real input source; the code path exists and was not
  exercised. Drag selection, scrollback scrolling and links are the same kind of
  not-yet-verified surface; find runs through Ghostty's search and image paste
  exists, but neither was exercised on screen.
- Signing with the project identity and notarization for release, multi-display
  behaviour, energy and memory measurements.

## Engine provenance

`GhosttyKit.xcframework` is a prebuilt universal static xcframework published by
the cmux project from its Ghostty fork (Ghostty itself is MIT; the fork is an
MIT derivative). `scripts/fetch-ghosttykit.sh` pins:

- Ghostty commit `cb1ef7091cdef0b581ee2cbd83742b653253523e`
- build flavour `crashsubdir-cmux-crash-sentry-off-noi18n-v2`
- archive SHA-256 `413515af9e3739068f91bae98bc33fa1d89d4ea20b35d0fa96b317379bb17ae2`

The archive is about 129 MB, extracts to about 505 MB and is **not** committed
(`vendor/` is ignored). The helper binary is about 18 MB after dead stripping.
Before distribution, decide whether to keep depending on that release or build
GhosttyKit from upstream; the study lists this as a risk.

## Layout

- `MakiTerminalCore`: pure workspace/split model and `TerminalLayoutStore`;
  tested without AppKit or Ghostty.
- `MakiTerminal`: AppKit window, sidebar, split container, Ghostty host, IPC
  server.
- `../Packages/MakiShared`: message envelope, framing and socket path, the
  `makidesk` CLI path and the agent-hook merge, linked by both apps.

## A note on TCC and network prompts

With the user's normal login shell, macOS attributed the shell's startup file
access to the terminal app: a prompt for `~/Downloads` and a network prompt for
`api.github.com` appeared. With `--no-rcs` they disappear. They come from the
shell's rc files, not from libghostty. The real helper will have to explain
these prompts, because a terminal is the process responsible for whatever the
user's shell starts.
