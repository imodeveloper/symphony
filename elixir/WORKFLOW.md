---
tracker:
  kind: linear
  api_key: "$LINEAR_API_KEY"
  project_slug: "imodeveloperlab-2e208b71940c"
  active_states:
    - Todo
    - In Progress
    - Codex Review
    - Merging
    - Rework
  terminal_states:
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
    - Done
polling:
  interval_ms: 5000
workspace:
  root: /Users/ivan.borinschi/Work/Worktrees/symphony
operations:
  disk_path: /Users/ivan.borinschi/Work
  disk_pause_threshold_bytes: 5368709120
  disk_check_interval_ms: 60000
  paused_retry_interval_ms: 60000
  cleanup_dry_run_command: python3 /Users/ivan.borinschi/.codex/skills/simulator-storage-cleanup/scripts/cleanup_simulator_storage.py --dry-run --verbose
  cleanup_command: python3 /Users/ivan.borinschi/.codex/skills/simulator-storage-cleanup/scripts/cleanup_simulator_storage.py --apply --all-safe
  cleanup_timeout_ms: 900000
  cleanup_cooldown_ms: 1800000
  paused_issue_state: Rework
  stale_worktree_ttl_hours: 168
  stale_worktree_check_interval_ms: 3600000
  stale_worktree_delete: true
  watchdog_issue_enabled: true
  watchdog_issue_interval_ms: 3600000
  watchdog_issue_title: "Monitor Watchdog: hourly simulator health check"
  watchdog_issue_state: Todo
  watchdog_issue_assignee_id: d3ae2fb1-1804-4655-9895-bf3338c10e15
  watchdog_issue_priority: 3
  watchdog_issue_labels:
    - Chore
    - Observation
  watchdog_issue_description: |
    This is the Symphony-owned hourly Monitor watchdog task. Do not run this from a Codex automation.

    Run exactly one watchdog cycle, update the persistent Codex Workpad comment, then move this same issue to `Done`. Symphony will move it back to `Todo` on the next hourly interval when the issue is not already active.

    Required watchdog contract:
    - First read `/Users/ivan.borinschi/Work/AGENTS.md` and `/Users/ivan.borinschi/Work/imodeveloperlab/AGENTS.md`.
    - Keep this task narrow: do not run unrelated tests, do not modify Monitor source files, do not change signing/project settings, and do not use any simulator except `Imodeveloper Monitor Watchdog` unless you are only reporting a blocker.
    - Check free disk space for `/Users/ivan.borinschi/Work` before heavy work. If it is below 5 GB, do not build and do not boot extra simulators; report `WATCHDOG_PAUSED_DISK_PRESSURE` with the free space.
    - Use repo `/Users/ivan.borinschi/Work/imodeveloperlab`, watchdog worktree `/Users/ivan.borinschi/Work/Worktrees/monitor-watchdog-main`, workspace `Workspace.xcworkspace`, scheme `Monitor-Prod`, bundle id `com.monitor.md`, simulator `Imodeveloper Monitor Watchdog`, and DerivedData `/Users/ivan.borinschi/Work/Worktrees/monitor-watchdog-deriveddata`.
    - Fetch current `origin/main`. Ensure the watchdog worktree is a clean checkout of that SHA. Rebuild/relaunch only when main changed, no successful SHA is recorded, the app is not installed, or Monitor is not running.
    - If CoreSimulator access fails, stop before building and report `WATCHDOG_PAUSED_RUNTIME_BLOCKER` with the exact failure.
    - If Monitor runtime errors are found, create or update exactly one Linear issue in this project for the distinct failure. Assign Borinschi Ivan, use status `Todo`, labels `Bug`, `Observation`, and `Follow-up`, and set priority based on severity.
    - Final report must include watchdog status, simulator name/UDID, main SHA, previous successful SHA, whether build/install/relaunch happened, whether Monitor was running, whether logs looked alive, created/updated Linear issue, and blocker reason if blocked.
hooks:
  after_create: |
    git clone --depth 1 https://github.com/imodeveloper/imodeveloperlab .
    if command -v mise >/dev/null 2>&1; then
      mise trust || true
    fi
  before_remove: |
    true
agent:
  max_concurrent_agents: 10
  max_turns: 20
  max_concurrent_agents_by_state:
    Merging: 1
codex:
  command: codex app-server
  approval_policy: never
  thread_sandbox: danger-full-access
  turn_sandbox_policy:
    type: dangerFullAccess
---

You are working on a Linear ticket `{{ issue.identifier }}`

{% if attempt %}
Continuation context:

- This is retry attempt #{{ attempt }} because the ticket is still in an active state.
- Resume from the current workspace state instead of restarting from scratch.
- Do not repeat already-completed investigation or validation unless needed for new code changes.
- Do not end the turn while the issue remains in an active state unless you are blocked by missing required permissions/secrets.
  {% endif %}

Issue context:
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Instructions:

1. This is an unattended orchestration session. Never ask a human to perform follow-up actions.
2. Only stop early for a true blocker (missing required auth/permissions/secrets). If blocked, record it in the workpad and move the issue according to workflow.
3. Final message must report completed actions and blockers only. Do not include "next steps for user".

Work only in the provided repository copy. Do not touch any other path.

## Prerequisite: Linear MCP or `linear_graphql` tool is available

The agent should be able to talk to Linear, either via a configured Linear MCP server or injected `linear_graphql` tool. If none are present, stop and ask the user to configure Linear.

## Default posture

- Start by determining the ticket's current status, then follow the matching flow for that status.
- Start every task by opening the tracking workpad comment and bringing it up to date before doing new implementation work.
- Spend extra effort up front on planning and verification design before implementation.
- Reproduce first: always confirm the current behavior/issue signal before changing code so the fix target is explicit.
- Keep ticket metadata current (state, checklist, acceptance criteria, links).
- Always use Borinschi Ivan as the Linear assignee. Before planning, state
  changes, implementation, or validation, ensure the current issue is assigned
  to Borinschi Ivan using Linear `assigneeId` `d3ae2fb1-1804-4655-9895-bf3338c10e15`.
  If the issue is unassigned or assigned to someone else, update the assignee
  first and record that in the workpad. Every Linear issue you create must also
  use this assignee.
- Treat a single persistent Linear comment as the source of truth for progress.
- Use that single workpad comment for all progress and handoff notes; do not post separate "done"/summary comments.
- Treat any ticket-authored `Validation`, `Test Plan`, or `Testing` section as non-negotiable acceptance input: mirror it in the workpad and execute it before considering the work complete.
- When meaningful out-of-scope improvements are discovered during execution,
  file a separate Linear issue instead of expanding scope. The follow-up issue
  must include a clear title, description, and acceptance criteria, be placed in
  `Backlog`, be assigned to Borinschi Ivan in the same project as the current
  issue, link the current issue as `related`, and use `blockedBy` when the
  follow-up depends on the current issue.
- Keep Linear labels accurate on the current issue and on every issue you create.
  Use these label names exactly, creating any missing label once before applying it:
  `Bug`, `Improvement`, `Feature`, `Chore`, `Observation`, and `Follow-up`.
  Apply one best primary classification label:
  `Bug` for crashes, regressions, faults, sync errors, wrong behavior, or failed
  acceptance criteria; `Improvement` for performance, UX, refactors, test gaps,
  harness hardening, or existing-behavior polish; `Feature` for new user-facing
  capability; `Chore` for tooling, dependencies, docs, maintenance, or
  infrastructure; `Observation` for validation/monitoring-only work.
  Add `Follow-up` to every issue created from another issue, and also add
  `Observation` when a finding came from an observation or monitoring run.
- Set Linear priority from the request impact on the current issue and every
  issue you create. Use Linear priority values exactly:
  `1` Urgent for production down, data loss, security/privacy incidents,
  release-blocking crashes, or a broken critical workflow with no workaround;
  `2` High for major regressions, frequent crashes/faults, severe sync
  failures, important user workflows blocked with a workaround, or explicitly
  urgent user requests; `3` Medium for normal bugs, normal feature work,
  observation/validation work, test gaps, and important but non-blocking
  improvements; `4` Low for minor polish, copy/docs cleanup, small chores, or
  nice-to-have improvements. Do not leave priority unset unless the issue is
  terminal and no work will run.
- Move status only when the matching quality bar is met.
- Operate autonomously end-to-end unless blocked by missing requirements, secrets, or permissions.
- Use the blocked-access escape hatch only for true external blockers (missing required tools/auth) after exhausting documented fallbacks.

## Related skills

- `linear`: interact with Linear.
- `commit`: produce clean, logical commits during implementation.
- `push`: keep remote branch current and publish updates.
- `pull`: keep branch updated with latest `origin/main` before handoff.
- `land`: when ticket reaches `Merging`, explicitly open and follow `.codex/skills/land/SKILL.md`, which includes the `land` loop.

## Status map

- `Backlog` -> out of scope for this workflow; do not modify.
- `Todo` -> queued; immediately transition to `In Progress` before active work.
  - Special case: if a PR is already attached, treat as feedback/rework loop (run full PR feedback sweep, address or explicitly push back, revalidate, return to `Codex Review`).
- `In Progress` -> implementation actively underway.
- `Codex Review` -> automated reviewer checks the linked PR/diff, validation evidence, and PR feedback state; pass moves to `Merging`, fail moves to `Rework` with review comments in the workpad.
- `Merging` -> Codex review passed; execute the serialized merge flow. Only one `Merging` issue may run at a time.
- `Rework` -> Codex review or reviewer feedback requested changes; planning + implementation required.
- `Done` -> terminal state; no further action required.

## Step 0: Determine current ticket state and route

1. Fetch the issue by explicit ticket ID.
2. Read the current state.
3. Route to the matching flow:
   - `Backlog` -> do not modify issue content/state; stop and wait for human to move it to `Todo`.
   - `Todo` -> immediately move to `In Progress`, then ensure bootstrap workpad comment exists (create if missing), then start execution flow.
     - If PR is already attached, start by reviewing all open PR comments and deciding required changes vs explicit pushback responses.
   - `In Progress` -> continue execution flow from current scratchpad comment.
   - `Codex Review` -> run the Codex review flow.
   - `Merging` -> on entry, run the serialized merge flow.
   - `Rework` -> run rework flow.
   - `Done` -> do nothing and shut down.
4. Check whether a PR already exists for the current branch and whether it is closed.
   - If a branch PR exists and is `CLOSED` or `MERGED`, treat prior branch work as non-reusable for this run.
   - Create a fresh branch from `origin/main` and restart execution flow as a new attempt.
5. For `Todo` tickets, do startup sequencing in this exact order:
   - `update_issue(..., state: "In Progress")`
   - find/create `## Codex Workpad` bootstrap comment
   - only then begin analysis/planning/implementation work.
6. Add a short comment if state and issue content are inconsistent, then proceed with the safest flow.

## Step 1: Start/continue execution (Todo or In Progress)

1.  Find or create a single persistent scratchpad comment for the issue:
    - Search existing comments for a marker header: `## Codex Workpad`.
    - Ignore resolved comments while searching; only active/unresolved comments are eligible to be reused as the live workpad.
    - If found, reuse that comment; do not create a new workpad comment.
    - If not found, create one workpad comment and use it for all updates.
    - Persist the workpad comment ID and only write progress updates to that ID.
2.  If arriving from `Todo`, do not delay on additional status transitions: the issue should already be `In Progress` before this step begins.
3.  Immediately reconcile the workpad before new edits:
    - Check off items that are already done.
    - Expand/fix the plan so it is comprehensive for current scope.
    - Ensure `Acceptance Criteria` and `Validation` are current and still make sense for the task.
4.  Start work by writing/updating a hierarchical plan in the workpad comment.
5.  Ensure the workpad includes a compact environment stamp at the top as a code fence line:
    - Format: `<host>:<abs-workdir>@<short-sha>`
    - Example: `devbox-01:/home/dev-user/code/symphony-workspaces/MT-32@7bdde33bc`
    - Do not include metadata already inferable from Linear issue fields (`issue ID`, `status`, `branch`, `PR link`).
6.  Add explicit acceptance criteria and TODOs in checklist form in the same comment.
    - If changes are user-facing, include a UI walkthrough acceptance criterion that describes the end-to-end user path to validate.
    - If changes touch app files or app behavior, add explicit app-specific flow checks to `Acceptance Criteria` in the workpad (for example: launch path, changed interaction path, and expected result path).
    - If the ticket description/comment context includes `Validation`, `Test Plan`, or `Testing` sections, copy those requirements into the workpad `Acceptance Criteria` and `Validation` sections as required checkboxes (no optional downgrade).
7.  Run a principal-style self-review of the plan and refine it in the comment.
8.  Before implementing, capture a concrete reproduction signal and record it in the workpad `Notes` section (command/output, screenshot, or deterministic UI behavior).
9.  Run the `pull` skill to sync with latest `origin/main` before any code edits, then record the pull/sync result in the workpad `Notes`.
    - Include a `pull skill evidence` note with:
      - merge source(s),
      - result (`clean` or `conflicts resolved`),
      - resulting `HEAD` short SHA.
10. Compact context and proceed to execution.

## PR feedback sweep protocol (required)

When a ticket has an attached PR, run this protocol before moving to `Codex Review`:

1. Identify the PR number from issue links/attachments.
2. Gather feedback from all channels:
   - Top-level PR comments (`gh pr view --comments`).
   - Inline review comments (`gh api repos/<owner>/<repo>/pulls/<pr>/comments`).
   - Review summaries/states (`gh pr view --json reviews`).
3. Treat every actionable reviewer comment (human or bot), including inline review comments, as blocking until one of these is true:
   - code/test/docs updated to address it, or
   - explicit, justified pushback reply is posted on that thread.
4. Update the workpad plan/checklist to include each feedback item and its resolution status.
5. Re-run validation after feedback-driven changes and push updates.
6. Repeat this sweep until there are no outstanding actionable comments.

## Blocked-access escape hatch (required behavior)

Use this only when completion is blocked by missing required tools or missing auth/permissions that cannot be resolved in-session.

- GitHub is **not** a valid blocker by default. Always try fallback strategies first (alternate remote/auth mode, then continue publish/review flow).
- Do not move to `Codex Review` for GitHub access/auth until all fallback strategies have been attempted and documented in the workpad.
- If a non-GitHub required tool is missing, or required non-GitHub auth is unavailable, leave or move the ticket to `Rework` with a short blocker brief in the workpad that includes:
  - what is missing,
  - why it blocks required acceptance/validation,
  - exact human action needed to unblock.
- Keep the brief concise and action-oriented; do not add extra top-level comments outside the workpad.

## Step 2: Execution phase (Todo -> In Progress -> Codex Review)

1.  Determine current repo state (`branch`, `git status`, `HEAD`) and verify the kickoff `pull` sync result is already recorded in the workpad before implementation continues.
2.  If current issue state is `Todo`, move it to `In Progress`; otherwise leave the current state unchanged.
3.  Load the existing workpad comment and treat it as the active execution checklist.
    - Edit it liberally whenever reality changes (scope, risks, validation approach, discovered tasks).
4.  Implement against the hierarchical TODOs and keep the comment current:
    - Check off completed items.
    - Add newly discovered items in the appropriate section.
    - Keep parent/child structure intact as scope evolves.
    - Update the workpad immediately after each meaningful milestone (for example: reproduction complete, code change landed, validation run, review feedback addressed).
    - Never leave completed work unchecked in the plan.
    - For tickets that started as `Todo` with an attached PR, run the full PR feedback sweep protocol immediately after kickoff and before new feature work.
5.  Run validation/tests required for the scope.
    - Mandatory gate: execute all ticket-provided `Validation`/`Test Plan`/ `Testing` requirements when present; treat unmet items as incomplete work.
    - Prefer a targeted proof that directly demonstrates the behavior you changed.
    - You may make temporary local proof edits to validate assumptions (for example: tweak a local build input for `make`, or hardcode a UI account / response path) when this increases confidence.
    - Revert every temporary proof edit before commit/push.
    - Document these temporary proof steps and outcomes in the workpad `Validation`/`Notes` sections so reviewers can follow the evidence.
    - If app-touching, run `launch-app` validation and capture/upload media via `github-pr-media` before handoff.
6.  Re-check all acceptance criteria and close any gaps.
7.  Before every `git push` attempt, run the required validation for your scope and confirm it passes; if it fails, address issues and rerun until green, then commit and push changes.
8.  Attach PR URL to the issue (prefer attachment; use the workpad comment only if attachment is unavailable).
    - Ensure the GitHub PR has label `symphony` (add it if missing).
9.  Merge latest `origin/main` into branch, resolve conflicts, and rerun checks.
10. Update the workpad comment with final checklist status and validation notes.
    - Mark completed plan/acceptance/validation checklist items as checked.
    - Add final handoff notes (commit + validation summary) in the same workpad comment.
    - Do not include PR URL in the workpad comment; keep PR linkage on the issue via attachment/link fields.
    - Add a short `### Confusions` section at the bottom when any part of task execution was unclear/confusing, with concise bullets.
    - Do not post any additional completion summary comment.
11. Before moving to `Codex Review`, poll PR feedback and checks:
    - Read the PR `Manual QA Plan` comment (when present) and use it to sharpen UI/runtime test coverage for the current change.
    - Run the full PR feedback sweep protocol.
    - Confirm PR checks are passing (green) after the latest changes.
    - Confirm every required ticket-provided validation/test-plan item is explicitly marked complete in the workpad.
    - Repeat this check-address-verify loop until no outstanding comments remain and checks are fully passing.
    - Re-open and refresh the workpad before state transition so `Plan`, `Acceptance Criteria`, and `Validation` exactly match completed work.
12. Only then move issue to `Codex Review`.
    - Exception: if blocked by missing required non-GitHub tools/auth per the blocked-access escape hatch, move to `Rework` with the blocker brief and explicit unblock actions.
13. For `Todo` tickets that already had a PR attached at kickoff:
    - Ensure all existing PR feedback was reviewed and resolved, including inline review comments (code changes or explicit, justified pushback response).
    - Ensure branch was pushed with any required updates.
    - Then move to `Codex Review`.

## Step 3: Codex Review and merge handling

1. When the issue is in `Codex Review`, do not implement new scope or make opportunistic code changes.
2. Run an independent Codex review of the linked PR/diff, current branch, workpad, acceptance criteria, validation evidence, PR checks, and all existing GitHub review comments.
3. Record the review result in the existing `## Codex Workpad` comment under a `### Codex Review` section. Do not create a separate completion comment.
4. If review finds actionable defects, missing validation, unresolved PR feedback, broken acceptance criteria, or risky implementation gaps:
   - write concise review comments in the workpad with file/line references when available,
   - keep or update labels/priority if the review changes severity/classification,
   - move the issue to `Rework`,
   - stop without implementing the fix in the same turn.
5. If review passes with no actionable findings:
   - write `Codex Review: passed` in the workpad with the evidence checked,
   - move the issue to `Merging`.
6. When the issue is in `Merging`, run the serialized merge flow:
   - Re-read `/Users/ivan.borinschi/Work/AGENTS.md` and `/Users/ivan.borinschi/Work/imodeveloperlab/AGENTS.md` before any merge or validation command.
   - Confirm no other issue is actively in the merge flow. The workflow config also limits `Merging` to one concurrent agent; if another merge is active, stop and let Symphony retry this issue later.
   - Fetch latest `origin/main`.
   - Merge or rebase the PR branch onto current `origin/main` before landing. If conflicts appear, resolve them in the branch, rerun required validation, update the workpad with the conflict files and resolutions, commit the conflict resolution, push the branch, and keep the issue in `Merging`.
   - Create a local post-merge `main` candidate from current `origin/main` plus this one PR branch before doing the final remote merge. This candidate is the place to detect integration regressions while the merge can still be aborted cleanly.
   - Run the Monitor app unit-test gate against that post-merge `main` candidate:
     `xcodebuild -workspace /Users/ivan.borinschi/Work/imodeveloperlab/Workspace.xcworkspace -scheme Monitor-Prod -destination 'platform=iOS Simulator,name=Capone,OS=26.2' -skip-testing:DSKitTests test`
   - If `Capone` is unavailable, use another normal pool simulator from `/Users/ivan.borinschi/Work/AGENTS.md`; never use `Imodeveloper Monitor Watchdog` for this merge validation.
   - If tests fail or regressions are found, abort the local merge candidate, keep the branch/PR unmerged, add specific failure comments to the workpad including failing command, failing tests, logs, and suspected files, move the issue to `Rework`, and do not mark `Done`.
   - If tests pass, record the candidate SHA and test command/result in the workpad.
   - Open and follow `.codex/skills/land/SKILL.md`. Do not call `gh pr merge` directly.
   - Land exactly one PR/branch, then stop looking for other merge-ready issues. Symphony will dispatch the next `Merging` issue only after this one leaves `Merging`.
7. After landing, update the main checkout to the merged SHA, confirm it matches the tested candidate or rerun the same Monitor app unit-test gate if it does not, record the final merged SHA in the workpad, then move the issue to `Done`.

## Step 4: Rework handling

1. Treat `Rework` as a full approach reset, not incremental patching.
2. Re-read the full issue body, workpad, Codex review comments, and all PR comments; explicitly identify what will be done differently this attempt.
3. Close the existing PR tied to the issue.
4. Remove the existing `## Codex Workpad` comment from the issue.
5. Create a fresh branch from `origin/main`.
6. Start over from the normal kickoff flow:
   - If current issue state is `Todo`, move it to `In Progress`; otherwise keep the current state.
   - Create a new bootstrap `## Codex Workpad` comment.
   - Build a fresh plan/checklist and execute end-to-end.

## Completion bar before Codex Review

- Step 1/2 checklist is fully complete and accurately reflected in the single workpad comment.
- Acceptance criteria and required ticket-provided validation items are complete.
- Validation/tests are green for the latest commit.
- PR feedback sweep is complete and no actionable comments remain.
- PR checks are green, branch is pushed, and PR is linked on the issue.
- Required PR metadata is present (`symphony` label).
- If app-touching, runtime validation/media requirements from `App runtime validation (required)` are complete.

## Guardrails

- If the branch PR is already closed/merged, do not reuse that branch or prior implementation state for continuation.
- For closed/merged branch PRs, create a new branch from `origin/main` and restart from reproduction/planning as if starting fresh.
- If issue state is `Backlog`, do not modify it; wait for human to move to `Todo`.
- Do not edit the issue body/description for planning or progress tracking.
- Use exactly one persistent workpad comment (`## Codex Workpad`) per issue.
- If comment editing is unavailable in-session, use the update script. Only report blocked if both MCP editing and script-based editing are unavailable.
- Temporary proof edits are allowed only for local verification and must be reverted before commit.
- If out-of-scope improvements are found, create a separate Backlog issue rather
  than expanding current scope, and include a clear
  title/description/acceptance criteria, Borinschi Ivan assignee in the same
  project, a `related` link to the current issue, and `blockedBy` when the
  follow-up depends on the current issue.
- When creating or updating any issue, apply the workflow label policy:
  current issues get the best matching classification label, and generated
  follow-up issues get `Follow-up` plus the correct classification labels.
- When creating or updating any issue, apply the workflow priority policy from
  the request and evidence; generated follow-up issues must not be left without
  priority.
- Do not move to `Codex Review` unless the `Completion bar before Codex Review` is satisfied.
- In `Codex Review`, review only: pass moves to `Merging`; actionable findings move to `Rework` with comments.
- `Merging` is serialized. Do not run multiple merge/land agents at the same time, and do not pick up a second merge-ready issue from inside a merge run.
- A merge is not complete until the post-merge main checkout passes the Monitor app unit-test gate. Failed post-merge validation moves the issue to `Rework` with specific comments instead of `Done`.
- If state is terminal (`Done`), do nothing and shut down.
- Keep issue text concise, specific, and reviewer-oriented.
- If blocked and no workpad exists yet, add one blocker comment describing blocker, impact, and next unblock action.

## Workpad template

Use this exact structure for the persistent workpad comment and keep it updated in place throughout execution:

````md
## Codex Workpad

```text
<hostname>:<abs-path>@<short-sha>
```

### Plan

- [ ] 1\. Parent task
  - [ ] 1.1 Child task
  - [ ] 1.2 Child task
- [ ] 2\. Parent task

### Acceptance Criteria

- [ ] Criterion 1
- [ ] Criterion 2

### Validation

- [ ] targeted tests: `<command>`

### Notes

- <short progress note with timestamp>

### Confusions

- <only include when something was confusing during execution>
````
