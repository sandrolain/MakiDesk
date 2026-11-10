# MakiDesk Docker — helper

A native window over the Docker CLI. It is a separate app, like the terminal:
`swift build` at the repository root does not build it, and it has no binary
dependency.

## Try it

```sh
task docker:run
```

The helper is built into `dist/MakiDeskDocker.app` and copied into
`MakiDesk.app/Contents/Applications/` by `task bundle`. A development
`swift run` of MakiDesk looks for the same `dist/` path.

## What it does

- Containers grouped by Compose project and by Standalone, with start, stop,
  restart, pause, kill, delete, logs, stats, inspect and a terminal.
- Images, volumes and networks with size, usage and safe removal.
- Cleanup with a preview, `docker system prune` and the destructive
  `docker system prune --all --volumes`.
- Docker contexts; remote contexts are marked and every destructive action
  names the host.
- The terminal action opens a workspace in **MakiDesk Terminal**; MakiDesk
  relays the request to the terminal helper, so the terminal keeps its
  one-client socket.

The Docker window owns `~/Library/Application Support/MakiDesk/Docker/`:
`window.json`, `settings.json` and `theme.json` (the last written by MakiDesk).
It never persists logs, inspect output or environment variables.
