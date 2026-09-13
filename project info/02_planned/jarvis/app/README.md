# Jarvis Mac Agent Foundation

Mac-first personal agent foundation with a menu-bar UI, local task service, deterministic policy gates, SQLite persistence, and an auditable timeline.

## Requirements

- macOS 14 or newer
- Xcode 15+ (full Xcode, not only the command-line tools)

## Build and test

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --package-path 'project info/02_planned/jarvis/app'
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift run --package-path 'project info/02_planned/jarvis/app' JarvisMenuBar
```

The menu-bar process creates its SQLite database at
`~/Library/Application Support/Jarvis/jarvis.sqlite` and starts an HTTP JSON
service bound only to `127.0.0.1` on an ephemeral port. The client is configured
to that port at startup; no remote gateway is exposed.

Protected actions pause in `awaiting_approval` and require an explicit approval
for the exact action digest. Approval and rejection never happen implicitly from
notifications. Audit events are persisted with secret-shaped values redacted.

The bundled `NoOpToolExecutor` is a demo executor used to exercise the complete
state and approval flow. Terminal workers, browser workers, and Accessibility or
ScreenCaptureKit GUI workers are intentionally not included yet.
