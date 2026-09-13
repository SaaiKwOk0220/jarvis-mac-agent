# Agent Collaboration Guide

This repo is built and maintained by a small team of AI agents plus a human decision-maker. The agents operate on a single workstation, each in an isolated git worktree, never editing the same files concurrently.

## Roles

| Role | Branch prefix | Sub-agent type | Responsibility |
|---|---|---|---|
| **Dev** | `feat/<topic>`, `fix/<topic>` | `developer` | Write code and unit tests, run `swift test`, commit on its feature branch |
| **QA** | `agent/qa/<task>` | `qa` | Read the dev branch's diff, design edge-case tests, run the test suite, file findings |
| **Review** | `agent/review/<task>` | `reviewer` | Read-only audit of the dev branch's commit(s): correctness, design, security, test coverage |
| **Decision** | (none — owns `main`) | human | The repository owner. Reviews reports, decides merge / iterate / hold |
| **Coordinator** | (none — orchestrates) | `general-purpose` | Routes Tasks to the right role, gathers reports, surfaces the decision packet |

The Coordinator is the entry point for the user: when you open a Task, the Coordinator dispatches Dev → QA → Review and packs the findings into a decision report.

## Branch and worktree conventions

- `main` is **protected**: requires a passing `swift-test` check, requires a PR, no direct push.
- Each role works on its own branch and its own git worktree:
  ```
  ~/projects/active/jarvis-mac-agent/repo/
  ├── .worktrees/main/                    ← main worktree, used only to sync remote main
  ├── .worktrees/feat-<topic>/            ← Dev's worktree (created when a feat branch is born)
  ├── .worktrees/agent-qa-<task>/         ← QA's worktree
  ├── .worktrees/agent-review-<task>/     ← Reviewer's worktree
  └── .worktrees/<agent-name>-<task>/     ← legacy / one-off agent worktrees
  ```
- A role never edits another role's branch. The Reviewer is strictly read-only.
- Two roles never write to the same file in the same window. The Coordinator sequences dispatches to keep this true.

## Workflow

```
User ──Task──▶ Coordinator
                  │
                  ├──▶ Dev (writes code + tests on feat/<topic>)
                  │      │ PR opened against main
                  │      ▼
                  ├──▶ QA (reviews diff + adds edge-case tests on agent/qa/<task>)
                  │      │ report
                  │      ▼
                  ├──▶ Review (read-only audit on agent/review/<task>)
                  │      │ report
                  │      ▼
                  └──▶ Decision packet ──▶ User
                                              │ approve
                                              ▼
                                           Coordinator merges PR to main
                                           (or asks Dev for another iteration)
```

## Merge rules

- `feat/<topic>` and `fix/<topic>` are the only branches that may open a PR to `main`.
- All PRs to `main` must:
  1. Pass the `swift-test` GitHub Actions check
  2. Receive at least one approving review (the Decision maker can self-approve)
- Squash or merge-commit is the Decision maker's choice; the default is **merge commit** to preserve the agent's history (`-no-ff`).
- Agent branches (`agent/<role>/<task>`) are deleted after their work lands in `main`.

## Communication contract

Each agent's final report **must** include:
- The commit SHA(s) it produced or reviewed
- File:line citations for any findings
- A clear verdict (`merge` / `iterate` / `hold`)
- For `iterate`: the minimal change list (not full code)

Reports must not include file dumps — the Decision maker can read the diff via GitHub PR.