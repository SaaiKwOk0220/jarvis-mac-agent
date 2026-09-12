# Mac Agent Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver a runnable Mac-first foundation with a menu-bar UI, local task service, deterministic approval policy, persistent task state, and an auditable timeline.

**Architecture:** A SwiftUI menu-bar app communicates only with a local task service over a typed localhost API (or XPC if the implementation environment supports it cleanly). The service owns SQLite, state transitions, policy checks, approvals, cancellation, and audit events; future agent planners and workers plug into explicit service interfaces and never receive direct OS authority.

**Tech Stack:** Swift 5.9+, SwiftUI, macOS 14+, Swift Package Manager, SQLite via GRDB.swift, XCTest, local HTTP over loopback for the initial IPC boundary.

**Spec:** `project info/02_planned/jarvis/docs/2026-09-12-mac-agent-mvp-design.md`

## Global Constraints

- The product is single-user and local to one Mac; no internet-facing gateway or external chat channel.
- Model output is an execution request, never an authorization decision.
- Protected actions require explicit approval bound to an exact action digest.
- Core states are `draft`, `planning`, `running`, `awaiting_approval`, `blocked`, `failed`, `cancelled`, and `completed`.
- SQLite is the source of truth for tasks, approvals, policy, and audit records.
- No credentials, cookies, or unredacted secrets may enter audit events.
- All external sends, uploads, deletes, credential changes, and privilege expansion require approval; money actions are unsupported.
- Every task must be cancellable from the menu-bar UI.

---

## File Map

Create a Swift package at `project info/02_planned/jarvis/app/` with these boundaries:

- `Package.swift`: package metadata and pinned dependencies.
- `Sources/JarvisDomain/`: value types, task states, side-effect classes, and service protocols; no UI or database imports.
- `Sources/JarvisPersistence/`: GRDB schema, repositories, migrations, and redaction.
- `Sources/JarvisPolicy/`: deterministic policy evaluation and approval digest validation.
- `Sources/JarvisService/`: task state machine, cancellation, audit orchestration, and loopback API.
- `Sources/JarvisMenuBar/`: SwiftUI menu-bar app, task list/detail, approval dialog, and notifications.
- `Tests/`: unit and integration tests matching the modules above.

### Task 1: Scaffold the package and domain contracts

**Files:**
- Create: `project info/02_planned/jarvis/app/Package.swift`
- Create: `project info/02_planned/jarvis/app/Sources/JarvisDomain/TaskModels.swift`
- Create: `project info/02_planned/jarvis/app/Sources/JarvisDomain/ToolContracts.swift`
- Create: `project info/02_planned/jarvis/app/Tests/JarvisDomainTests/TaskModelsTests.swift`

**Interfaces:**
- `enum TaskStatus: String, Codable` with the eight states in the global constraints.
- `enum SideEffect: String, Codable` with `read`, `local-execute`, `local-write`, `external-send`, `upload`, `delete`, `credential`, `money`.
- `struct Task: Codable, Identifiable` containing `id: UUID`, `title: String`, `status: TaskStatus`, `createdAt: Date`, `updatedAt: Date`.
- `struct ToolRequest: Codable, Identifiable` containing `id`, `taskID`, `name`, `sideEffect`, `target`, `payload: String`, `payloadDigest: String`.
- `protocol TaskServiceAPI` declaring `createTask(title:)`, `getTask(id:)`, `listTasks()`, `approve(requestID:digest:)`, `reject(requestID:)`, and `cancel(taskID:)`.

- [ ] Write tests proving status and side-effect Codable round trips and that a digest changes when target or payload changes.
- [ ] Run `swift test --package-path 'project info/02_planned/jarvis/app'`; verify the new tests fail before implementation.
- [ ] Implement the value types and SHA-256 action digest helper without persistence or UI dependencies.
- [ ] Run the domain test target and verify it passes.
- [ ] Commit with `git add 'project info/02_planned/jarvis/app' && git commit -m 'feat: add Jarvis domain contracts'`.

### Task 2: Add SQLite persistence and redacted audit storage

**Files:**
- Modify: `project info/02_planned/jarvis/app/Package.swift`
- Create: `project info/02_planned/jarvis/app/Sources/JarvisPersistence/Database.swift`
- Create: `project info/02_planned/jarvis/app/Sources/JarvisPersistence/Repositories.swift`
- Create: `project info/02_planned/jarvis/app/Sources/JarvisPersistence/Redaction.swift`
- Create: `project info/02_planned/jarvis/app/Tests/JarvisPersistenceTests/RepositoryTests.swift`

**Interfaces:**
- `final class Database: Sendable` with `init(path: String) throws`, `migrate() throws`, and `read/write` accessors.
- `struct AuditEvent: Codable, Identifiable` with timestamp, task ID, worker, target, side effect, action digest, redacted summary, result, and approval ID.
- `protocol TaskRepository` with `insert`, `updateStatus`, `fetch`, and `list` methods.
- `protocol AuditRepository` with `append(_:)` and `events(for:)`.
- `func redactSecrets(_ input: String) -> String` redacting API-key, cookie, bearer-token, and password-shaped values.

- [ ] Write tests for migration, task round-trip, audit ordering, and redaction of representative secret patterns.
- [ ] Run the persistence tests and verify failure due to missing schema/repositories.
- [ ] Add GRDB migrations for `tasks`, `tool_requests`, `approvals`, `audit_events`, and `policy_rules`; add repository implementations with transactions.
- [ ] Ensure audit insertion always applies `redactSecrets` before writing.
- [ ] Run all package tests and verify they pass.
- [ ] Commit with `git add 'project info/02_planned/jarvis/app' && git commit -m 'feat: persist tasks and redacted audit events'`.

### Task 3: Implement deterministic policy and approval gates

**Files:**
- Create: `project info/02_planned/jarvis/app/Sources/JarvisPolicy/Policy.swift`
- Create: `project info/02_planned/jarvis/app/Sources/JarvisPolicy/Approval.swift`
- Create: `project info/02_planned/jarvis/app/Tests/JarvisPolicyTests/PolicyTests.swift`

**Interfaces:**
- `struct PolicyConfig: Codable` containing approved directories, command names, browser profiles, sites, and application bundle IDs.
- `enum PolicyDecision: Equatable { case allow, case requireApproval(reason: String), case deny(reason: String) }`.
- `protocol PolicyEvaluator { func evaluate(_ request: ToolRequest, config: PolicyConfig) -> PolicyDecision }`.
- `func validateApproval(request: ToolRequest, approvalDigest: String) -> Bool`.

- [ ] Write tests asserting reads and approved local test commands allow; writes, sends, uploads, deletes, credentials, and changed digests require approval or deny.
- [ ] Run policy tests and verify they fail before the evaluator exists.
- [ ] Implement target containment (approved directory must contain the resolved path), exact command allowlisting, application/site allowlisting, and side-effect defaults from the spec.
- [ ] Implement exact digest comparison; never accept an approval for a changed payload, target, or scope.
- [ ] Run policy tests and verify they pass.
- [ ] Commit with `git add 'project info/02_planned/jarvis/app' && git commit -m 'feat: enforce deterministic approval policy'`.

### Task 4: Build the task state machine and local service API

**Files:**
- Create: `project info/02_planned/jarvis/app/Sources/JarvisService/TaskStateMachine.swift`
- Create: `project info/02_planned/jarvis/app/Sources/JarvisService/TaskService.swift`
- Create: `project info/02_planned/jarvis/app/Sources/JarvisService/LoopbackServer.swift`
- Create: `project info/02_planned/jarvis/app/Tests/JarvisServiceTests/TaskServiceTests.swift`

**Interfaces:**
- `final class TaskService: TaskServiceAPI` with `init(taskRepository:auditRepository:policy:)` and the methods in `TaskServiceAPI`.
- `func submit(request: ToolRequest) async throws -> PolicyDecision`.
- `func transition(taskID: UUID, to: TaskStatus) throws` enforcing legal transitions.
- `protocol ToolExecutor { func execute(_ request: ToolRequest) async throws -> ToolResult }` (the foundation ships a no-op demo executor only).

- [ ] Write tests for legal transitions, illegal transition rejection, awaiting-approval persistence, approval digest mismatch, cancellation, and audit event creation.
- [ ] Run service tests and verify they fail before the state machine and service exist.
- [ ] Implement transactional transitions; write an audit event for each request, decision, approval, rejection, result, failure, and cancellation.
- [ ] Implement loopback-only JSON endpoints for task creation/list/detail, approval/rejection, and cancellation; reject non-loopback peers.
- [ ] Run service tests plus a loopback integration test and verify they pass.
- [ ] Commit with `git add 'project info/02_planned/jarvis/app' && git commit -m 'feat: add local task service and state machine'`.

### Task 5: Add the SwiftUI menu-bar shell and approval timeline

**Files:**
- Create: `project info/02_planned/jarvis/app/Sources/JarvisMenuBar/JarvisMenuBarApp.swift`
- Create: `project info/02_planned/jarvis/app/Sources/JarvisMenuBar/ServiceClient.swift`
- Create: `project info/02_planned/jarvis/app/Sources/JarvisMenuBar/TaskListView.swift`
- Create: `project info/02_planned/jarvis/app/Sources/JarvisMenuBar/TaskDetailView.swift`
- Create: `project info/02_planned/jarvis/app/Sources/JarvisMenuBar/ApprovalView.swift`
- Create: `project info/02_planned/jarvis/app/Tests/JarvisMenuBarTests/ServiceClientTests.swift`

**Interfaces:**
- `final class ServiceClient: ObservableObject` with published `tasks`, `selectedTask`, `refresh()`, `approve`, `reject`, and `cancel` methods.
- `@main struct JarvisMenuBarApp: App` exposing a `MenuBarExtra` and a task detail window.

- [ ] Write client decoding tests for task lists, approval requests, errors, and service-unavailable responses.
- [ ] Run tests and verify failure before the client exists.
- [ ] Implement the typed loopback client and menu-bar views; show status, current step, approval reason, target, digest-bound preview, and cancel control.
- [ ] Add macOS notification on `awaiting_approval`, `blocked`, `failed`, and `completed` transitions; do not auto-approve on notification click.
- [ ] Run package tests and manually launch the macOS app with `swift run --package-path 'project info/02_planned/jarvis/app' JarvisMenuBar`; verify task creation, cancellation, and approval UI against the demo executor.
- [ ] Commit with `git add 'project info/02_planned/jarvis/app' && git commit -m 'feat: add Jarvis menu-bar task UI'`.

### Task 6: Foundation acceptance and handoff

**Files:**
- Create: `project info/02_planned/jarvis/app/README.md`
- Create: `project info/02_planned/jarvis/app/Tests/JarvisAcceptanceTests/FoundationAcceptanceTests.swift`

- [ ] Write an end-to-end test that creates a task, allows a read request, pauses on a local write, rejects a changed digest, approves the original digest, cancels a running task, and verifies the complete audit trail.
- [ ] Run `swift test --package-path 'project info/02_planned/jarvis/app'` and verify all tests pass.
- [ ] Document setup, database location, required macOS version, loopback-only boundary, and the demo executor; explicitly state that terminal/browser/GUI workers are not yet included.
- [ ] Run a clean build from a fresh checkout and inspect `git diff --check`.
- [ ] Commit with `git add 'project info/02_planned/jarvis/app' && git commit -m 'docs: document Jarvis foundation and acceptance tests'`.

## Follow-up Plans (separate sub-projects)

After this foundation is accepted, write separate plans for: (1) restricted terminal/project worker, (2) Playwright/browser-use worker, (3) one selected agent orchestrator with durable planning, (4) Accessibility/ScreenCaptureKit GUI fallback, and (5) structured memory plus scheduled low-risk suggestions. Each plan must preserve the service, policy, and audit interfaces above.
