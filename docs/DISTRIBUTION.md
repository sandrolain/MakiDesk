# MakiDesk — distribution

MakiDesk is MIT-licensed and can be redistributed. The source and every runtime
dependency use permissive licences; the build is outside the Mac App Store by
design. This page is the practical release checklist.

- [What is ready](#what-is-ready)
- [Current state](#current-state)
- [Local DMG](#local-dmg)
- [Public release](#public-release)
- [Notarization](#notarization)
- [GitHub release](#github-release)
- [Versioning and identity](#versioning-and-identity)
- [App Store](#app-store)

## What is ready

| Item | State |
|---|---|
| App licence | MIT (© 2026 Sandro Lain); `LICENSE` in the repo and app bundle. |
| Dependencies | Third-party runtime, grammars and scanners; all permissive, no copyleft. Licences in `THIRD_PARTY_NOTICES.md`. |
| Notices | `THIRD_PARTY_NOTICES.md` in the repo, the app bundle and the DMG; also openable from Settings ▸ General ▸ Licensing. |
| Packaging | `task dmg` builds a DMG with the app, `/Applications` link, licence, notices and README. |
| Source | SwiftPM; `Package.resolved` committed for a reproducible graph. |

The app's own MIT terms are in [LICENSE](../LICENSE). Third-party terms and the
grammar copyrights are in [THIRD_PARTY_NOTICES](../THIRD_PARTY_NOTICES.md).

## Current state

The local development DMG is **not distribution-ready**:

- it is **arm64-only**;
- it is signed with the local self-signed identity `MakiDesk Local Signing`
  without the hardened runtime;
- Gatekeeper rejects it on another Mac (`spctl -a -vv` → rejected).

The source can be published and built by anyone today. For a smooth download,
complete the path below.

## Local DMG

```sh
task dmg
```

This runs the release build, signs with the local identity and writes
`dist/MakiDesk-<version>.dmg`. Open it, drag MakiDesk to Applications, and test
on the same Mac. It is useful for local testing and for checking the contents;
do not publish this artifact.

`task dmg-only` packages the current `dist/MakiDesk.app` **without** re-signing.
Use it in the Developer ID flow, after you have replaced the local signature.

## Public release

### 1. Apple Developer Program

Join the Apple Developer Program and create a **Developer ID Application**
certificate. Notarization requires a paid membership. The local certificate used
by `task cert` cannot be notarized.

### 2. Universal build

Build for both Apple Silicon and Intel (macOS 14+):

- with Xcode, archive the executable and set **Architectures** to
  `arm64 x86_64`;
- or with SwiftPM, build both architectures and combine the products with
  `lipo` (or use a multi-arch SwiftPM invocation supported by your toolchain).

The current `task release` builds the host architecture only.

### 3. Sign with hardened runtime

`task bundle` builds the **host** architecture, so use it to create the bundle
and resources first, then copy the universal executable over the one it wrote.
Sign the app **after** that:

```sh
codesign --force --options runtime --timestamp \
  --sign "Developer ID Application: Your Name (TEAMID)" \
  dist/MakiDesk.app
codesign --verify --deep --strict --verbose=2 dist/MakiDesk.app
```

The app needs no special entitlements: Accessibility and Screen Recording are
user-granted TCC permissions, not sandbox entitlements. Do not add `--deep` as a
substitute for signing nested code; this app has no nested frameworks, so the
single app signature is enough.

### 4. Build and sign the DMG

```sh
task dmg-only
codesign --force --timestamp \
  --sign "Developer ID Application: Your Name (TEAMID)" \
  dist/MakiDesk-<version>.dmg
```

The DMG contains the app, an `/Applications` symlink, `LICENSE`,
`THIRD_PARTY_NOTICES.md` and `README.md`.

## Notarization

Store an app-specific password or API key in a `notarytool` keychain profile
once:

```sh
xcrun notarytool store-credentials "notary" \
  --apple-id "you@example.com" --team-id TEAMID
```

Submit and staple:

```sh
xcrun notarytool submit dist/MakiDesk-<version>.dmg \
  --keychain-profile "notary" --wait
xcrun stapler staple dist/MakiDesk-<version>.dmg
xcrun stapler validate dist/MakiDesk-<version>.dmg
spctl -a -vv dist/MakiDesk.app
```

`spctl` should say *accepted* with a *source=Notarized Developer ID*. Test the
DMG on a Mac that has never seen the app, with a normal download (quarantine
attribute) — that is the real Gatekeeper test. If notarization reports a
problem, fix the signature and resubmit; do not ask users to bypass Gatekeeper.

## GitHub release

1. Commit the source, `Package.resolved`, `LICENSE` and
   `THIRD_PARTY_NOTICES.md`. Do **not** commit `refs/` (third-party checkouts
   used for analysis) or `dist/`.
2. Tag the release (`v0.2.0`, matching `CFBundleShortVersionString`).
3. Attach the notarized DMG and a SHA-256 checksum:
   `shasum -a 256 dist/MakiDesk-0.2.0.dmg`.
4. Write release notes: requirements, permissions, known limitations, changes.
5. Keep the bundle id and signing identity stable across releases; updates
   otherwise lose the Accessibility/Screen Recording grants.

There is no auto-updater today. Users install a new DMG over the old app. If an
update feed is added later, sign its appcast and keep the same identity.

## Versioning and identity

- `Resources/Info.plist` holds `CFBundleShortVersionString` (release) and
  `CFBundleVersion` (build number). The DMG name follows the short version.
- The bundle id is `com.makidesk.app`. Changing it is a new app for TCC: users
  must grant Accessibility and Screen Recording again.
- Requirements: macOS 14+. The source builds on Apple Silicon and Intel; the
  current local binary is Apple Silicon only.
- The project name is not a trademark clearance: verify that “MakiDesk” is free
  in your jurisdiction before publishing a binary.

## App Store

MakiDesk is **not** offered through the Mac App Store. It needs Accessibility to
drive other apps' windows and a global shake monitor; the App Store sandbox and
review are a poor fit for the current design. Direct distribution, notarized, is
the supported path.
