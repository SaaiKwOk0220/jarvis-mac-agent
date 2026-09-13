# SDD ledger — plan: project info/02_planned/jarvis/docs/superpowers/plans/2026-09-12-mac-agent-foundation.md

## Preflight interface scan

| Tasks | Shared file or interface | Producer → consumer | Finding / ruling |
|---|---|---|---|
| 1 → 2 | `Task`, `ToolRequest`, action digest | Domain models are persisted by repositories. | Compatible: both require Codable value types and UUID identifiers. |
| 1 → 3 | `ToolRequest`, `SideEffect`, payload digest | Domain contracts drive policy evaluation and approval validation. | Compatible: exact action digest is defined in Task 1 and validated in Task 3. |
| 1 → 4 | `TaskServiceAPI`, `ToolRequest`, `TaskStatus` | Service implements the domain protocol and state transitions. | Compatible: Task 4 defines implementation without changing contract names. |
| 2 → 4 | task/audit repositories | Service writes state and audit events transactionally. | Compatible: repository protocols are introduced before service construction. |
| 3 → 4 | `PolicyEvaluator`, `PolicyDecision` | Service evaluates every request before dispatch. | Compatible: `submit(request:)` returns the policy decision. |
| 4 → 5 | loopback endpoints, task/approval records | Menu-bar client calls the local service. | Compatible: Task 5 consumes the endpoints Task 4 creates. |
| 2/4 → 6 | SQLite audit and service behavior | End-to-end acceptance exercises persisted decisions. | Compatible: acceptance sequence matches the service and policy contracts. |
| 1 | Own requirements | Codable models and digest helper are paired with direct tests. | Consistent. |
| 2 | Own requirements | Migration/repository/redaction implementation is paired with persistence tests. | Consistent. |
| 3 | Own requirements | Policy defaults and target restrictions are paired with evaluator tests. | Consistent. |
| 4 | Own requirements | State-machine transitions, service endpoints, and no-op executor are paired with unit/integration tests. | Consistent. |
| 5 | Own requirements | UI client decoding is unit-tested; manual launch validates macOS interaction. | Consistent. |
| 6 | Own requirements | Acceptance test follows the defined policy lifecycle. | Consistent. |

Baseline: no Swift package exists before Task 1, so there is no applicable test command. Workspace starts clean at `9ed9231`.

Task 1: fix round 1/5 (1 addressed, 0 open — immutable action digest enforced for construction and Codable decoding; commits 0e2b786..bf9be4b)
Task 1: complete (commits 9ed9231..bf9be4b, review clean)
Task 2: fix round 1/5 (2 addressed, 1 open — JSON/quoted secret redaction and safe corrupt-row decoding fixed; approvals and policy records required persistence repositories; commits 5dd6347..edaf785)
Task 2: fix round 2/5 (2 addressed, 1 open — approvals/policy repositories and additional redaction forms added; username-only URL, direct cookie, escaped JSON remained; commits edaf785..46798d9)
Task 2: fix round 3/5 (1 addressed, 0 open — raw SQLite audit tests cover username-only URL, direct cookie, and escaped JSON secrets; commits 46798d9..6d26a8a)
Task 2: complete (commits bf9be4b..6d26a8a, review clean)
Task 3: fix round 1/5 (5 addressed, 1 open — command grammar, fail-closed sends, delete containment, scope-bound approvals, browser HTTPS/profile restrictions fixed; URL scheme classification remained; commits 205de7f..fc7c8eb)
Task 3: fix round 2/5 (1 addressed, 0 open — all URL schemes classify through strict browser gate; commits fc7c8eb..4492d7a)
Task 3: complete (commits 6d26a8a..4492d7a, review clean)
Round 1 findings: persistence UoW and request repository were added in d1697e6, but the implementer reported remaining gaps. Continue fix loop: add restart/approval/rejection/transaction/cancellation/parser tests; remove fatalError config path; correct cancellation target; atomic result/failure; verify real localhost transport.
Task 4: fix round 1/5 (6 open -> partial persistence/network hardening in d1697e6; re-review kept all 6 critical findings open)
Task 4: fix round 2/5 started at 924de67; re-review still open C2/C3/C4/C6 plus migration compatibility.
Ruling: task 4 remains in fix loop because service still fails atomicity/cancellation/failure requirements; do not advance tasks until all critical findings are closed.
Task 4: fix round 2/5 (migration, single-op transactions, failure audit and HTTP bounds addressed in 1fd7fb5; re-review keeps critical cross-instance submit/cancel race, execution tracking, and mixed-repository persistence contract open).
Task 4: fix round 3/5 (all remaining critical findings addressed in 1c97f7f; scoped re-review clean; full Xcode XCTest 55/55 passed)
Task 4: complete (commits 4492d7a..1c97f7f, independent review clean)
Task 5: fix round 1/5 started — reviewer found missing request metadata route, app-owned service bootstrap, and digest-state race; repair must include end-to-end tests.
Task 5: fix round 1/5 complete (6fecc2b..8f7d6f5; request metadata route, local runtime bootstrap, async digest update; independent review clean; full Xcode XCTest 63/63 passed)
Task 5: complete (commits eaeec55..8f7d6f5)
Task 6: complete (commit ce96d28; README and FoundationAcceptanceTests added; full Xcode XCTest 64/64 passed; clean product build and diff check)
Final branch review: initial whole-branch review identified inaccessible task detail, missing task creation/demo flow, static/stale timeline, and unstable equal-timestamp audit ordering. All addressed in c7bafa1, 28aff59, and 419ca07; independent final review clean.
Final verification: full Xcode XCTest 69/69, `swift build --product JarvisMenuBar`, `swift run JarvisMenuBar` startup, and `git diff --check` all passed.
