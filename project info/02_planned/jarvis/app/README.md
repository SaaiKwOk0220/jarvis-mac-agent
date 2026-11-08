# Jarvis Mac Agent Foundation

Mac-first personal agent foundation with a menu-bar UI, local task service, deterministic policy gates, SQLite persistence, and an auditable timeline.

## Requirements

- macOS 14 or newer
- Xcode 15+ (full Xcode, not only the command-line tools)

## Build and test

Run the commands below from the repository root.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --package-path 'project info/02_planned/jarvis/app'
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
bash 'project info/02_planned/jarvis/app/scripts/build-dev-app.sh'
```

The script prints the path of a newly created development `Jarvis.app`. Open
that path in Finder or run `open '/path/printed/by/script/Jarvis.app'`. Each
build uses a separate directory under `.build/dev-app`, so it does not replace
an existing app. This is an unsigned development bundle, not a release or
installer. Close any previous Jarvis instance before launching another; the
global shortcut is Cmd+Shift+J. New builds refuse to start when another new
Jarvis instance holds the process lock; older builds do not participate in that
lock, so close them manually first. Do not remove or replace the private
`~/Library/Application Support/Jarvis/instance-lock` directory while Jarvis
is running; doing so can invalidate the lock. The app continues to use the existing Jarvis
application-support database.

Run the packaging smoke test with `bash 'project info/02_planned/jarvis/app/Tests/Packaging/test-bundle.sh'`.

The menu-bar process creates its SQLite database at
`~/Library/Application Support/Jarvis/jarvis.sqlite` and starts an HTTP JSON
service bound only to `127.0.0.1` on an ephemeral port. The client is configured
to that port at startup; no remote gateway is exposed.

Protected actions pause in `awaiting_approval` and require an explicit approval
for the exact action digest. Approval and rejection never happen implicitly from
notifications. Audit events are persisted with secret-shaped values redacted.

To exercise the foundation without a planner or worker, create a task from the
menu bar, open its detail window, and choose **Start demo approval**. This creates
a local-draft proposal under Jarvis application support, pauses for an exact-digest
approval, and then runs only the no-op demo executor. The timeline records each
state transition, policy decision, approval, and result.

The bundled `NoOpToolExecutor` is a demo executor used to exercise the complete
state and approval flow. Terminal workers, browser workers, and Accessibility or
ScreenCaptureKit GUI workers are intentionally not included yet.
