# Jarvis MVP Implementation Plan

> **For agentic workers:** Use the project Dev → QA → Review workflow, with independently testable slices and a decision packet for each PR.

**Goal:** Deliver the local-first macOS assistant described in the existing MVP design, starting with a working Qwen model and a policy-gated tool loop.

**Architecture:** Retain the SwiftUI menu-bar client, local TaskService, deterministic policy gate, SQLite persistence, and provider-neutral agent loop. Extend existing contracts instead of allowing the model to bypass the service; keep external actions behind explicit approval.

**Tech Stack:** Swift 6, SwiftUI, SQLite/GRDB, Ollama, macOS Accessibility and ScreenCaptureKit, browser automation where available.

**Spec:** `project info/02_planned/jarvis/docs/2026-09-12-mac-agent-mvp-design.md`.

## Global Constraints

- Protected effects require approval bound to the exact action and scope; model output never authorizes execution.
- Preserve existing user data, existing worktrees and main branch protection. A passing CI and human merge decision are required.
- Task history survives restart; pending or already-approved protected requests must not replay automatically after restart.
- User-approved directory, site and application scopes must be enforced by the executor and policy gate.
- No unattended remote control, external messaging, purchases or continuous wake-word operation in MVP.

## Review Focus

- Missing local model, stopped service, malformed response, cancellation and timeouts produce useful, non-destructive failures.
- Multi-tool calls, response IDs and JSON arguments survive the full provider → agent → service → provider round trip.
- Approval denial, changed payload/scope, concurrent requests and restart cannot execute an unapproved action.
- File paths, symlinks and browser targets cannot escape the approved scope; sensitive data is not leaked to logs.
- GUI permissions, app identity changes and cancellation stop safely; real-device checks supplement automated tests.

## Delivery slices

1. **Local model and agent loop:** Download Qwen3 4B; configure it in Ask Jarvis; fix Ollama tool round trips and offline/model-not-found handling. Test Chinese conversation, tool call/result, approval and rejection, and run `swift test`. Owner: `JarvisLLM`, `JarvisMenuBar` and corresponding tests.
2. **Local project operations:** Inventory current restricted shell and scope policy; implement approved project selection, inspection/test commands and audit; add file diff preview, exact-digest approval and separately gated writes/git actions. Test path traversal, symlinks, changes after approval and failures.
3. **Browser tasks:** Implement a scoped signed-in browser profile with read/search/draft/fill, and require approval for each submit/upload/send. Test navigation, login expiry, allowlist escapes and cancellation.
4. **Durable tasks and recovery:** Persist enough planning and state for inspection and safe recovery; enforce no automatic protected replay on restart, with concurrent pending approvals and cancellation tests.
5. **Desktop GUI fallback:** Limit interaction to a selected allowed app, validate target, capture evidence and allow immediate interruption; verify macOS permission failures and manually test on a real Mac.
6. **MVP acceptance and delivery:** Exercise each original design acceptance criterion end-to-end on device, update setup/user documentation, and package only after the acceptance results and remaining limitations are recorded.

Each slice requires a precise implementation plan based on the current code, meaningful tests, a Dev commit and PR, separate QA and read-only review, passing `swift-test`, and the Decision maker's explicit merge approval. Do not treat later unchecked slices as complete.
