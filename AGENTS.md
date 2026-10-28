# MakiDesk — agent instructions

Applies to the entire repository. Follow the user's current scope; preserve unrelated local changes. Keep this file concise and update it when architecture or commands change. Use English for source comments and existing English UI; communicate with the user in their language.

## Project and navigation

Native macOS menu-bar app controlling **real windows** through Accessibility (AX), with a window switcher, overlays, clipboard, notes and Shelf. SwiftPM executable, Swift tools 5.9, macOS 14 minimum; SwiftUI + AppKit, ScreenCaptureKit, Tree-sitter and C grammar scanners. Do not assume a web app, Xcode project or Swift 6 language mode.

Read only the relevant paths before editing:

| Area | Main files |
| --- | --- |
| App lifecycle, shortcuts, settings | `MakiDeskApp.swift`, `ShortcutManager.swift`, `SettingsView.swift` |
| Commands and model orchestration | `WorkspaceStore.swift` |
| AX discovery, identity, events, frame operations | `WindowIndex.swift`, `WindowController.swift`, `AXFrameWriteCoordinator.swift` |
| Geometry and layout | `CanvasCore.swift`, `TilingEngine.swift`, `LayoutAdvisor.swift`, `WindowScene.swift`, `WindowGroup.swift` |
| Switcher, ordering, screen choice | `WindowPalette.swift`, `PaletteOrdering.swift`, `PaletteScreenLocation.swift` |
| Captures and overlays | `WindowCapture.swift`, `WindowOutlineController.swift`, `MiniMapController.swift`, `PeekController.swift`, `PeekPanel.swift` |
| Panel focus restoration | `PanelFocusReturn.swift`, `ClipboardPanel.swift`, `NotesPanel.swift`, `ShelfController.swift` |
| Notes and incremental editor | `NotesStore.swift`, `NotesEditor.swift`, `NotesSyntax.swift`, `NotesHighlightDiff.swift`, `NotesLineIndex.swift` |
| Drag and image transfer | `WindowDrag.swift`, `ShelfController.swift`, `ShelfImageWriter.swift` |
| Persistence and migration | `GroupStore.swift`, `NotesStore.swift`, `LegacyMigration.swift` |

Swift files above are under `Sources/MakiDesk/`; tests are under `Tests/MakiDeskTests/`. Package/dependency configuration is in `Package.swift` and `Package.resolved`; bundling/signing commands are in `Taskfile.yml`; app metadata is in `Resources/Info.plist`.

For performance or lifecycle work, read the findings and current implementation ledger in [the 2026-10-26 analysis](docs/analisi-ottimizzazioni-refactoring-bug-2026-10-26.md) and the findings B01–B11 with their implementation ledger in [the 2026-10-28 analysis](docs/analisi-performance-bug-2026-10-28.md). Verify historical claims against current code.

## Workflow and change scope

- Inspect `git status` and the relevant diff first. Never reset, stash, overwrite or remove someone else's edits to obtain a clean baseline.
- After every significant change (code, tests or behavior docs), propose a [Conventional Commits](https://www.conventionalcommits.org/) message (`type(scope): summary`, e.g. `fix:`, `perf:`, `docs:`) with a short body grouping the affected areas and what was verified. Wait for the user's confirmation before committing; then stage only the files belonging to that change and never bundle unrelated edits.
- Trace the caller, state owner, asynchronous completion and teardown before changing a shared API. Use `rg` to locate all callers.
- Fix the cause with a focused change. Preserve existing dependency injection and pure geometry helpers; avoid adding another global cache or controller for state already owned elsewhere.
- Keep model/discovery in the index and store, AX primitives in the controller, presentation in panels, and pure layout logic independent of AppKit I/O. Avoid growing `WorkspaceStore` or `ShelfController` with unrelated responsibilities.
- Preserve persisted keys, defaults and formats unless the task requires a compatible migration. Update README/settings documentation when behavior changes.
- Do not upgrade dependencies, regenerate lockfiles, change signing identity or mix broad refactoring into a bug fix without a task-related reason.

## Responsiveness and concurrency invariants

- **No synchronous global AX discovery on the main thread**, in shortcuts, view rendering, panel opening, focus callbacks or monitor changes. Use `WindowIndex.snapshot()` for immediate reads; request asynchronous discovery explicitly. A getter must not perform hidden I/O because a TTL expired.
- Keep launch usable while inventory, note restoration and observer registration run. Dependent recovery/layout actions must await the appropriate loaded state; an empty initial model is not a completed inventory.
- `Task { @MainActor in ... }` does not move blocking work off the main thread. Put expensive discovery, parsing, search, encoding and ordinary disk I/O on their designated worker/executor; publish UI state on the main actor/queue.
- Do not add main-thread `sync`, semaphore waits, group waits, sleeps or synchronous flushes to interactive paths. Preserve intentional termination durability fences until an equivalent shutdown protocol exists.
- Every asynchronous pipeline needs an owner, a generation/revision or equivalent validity check, cancellation/teardown, and a bound on queued work. Check validity **when publishing**, even on cache hits; cancellation alone does not prevent stale callbacks.
- Coalesce concurrent inventory requests. Discard superseded results without losing callers waiting for a valid result. Preserve confirmed geometry updates made while discovery was in flight.
- Validate deferred commands against current command generation, foreground app, target identity and availability before applying them. Old layout or capture work must not override a newer user command.
- Make thread ownership explicit. Prefer actor isolation or narrowly synchronized value transfer. Do not silence concurrency diagnostics using broad `@unchecked Sendable`, `nonisolated(unsafe)` or `MainActor.assumeIsolated` without a documented, enforceable ownership invariant.
- Keep callbacks on the expected executor; avoid mutable captured variables shared across workers and timers. Account for reentrancy when callbacks can close/reopen panels or trigger another command.

## AX inventory and window commands

- AX calls are cross-process and can stall or fail. Use object-local messaging timeouts, bounded transient retries and backoff. Unsupported notifications are permanent failures; do not retry them forever.
- Keep observer registration off the main thread, callbacks on the intended run loop, and cleanup symmetric. Register window notifications on window elements. Bound observers and remove terminated processes from related caches.
- Focus/geometry events should update the affected target, not invalidate the entire desktop. Use PID-scoped inventory refresh when the changed app is known; reserve global refresh for genuinely global changes.
- Window identity must survive enumeration reordering. Never use an enumeration index or title alone as durable identity; reserve existing IDs before assigning new ones. CG window numbers and PIDs can be reused after destruction/termination.
- Distinguish absent, minimized, parked and temporarily unavailable windows. A timeout is not proof of closure. Keep uncertainty explicit; do not silently move a stale/unavailable target or replace an explicit selection with all windows.
- AX writes can be rejected, constrained or rounded by applications. Preserve ordered position/size operations, error handling and verification of actual geometry. Respect Reduce Motion. Avoid redundant writes and unbounded intermediate animation frames.
- Existing animation writes still run on the main thread (N13). Do not add more blocking work there. Any off-main replacement must serialize writes per target, coalesce superseded frames and preserve completion/verification semantics.

## Switcher, focus and multiple displays

- MRU ordering uses actual focus history, with deterministic alphabetical fallback and a stable identity tie-break. Freeze visual order during an open palette session: remove vanished windows, append new ones and preserve selection by ID.
- One forward `⌥Tab` selects the previous window relative to the opening origin, enabling repeated A↔B switching. Preserve reverse cycling, rapid Option release and repeated shortcuts while the first inventory is pending. Search and browse have different initial-selection semantics.
- Utility panels must capture their return destination **before taking focus**, using `PanelFocusReturn`. Consume restoration once before hiding to avoid reentrant dismissals; restore only when the panel still owns keyboard focus. Never steal focus after the user has chosen another app. Preserve nested panel/responder restoration.
- Palette acceptance activates its selected target; cancellation returns appropriately. Quick Look dismissal within Shelf must respect Shelf's own keyboard session.
- Choose palette display from the persisted focused-window/mouse preference once per opening; keep sizing and placement on that display throughout the session. Handle monitor removal with a valid fallback.
- Respect AppKit/AX/CG coordinate conversions, each display's origin, `visibleFrame` and backing scale. Negative global coordinates are valid. Never assume the main screen, identical scale factors or a zero origin. Reuse existing conversion helpers.
- Validate frame dimensions and finite values without clamping all global origins to positive coordinates. Preserve off-screen parking and recovery behavior.

## Capture, timers and memory

- Share the screenshot budget across palette, Peek and scoring; keep queues bounded and prioritize selected/visible cards. Stop scheduling on hide/disable and reject obsolete session/dimension callbacks.
- Budget **both** capture cache and UI-held images; cache eviction alone cannot release images still retained by the UI. Account for pixel bytes, backing scale and dimensions, not just entry count. Current budgets are 64 MiB capture cache and 32 MiB palette images; these are not a total RSS guarantee.
- Cache keys must include window identity and requested size, not a recyclable CG number alone. Separate freshness from LRU access; provide icon fallbacks without Screen Recording permission or while images arrive.
- Give timers/tasks/observers an explicit shutdown path. No polling when a feature is disabled; use lower idle frequency and failure backoff. Debouncing must not invalidate unrelated useful work or create an unbounded backlog.
- Shelf drag initiation must not eagerly encode all image formats. Preserve promised representations, bounded preparation/cache and Quick Look session checks. The first uncached format request can still block (N15); do not claim it is fully asynchronous.

## Notes, persistence and privacy

- Keep parser/tree/query ownership on the syntax worker. Preserve incremental UTF-16 range handling, Unicode/surrogate correctness, dirty-range styling and incremental line indexing. Large notes must not trigger a full parse/style/line scan on every keystroke.
- Search results and external-file callbacks need revision checks. Late completion must not overwrite a newer draft, save, selected note or file association.
- Serialize persistence, use atomic replacement where appropriate, and clear dirty state only after successful writes for the same revision. Keep failed writes retryable and report errors; preserve drafts through panel closure and termination.
- Preserve external-file conflict detection, security-scoped access lifetime and Save As semantics. Migration must be idempotent and must not overwrite newer data or mark a failed migration complete. Reset behavior must preserve documented user data.
- Note restoration still loads all draft bodies (N17). A future lazy-loading design must preserve search, crash recovery and external baseline checks rather than treating unloaded text as empty.
- Use temporary directories and isolated defaults/providers for verification. Do not modify the user's real notes, groups, clipboard archive, TCC settings or system tiling preference as a test fixture.
- Log durations, counts, revisions and technical IDs. Avoid public logging of window titles, note/clipboard contents, file paths or screenshots.

## Build, verification and reporting

Run commands from the repository root. For documentation-only changes, inspect the diff and links; building or launching the app is unnecessary.

```sh
swift build
swift build -c release
# When tests are requested:
swift test
swift test --filter WindowInventoryTests
# When a concurrency audit is requested or part of the agreed scope:
swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency
git diff --check
```

`task build`, `task release` and `task test` wrap the corresponding commands. Run SwiftPM operations sequentially against a shared build directory. In restricted environments, use writable module/cache paths and `--disable-automatic-resolution` when dependencies are already available. The analysis document records the local workaround for nested SwiftPM sandbox failures; do not confuse that build workaround with app permissions or change the app's security configuration.

- Add/run tests when requested by the user or included in the agreed verification scope. For regressions, prefer injected providers and deterministic pure tests over sleeps or the real desktop. Cover stale callbacks, rapid reopen, initial empty state, unavailable AX targets, duplicate IDs and Unicode where relevant.
- Do not weaken assertions or silently skip tests to get a green suite. Report environment-dependent skips separately. A successful build or unit suite does not prove GUI latency, focus restoration or multi-monitor correctness.
- Use release builds for performance comparisons. Separate keyboard→handler, inventory wait, AX reads/writes, first visible response and animation duration. Smooth animation does not rule out delayed execution.
- Compare first/repeated resize, focus changes, rapid switcher use and internal/external displays. Report environment, sample count, median/p95/max and cache state for measured claims. Historical 1.56 s discovery logs are not measurements of the current revision.
- `task open` launches a new instance; `task reload` kills the running app; install/sign/certificate/TCC commands affect the user's environment. Use them only when relevant and authorized by the task. Avoid duplicate instances competing for global shortcuts. Raw `swift run` is not equivalent to the signed bundle for permissions.
- Do not reset permissions, create certificates or alter system preferences to make an ordinary build pass. Preserve bundle ID `com.makidesk.app`, signing setup and minimum OS compatibility.
- Report what changed, what was actually checked, skips/warnings, and remaining risks. Update the analysis ledger when implementing a tracked finding; distinguish code changes, partial mitigation and measured resolution. Current open areas include N13, N15, N17 and UI concurrency isolation—verify their current state before continuing.
