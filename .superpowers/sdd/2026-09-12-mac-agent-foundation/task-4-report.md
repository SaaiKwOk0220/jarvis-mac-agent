# Task 4 report — local task service and state machine

## Changed files

- `project info/02_planned/jarvis/app/Package.swift`
  - Adds the `JarvisService` library target and its XCTest target.
- `project info/02_planned/jarvis/app/Sources/JarvisService/TaskStateMachine.swift`
  - Defines the explicit, fail-closed legal transition graph.
- `project info/02_planned/jarvis/app/Sources/JarvisService/TaskService.swift`
  - Implements task creation/querying, protected-request submission, digest-bound approval/rejection, cancellation, no-op execution, and redacted audit orchestration.
- `project info/02_planned/jarvis/app/Sources/JarvisService/LoopbackServer.swift`
  - Implements loopback-only JSON routes and a localhost-bound HTTP listener.
- `project info/02_planned/jarvis/app/Tests/JarvisServiceTests/TaskServiceTests.swift`
  - Covers legal and illegal transitions, persisted awaiting-approval state, digest mismatch, cancellation, audit creation/redaction, in-process JSON routing, remote-peer rejection, and a real localhost HTTP round trip.

## Design and invariants

- State changes use a single lock around read/validate/write/audit orchestration. The transition graph is explicit and terminal states have no outward transitions.
- `submit` always records the request and decision before acting. A protected request is retained unchanged by request ID and changes the persistent task state to `awaiting_approval`.
- Approval uses `validateApproval`, which compares the supplied digest against the immutable `ToolRequest` action digest. That digest already binds name, side effect, target, payload, and `ToolScope`.
- Nothing with a protected side effect is handed to an executor before a matching explicit approval. The included executor is deliberately no-op.
- Audit entries deliberately exclude payloads and executor error text. Repository-level secret redaction remains the final defense in depth.
- The API permits only `127.0.0.1`, `::1`, localhost, and IPv4-mapped loopback peers. Its TCP listener binds locally and returns JSON only for creation/list/detail/approval/rejection/cancellation routes.

## Verification

1. Red: the focused service test command initially failed because `JarvisService` did not exist (`Source files for target JarvisService should be located under Sources/JarvisService`).
2. Green: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path 'project info/02_planned/jarvis/app' --filter TaskServiceTests`
   - 8 tests executed, 0 failures, including the real localhost HTTP integration test.
3. Full regression: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path 'project info/02_planned/jarvis/app'`
   - 46 tests executed, 0 failures.
4. `git diff --check` completed without whitespace errors.

## Commit

- `0b767a5 feat: add local task service and state machine`
- `924de67 fix: make task service persistence and loopback handling atomic`

## Unresolved concerns

- The service now requires a persistence unit of work for atomic lifecycle writes and persists immutable requests, scopes, statuses, and approvals. Custom non-SQLite repositories must supply a matching `PersistenceUnitOfWork` implementation.
- Cooperative cancellation depends on executors observing Swift task cancellation; the service suppresses completion for already-cancelled tasks and marks pending requests cancelled.

### Third-round hardening

- Added a separate upgrade migration for persisted request scope columns, preserving existing installations.
- Added transactional request receipt/result/failure/cancellation methods, restart-safe injected repositories, task-scoped cooperative cancellation, bounded/redacted result summaries, and malformed-header rejection.
- Focused service suite now covers 12 tests with zero failures, including restart approval/rejection, executor failure, and cancellation suppression.
