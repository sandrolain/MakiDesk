# MakiDesk — development

MakiDesk is a Swift Package Manager executable; there is no `.xcodeproj`. The
app bundle is assembled from the SwiftPM product plus `Resources/`.

- [Requirements](#requirements)
- [Build and run](#build-and-run)
- [Task commands](#task-commands)
- [Signing and permissions](#signing-and-permissions)
- [Tests](#tests)
- [Project layout](#project-layout)
- [Dependencies and generated files](#dependencies-and-generated-files)
- [Debugging](#debugging)
- [Release](#release)

## Requirements

- macOS 14 or later.
- Xcode 15+ (or a Swift 5.9+ toolchain with the macOS SDK).
- [go-task](https://taskfile.dev/) for the convenience tasks (optional; the
  `swift` commands work on their own).
- Network access the first time, to resolve the SwiftPM dependencies.

## Build and run

```sh
git clone https://github.com/sandrolain/MakiDesk.git
cd MakiDesk
task open
```

`task open` builds a release bundle, signs it, and launches `dist/MakiDesk.app`.
Use the bundle, not `swift run`: a raw executable is not a selectable `.app` in
System Settings ▸ Privacy & Security ▸ Accessibility.

For a quick debug loop:

```sh
task build     # swift build
swift test     # unit tests
task reload    # kill the running app, rebuild the signed bundle, relaunch
```

The app is an `.accessory` menu-bar app: quitting it from the Dock is not
possible, use the menu-bar icon or `⌘Q` from its panels.

## Task commands

| Command | What it does |
|---|---|
| `task build` | Debug build. |
| `task run` | `swift run` (not the app bundle). |
| `task test` | `swift test`. |
| `task release` | Optimized release build. |
| `task bundle` | Copy the release binary, Info.plist, icon, licence and notices into `dist/MakiDesk.app`. |
| `task cert` | Create the local `MakiDesk Local Signing` identity once (stable TCC identity). |
| `task sign` | Sign the bundle with that identity, or ad-hoc if it is missing. |
| `task open` | Build, sign, launch. |
| `task reload` | Kill, build, sign, relaunch. |
| `task install` | Copy the signed app to `~/Applications`. |
| `task dmg` | Sign with the local identity and create a local DMG. |
| `task dmg-only` | Package the current `dist/MakiDesk.app` without re-signing (Developer ID path). |
| `task reset-permission` | `tccutil reset Accessibility com.makidesk.app`. |
| `task clean` | SwiftPM clean. |

## Signing and permissions

macOS keys Accessibility and Screen Recording grants to the app's **code
identity**. An ad-hoc signature changes with every build, so the permission is
lost. Run this once:

```sh
task cert
task reset-permission   # optional: clear the old ad-hoc entry
task open
```

Then add MakiDesk in System Settings ▸ Privacy & Security ▸ Accessibility and
grant Screen Recording. With the self-signed certificate, rebuilds keep the
grant as long as the bundle id (`com.makidesk.app`) and signing identity do not
change. Trusting the certificate system-wide is not required.

For a public release, use a **Developer ID Application** certificate and
notarize the DMG; see [Distribution](DISTRIBUTION.md). Do not distribute a
build signed with the local identity.

## Tests

```sh
swift test
```

The suite is pure where possible (geometry, advisor, groups, shake, catalogue,
focus-border placement) and uses temporary directories/pasteboards for
persistence and clipboard. It currently has **235 tests**. Add cases next to
the existing ones; keep the engines free of AppKit so they stay testable.

## Project layout

```
Sources/
  MakiDesk/          the app, one target
  GrammarScanners/   vendored grammar scanners (C)
Tests/
  MakiDeskTests/     SwiftPM tests
Resources/
  Info.plist         bundle plist (version, id, minimum macOS)
  AppIcon.icns       app icon
docs/                usage, architecture, distribution, privacy, assets
dist/                generated app and DMG (git-ignored)
refs/                third-party checkouts used for analysis (git-ignored)
Taskfile.yml         build/sign/package tasks
Package.swift        dependency and target graph
```

## Dependencies and generated files

- A syntax runtime and nine grammar packages; `Package.resolved` pins the exact
  graph and is committed so a fresh checkout resolves the same versions. Their
  licences are in `THIRD_PARTY_NOTICES.md`.
- `Sources/GrammarScanners` exists because the JavaScript, Python and CSS
  grammar manifests decide whether to compile `scanner.c` with a path relative
  to the current working directory. SwiftPM therefore leaves it out; the
  scanners and their parser headers are vendored and linked as a C target.
- `Sources/MakiDesk/NotesGrammarQueries.swift` embeds the grammars'
  `queries/highlights.scm` as strings. It is generated from the checkouts; if a
  grammar is updated, regenerate it from the new query files instead of editing
  the strings by hand.
- The app uses no analytics, networking SDK, database or private API.

## Debugging

- The app writes status to the small HUD and to `status` in the model. Most
  commands are global, so the HUD is the first place to look.
- Unified log messages (layout advice/weights, captures, first run):

  ```sh
  log show --last 10m --predicate 'process == "MakiDesk"'
  ```

- Window control is Accessibility-dependent: some windows are not resizable and
  some apps only expose a frame after a retry. `WindowController` reports those
  refusals; don't silence them.
- The menu-bar panel does not appear in the Dock. To stop it during development
  use the menu-bar Quit item or `pkill -x MakiDesk`.

## Release

For a local DMG:

```sh
task dmg
```

This signs with the local identity and writes `dist/MakiDesk-<version>.dmg`. For
a public release use a Developer ID, hardened runtime, a universal binary and
notarization; the full procedure is in [Distribution](DISTRIBUTION.md).
