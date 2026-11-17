# MakiDesk Browser

A separate regular app, `MakiDeskBrowser.app`, bundled inside MakiDesk in
`Contents/Applications/`. WebKit, vertical MRU tabs, pinned/active/old groups,
favicon tint, a per-site content blocker, local address suggestions and
on-device Foundation Models page summaries. Its browser chrome follows the
selected MakiDesk palette, while web pages keep their own styles. Incoming
links can be opened in MakiDesk Browser or another installed handler; the
chooser uses a three-column icon grid and remembers recent external-app choices
locally.

- `Sources/MakiBrowser/` — model, WebKit sessions, sidebar/window, blocker,
  favicons and summaries.
- `Sources/MakiDeskBrowser/` — executable and app menu.
- `Tests/MakiBrowserTests/` — pure lifecycle/MRU/time/domain/blocker/persistence
  tests plus the content-rule compilation check.

```sh
swift build --package-path Browser
swift test --package-path Browser
task browser:bundle
task browser:run
task browser:reload
```

The app is `.regular`: its window is a normal window in MakiDesk's AX inventory.
`task bundle` embeds it beside Terminal and Docker; `task reload` stops it before
rebuilding. `task browser:reload` does the same for the browser alone: stop,
rebuild, sign and relaunch.
