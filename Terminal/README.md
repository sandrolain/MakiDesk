# MakiDesk Terminal — F0 spike

A separate SwiftPM package with one job: prove that libghostty can host a real,
usable terminal inside the future MakiDesk helper. It is **not** the helper yet:
there are no workspaces, splits, sidebar, quake panel, IPC or settings. Those
belong to F1, and the design lives in
`refs/docs/analisi-terminale-2026-11-07.md`.

The package is deliberately apart from the root package: `swift build` at the
repository root must keep working without the GhosttyKit binary.

## Try it

```sh
task terminal:fetch     # once: downloads and verifies the pinned GhosttyKit
task terminal:bundle    # builds and assembles dist/MakiDeskTerminal.app
open dist/MakiDeskTerminal.app
```

The bundle is ad-hoc signed, enough for a local spike. To run without the user's
zsh startup files (useful when they ask for `~/Downloads` or network access):

```sh
MAKIDESK_SPIKE_CLEAN_SHELL=1 dist/MakiDeskTerminal.app/Contents/MacOS/MakiTerminal
```

`task terminal:run` does `terminal:bundle` and opens the app.

## What F0 proved

Verified by hand on 7 November 2026, macOS 26, arm64, one window and one
surface:

- **Rendering:** a login shell (`/usr/bin/login -flp … /bin/zsh`) starts in a
  PTY and renders through Ghostty's Metal layer.
- **Keyboard:** printable keys, Return, Ctrl+C and arrows reach the shell.
- **Option as Meta:** `macos-option-as-alt = true` sends `Esc` + key (checked
  with `cat -v`: Option+B shows `^[b`).
- **Paste:** ⌘V runs Ghostty's `paste_from_clipboard` binding and the shell
  receives the text.
- **Copy:** ⌘A then ⌘C fills the macOS clipboard with the scrollback text.
- **Resize:** changing the window size reflows the grid; the PTY follows.
- **Title:** `SET_TITLE` updates the window title with the shell's cwd/user.
- **Bundled app:** `dist/MakiDeskTerminal.app` launches from Finder, is ad-hoc
  signed, and reports `com.makidesk.app.terminal`.

## What F0 did not prove

- **IME composition and dead keys.** The `NSTextInputClient` path is implemented
  but was not exercised with a composing input source.
- **Drag selection, scrollback scrolling, mouse reporting, links, search.**
- **Several surfaces at once**, tabs, splits, workspace restore.
- **Signing with the project identity, hardened runtime, notarization.**
- **Energy and memory** under load.
- **A helper/IPC boundary**: none exists yet.

## Engine provenance

`GhosttyKit.xcframework` is a prebuilt universal static xcframework published by
the cmux project from its Ghostty fork (Ghostty itself is MIT; the fork is an
MIT derivative). `scripts/fetch-ghosttykit.sh` pins:

- Ghostty commit `cb1ef7091cdef0b581ee2cbd83742b653253523e`
- build flavour `crashsubdir-cmux-crash-sentry-off-noi18n-v2`
- archive SHA-256 `413515af9e3739068f91bae98bc33fa1d89d4ea20b35d0fa96b317379bb17ae2`

The archive is about 129 MB, extracts to about 505 MB and is **not** committed
(`vendor/` is ignored). The spike binary is about 18 MB after dead stripping.

Before distribution, decide whether to keep depending on that release or build
GhosttyKit from upstream; the study lists this as a risk. The wrapper is kept
small on purpose so the binary can be replaced:

- `GhosttyRuntime.swift`: `ghostty_init`, one `ghostty_app_t`, callbacks
  (tick, actions, clipboard, close).
- `TerminalSurfaceView.swift`: `CAMetalLayer` host, sizing, `NSTextInputClient`,
  key and mouse forwarding.
- `TerminalAppDelegate.swift`: one window, minimal menu.

## A note on TCC and network prompts

With the user's normal login shell, macOS attributed the shell's startup file
access to the terminal app: a prompt for `~/Downloads` and a network prompt for
`api.github.com` appeared. With `--no-rcs` they disappear. They come from the
shell's rc files, not from libghostty. The real helper will have to explain
these prompts, because a terminal is the process responsible for whatever the
user's shell starts.
