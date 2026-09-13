# Jarvis Mac Agent

> Mac-first personal agent foundation: menu-bar UI, local task service, deterministic policy gates, SQLite persistence, auditable timeline.

This is the public-facing README. The agent-team workflow lives in [AGENTS.md](AGENTS.md).

## What it is

A macOS menu-bar app that runs tasks locally, gates every protected action behind a deterministic policy + explicit approval, persists everything in SQLite, and shows the user a fully auditable timeline.

- ✅ Task creation, detail view, timeline, audit
- ✅ Demo approval flow (local-draft → awaiting_approval → approve/reject)
- ✅ State machine + concurrency safety + local loopback HTTP service
- ✅ 73 unit + integration + acceptance tests passing
- 🚧 Real planners and workers (terminal, browser, Accessibility / ScreenCaptureKit) are intentionally **not** included yet — only the `NoOpToolExecutor` demo is shipped today

## Requirements

- macOS 14 or newer
- Xcode 15+ (full Xcode, not just the command-line tools)

## Build and test

```sh
cd project info/02_planned/jarvis/app
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Run the menu bar:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift run JarvisMenuBar
```

The menu-bar process creates its SQLite database at `~/Library/Application Support/Jarvis/jarvis.sqlite` and starts an HTTP JSON service bound only to `127.0.0.1` on an ephemeral port. The client is configured to that port at startup; no remote gateway is exposed.

## Architecture

| Module | Role |
|---|---|
| `JarvisDomain` | Task models, status, request/approval types |
| `JarvisPolicy` | Deterministic policy gate: which actions require approval |
| `JarvisPersistence` | SQLite repositories (tasks, requests, approvals, audit, policy rules) |
| `JarvisService` | `TaskService` (state machine + concurrency) + `LoopbackServer` (HTTP JSON) |
| `JarvisMenuBar` | SwiftUI menu bar UI: task list, detail, approval view, new task window |

All protected actions pause in `awaiting_approval` and require explicit approval for the exact action digest. Audit events are persisted with secret-shaped values redacted.

## Source layout

```
project info/02_planned/jarvis/app/
├── Package.swift
├── README.md                     ← package-specific build/test details
├── Sources/
│   ├── JarvisDomain/
│   ├── JarvisPolicy/
│   ├── JarvisPersistence/
│   ├── JarvisService/
│   └── JarvisMenuBar/
└── Tests/
    ├── JarvisDomainTests/
    ├── JarvisPolicyTests/
    ├── JarvisPersistenceTests/
    ├── JarvisServiceTests/
    ├── JarvisMenuBarTests/
    └── JarvisAcceptanceTests/    ← end-to-end through real LoopbackServer
```

## Known limitations

The foundation deliberately narrows the demo flow: each task carries **at most one tool request**. After a successful executor run the task transitions to `.completed`, and a subsequent `submit(request:)` on that task will throw `illegalTransition(from: .completed, to: .running)`. This is documented in the `execute(_:)` doc comment in `TaskService.swift`. If multi-request tasks become a requirement, the state machine and persistence layer will need to be relaxed.

## License

Private — not yet licensed for redistribution.