# Mac Agent MVP Design

## Goal

Build a Mac-first personal agent that accepts an outcome, plans and executes
work across local projects, terminal tools, browser-based office work, and
selected desktop applications. It runs ordinary low-risk work in the
background, exposes progress on demand, and pauses before any meaningful
external, destructive, or privilege-expanding action.

The product is a single-user assistant for this Mac. It is not an unattended
remote-control service and does not accept work from external chat channels.

## MVP Scope

### Included

- Menu-bar entry point, global shortcut, task list, task details, notifications,
  approval dialogs, and a visible execution timeline.
- Natural-language tasks for local software projects: inspect files, run
  approved commands and tests, collect results, and prepare file changes.
- File writes only after the user reviews an affected-file summary and diff.
  `git commit`, push, and deletion always require separate confirmation.
- Browser work on already authenticated sites: read, search, collect, organize,
  draft, and fill content. Sending, submitting, publishing, uploading, or
  sharing always requires confirmation.
- GUI automation only for user-approved applications, as a last resort after
  command, API, or browser DOM automation is unavailable.
- Local, persistent task state, structured memory, approval records, and audit
  events in SQLite.

### Excluded

- Wake-word or continuous voice operation.
- Phone or remote access, smart-home control, payments, purchases, or trading.
- Auto-submission, CAPTCHA bypass, credential harvesting, or unsupervised
  external messaging.
- Unrestricted background autonomy or an internet-facing agent gateway.

## Architecture

```text
SwiftUI menu-bar app + global shortcut + notification/approval UI
                         |
                local IPC (XPC or localhost only)
                         |
  Task service: task state machine, policy enforcement, audit, SQLite
        |                 |                  |                 |
    Agent planner     terminal/files     browser worker      GUI worker
 (Agents SDK or       restricted local   Playwright first,  Accessibility +
  LangGraph)          worker             browser-use next   ScreenCaptureKit
```

The SwiftUI application owns user interaction: task creation, real-time task
view, approval/rejection, cancellation, and notifications. The task service is
the sole authority allowed to dispatch tools. It runs only on the local Mac;
the UI never gives a model direct operating-system access.

The agent planner converts a request into proposed steps and tool calls. Every
tool declares a side-effect class. The task service evaluates that class against
the policy before invoking the worker. Thus model output is an execution
request, never an authorization decision.

The initial implementation chooses exactly one orchestration library:

- **OpenAI Agents SDK** when the goal is a smaller Python service with tool
  calling, sessions, tracing, and human-in-the-loop primitives.
- **LangGraph** when durable pause/resume graphs and complex long-running
  workflows dominate.

The final selection is an implementation decision; both fit the product
contract. The first implementation must not install both.

## Execution Order and Workers

Workers follow this reliability preference:

1. Local API, file operation, or constrained terminal command.
2. Browser DOM automation through Playwright.
3. Model-assisted browser automation (browser-use) for unfamiliar pages.
4. Desktop GUI automation through the Accessibility API and ScreenCaptureKit;
   Peekaboo may be used as the adapter rather than forked as the product UI.

Each worker receives a narrow, structured request, not unrestricted shell or
screen control. The terminal worker is limited to user-approved directories
and an allowlist of read/test commands. The browser worker uses isolated,
named profiles; credentials are never included in model prompts or task logs.
The GUI worker is restricted to an application allowlist and performs visible,
single-step actions that can be stopped immediately.

## Task Lifecycle

1. The user states a goal, for example: “run this project’s tests, fix clear
   failures, and draft a summary.”
2. The planner returns a concise plan, resources likely to be used, and
   proposed tool calls. The service assigns the risk class to each call.
3. Low-risk calls execute in the background. The menu bar shows state and the
   user can open the live timeline at any point.
4. A protected call changes the task to `awaiting_approval`; the UI shows the
   intended effect, target, diff or payload preview, and choices to approve,
   reject, edit the instruction, or cancel.
5. An approval binds to the exact action digest and expires if its relevant
   payload, target, or scope changes. It is not a blanket approval for future
   actions.
6. Every result advances the plan, triggers replanning after a recoverable
   failure, or transitions the task to `blocked`, `failed`, `cancelled`, or
   `completed`.
7. Completion produces a concise outcome: work done, changes made, unresolved
   items, and a continuation suggestion. No awaiting protected action resumes
   automatically after an application restart.

Core persistent states are `draft`, `planning`, `running`, `awaiting_approval`,
`blocked`, `failed`, `cancelled`, and `completed`.

## Authorization Policy

| Side effect | Examples | Default |
|---|---|---|
| `read` | inspect files, test output, web pages | run |
| `local-execute` | approved test/build commands | run |
| `local-write` | modify project files, create drafts | preview diff, then approve |
| `external-send` | send email, submit/publish a form, share | require approval |
| `upload` | attach a file or transfer data externally | require approval |
| `delete` | remove files, records, or web content | require approval |
| `credential` | change credential scope or request privileged access | require approval |
| `money` | purchases, payments, transfers | unsupported in MVP |

Policy is deterministic application code, configured with an explicit set of
approved directories, browser profiles, sites, applications, and command
rules. A prompt, tool description, or content from an inspected website cannot
weaken it. The user can cancel any task, including an already running low-risk
step, from the menu bar or task detail view.

## Data, Memory, and Audit

SQLite is the local source of truth. It stores tasks, planned steps, tool
requests/results, artifact references, user approvals, project records,
preferences, and policy configuration. Audit records retain a redacted input
and output summary, timestamp, worker, target, risk class, action digest,
result, and approval reference where applicable. Full screenshots, command
output, and diffs are stored as local artifacts referenced by the event; secrets
and browser cookies are never stored in the audit stream.

Structured memory is explicit and user-editable: projects, approved working
directories, preferred tools, recurring conventions, and reminders. A future
Mem0-style semantic layer may search this data, but it is not authoritative for
permission, task, or audit decisions.

## Error Handling and Recovery

- A missing OS permission, login prompt, CAPTCHA, ambiguous target, or absent
  required input changes the task to `blocked` and tells the user exactly what
  is needed.
- Worker failures preserve the current plan, prior outputs, and artifacts. The
  planner may propose a safe retry or alternate worker; protected retries need
  a new approval.
- Browser page changes fall back from a saved Playwright workflow to a
  supervised browser-use attempt, never silently to external submission.
- GUI actions must validate the intended application and visible target before
  acting. Failed validation stops the action rather than guessing coordinates.
- Restart recovery restores task history but only resumes low-risk work after a
  fresh service health check; it never replays an awaiting or previously
  approved protected request.

## MVP Acceptance Criteria

- A user can open the assistant with a shortcut, create a project or browser
  task, and view its current status from the menu bar.
- The agent can inspect an approved project and run an approved test command;
  its output appears in the task timeline.
- Before changing a project file, the UI shows a diff and requires an explicit
  approval. Commit, push, and deletion each need their own approval.
- On an approved, already signed-in site, the agent can read and draft/fill a
  form through browser automation, but it cannot submit, publish, upload, or
  send without approval.
- A GUI task is limited to a selected application and is visibly interruptible.
- An audit entry identifies every worker action and its approval status. Tasks
  awaiting approval remain safe after app restart.

## Delivery Sequence

1. SwiftUI shell, local service, SQLite schema, task state machine, policy
   engine, audit timeline, approval and cancellation UI.
2. Restricted terminal/project worker: read, test, diff preview, file-write,
   git confirmation workflow.
3. Browser worker: Playwright session isolation, approved site/profile rules,
   read/draft/fill flows and external-action approval gates.
4. Select and integrate one agent orchestrator, adding durable planning and
   pause/resume around the existing service contract.
5. GUI fallback: approved-app list, required macOS permissions, accessibility
   target validation, screenshot artifacts, and one-step cancellation.
6. Structured memory and optional semantic retrieval; pre-authorized low-risk
   scheduled suggestions only after the preceding stages are reliable.

## References

The evaluated open-source components, licenses, maintenance signals, and
adoption guidance are recorded in
[`2026-09-12-github-landscape.md`](2026-09-12-github-landscape.md).
