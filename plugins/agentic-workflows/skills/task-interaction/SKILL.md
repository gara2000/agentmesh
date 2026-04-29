---
name: task-interaction
description: Pick up a task from NoteCove, explore its context, brainstorm with the user, plan, implement, and create a PR — lightweight agentic workflow for individual tasks
disable-model-invocation: true
allowed-tools: Bash(notecove *, git *, gh pr *), Read, Glob, Grep, Edit, Write
hint: "Pick up and work on a NoteCove task. Required: --project <key-or-name> OR --sd <id-or-name> (at least one). Optional: --task <slug> (e.g. PROJ-42), --profile <id-or-name>"
---

# Task Interaction — Pick Up & Work on NoteCove Tasks

**Task:** $ARGUMENTS

This workflow ensures tasks from NoteCove are worked on methodically: gather context before asking questions, resolve questions before planning, and keep the user in the loop at every transition. The "Attention" state is how control is handed back to the user — the agent stops and waits until the user says 'continue'.

---

## NoteCove Setup

> All artifacts (notes, folders) live in NoteCove — not on disk.
> Use the `notecove` CLI for every artifact. The desktop app must be running.

### Step 1: Resolve NoteCove Context

Parse `$ARGUMENTS` for optional flags:
- `--profile <id-or-name>` — profile ID or profile name (case-insensitive)
- `--project <key-or-name>` — project key or project name (case-insensitive)
- `--sd <id-or-name>` — storage directory ID or name (case-insensitive)
- `--task <slug>` — task slug (e.g. `PROJ-42`)

**Scope rules:**
- At least one of `--project` or `--sd` MUST be provided. If both are given, use `--project` and ignore `--sd`.
- If neither is provided, ask the user before doing anything else.

**Resolve profile ID:** If `--profile` looks like a name, resolve via `notecove profiles`. Match case-insensitively.

**Default profile:** If `--profile` is not provided, use `kmq9h71tepf95rac2b59xdbsq2` (the "Agents" profile) without asking.

**Resolve project key:** If `--project` looks like a name, resolve via `notecove project list --json`. Match case-insensitively.

**Resolve storage directory ID:** If `--sd` looks like a name, resolve via `notecove sd list --json`. Match case-insensitively.

**Full-scope auth fallback:** If the expected project or storage directory is not found in the listing, the current authentication may be scoped too narrowly. Re-run:
```bash
notecove init --profile <id> --all-tasks --notes
```
Then retry `notecove sd list --json` or `notecove project list --json`. Only give up and ask the user if the entry is still missing after the re-auth.

### Step 2: Initialize CLI Access

| Condition | Init command |
|-----------|-------------|
| `--project` provided | `notecove init --profile <id> --tasks-project <KEY> --notes` |
| No project, `--sd` provided | `notecove init --profile <id> --all-tasks --notes --sd <sd-id>` |

If already initialized, `init` is a no-op — proceed.

---

## Step 3: Task Pickup

### 3a. Find the Task

**If `--task <slug>` was provided:**

Fetch the task via `notecove task show <slug> --format json`. Check the state — if NOT `"Ready"`, stop and alert the user. Wait for them to fix it.

**If `--task` was NOT provided:**

```bash
# If scoped to a project:
notecove task list --state "Ready" --project <KEY> --limit 50 --json

# If scoped to a storage directory (no project):
notecove task list --state "Ready" --limit 50 --json
```

If no tasks found, alert the user and stop. Otherwise, pick the **highest-priority** one — that is, the task with the **lowest `priority` number** (P1 is higher priority than P2). If tied, pick the first in the list.

**In both cases**, extract the task's `folderId` from the JSON output — this is the **parent folder** where the task lives. Then fetch the full content:
```bash
notecove task show <task-slug> --format markdown-with-comments
```

### 3b. Announce & Mark Doing

Announce the picked-up task (slug, title, priority, brief summary), then:
```bash
notecove task change <task-slug> --state "Doing"
```

### 3c. Create or Find Task Folder

Every task gets a dedicated NoteCove folder so its artifacts (notes, context, plan) stay organized and linked back to the task.

Check if the task description already contains a folder link (`[[F:` pattern):
- If yes, extract the folder ID and verify it exists via `notecove folder show <folder-id> --json`. Use it as the **task folder**.
- If no folder link exists, create it **under the task's parent folder** (the `folderId` from step 3a):
  1. `notecove folder create "<task-slug>" --parent <task-parent-folder-id>`
  2. `notecove folder show <new-folder-id> --json` — extract folder path and longid
  3. Append the folder link to the task description:
     ```bash
     notecove task change <task-slug> --content-file - --content-format markdown << 'EOF'
     <existing task content>

     [[F:<folder-longid>|<folder-path>]]
     EOF
     ```

All notes created during this workflow go directly inside the task folder (no subfolders).

---

## Phase 1: Exploration & Context Gathering

Study the task and its surrounding context thoroughly before doing any work.

**Explore all linked context from the task:**
- Task tree (parents, children): `notecove task tree <task-slug> --depth 3 --json`
- Inbound links: `notecove task inbound-links <task-slug> --type all --json`
- Read each linked task via `notecove task show <linked-slug> --format markdown-with-comments`
- Parse the task description and comments for `[[F:...]]` folder links, `[[T:...]]` task links, and `[[...]]` note links — read the content of each
- For folder links, also list and read the notes inside the folder

**Explore the codebase** based on what you've learned — use Read, Glob, Grep extensively. Understand architecture, patterns, conventions, affected areas, and dependencies.

If the task turns out to be too large for a single PR, alert the user and suggest decomposition instead of continuing.

Proceed automatically to Phase 2.

---

## Phase 2: Brainstorming & Questions

Ask the user to clarify ambiguities and align on the approach. Ask SPECIFIC, DETAILED questions — not vague yes/no. Cover: architecture decisions, API design, data models, error handling, testing approach, edge cases, integration points.

**Create a NoteCove note for each questions round:**

```bash
notecove note create "<task-slug>/QUESTIONS-<N>" --folder <task-folder-id> --content-file - --format markdown --json << 'EOF'
<!-- Answer each question inline below it. When done, say 'continue'. -->

## Q1: <your question>

## Q2: <your question>

---

## Anything else you'd like to mention?
EOF
```

Then **request user attention** (see Global Principles below). Tell the user questions are ready in NoteCove. **Stop and wait.**

### After User Responds

1. Read the updated note: `notecove note show <note-id> --format markdown-with-comments`
2. Set the task back to Doing
3. If more questions arise, create QUESTIONS-{N+1} and repeat
4. Only proceed when 100% confident in understanding

When all questions are resolved, proceed automatically to Phase 3.

---

## Phase 3: Plan Creation

Produce a lightweight implementation plan.

```bash
notecove note create "<task-slug>/PLAN" --folder <task-folder-id> --content-file - --format markdown --json << 'EOF'
# Implementation Plan

**Task:** <task-slug> — <task title>

## Phase 1: <phase name>

- <task description>
  - Write tests
  - Implement
  - Verify tests pass

## Phase 2: <phase name>
...
EOF
```

**Requirements:**
- Clear, minimal, concise steps
- When the task involves code changes, write tests before implementation (TDD)
- No unnecessary complexity or scope creep

**Request user attention.** Tell the user the plan is ready for review. **Stop and wait.**

When the user continues, set the task back to Doing.

---

## Phase 4: Implementation

Implement precisely as planned.

**Do not create new tasks in NoteCove** — it adds noise and API overhead without helping anyone. Only interact with the existing picked-up task and its linked tasks. If the user explicitly asks for new tasks, create them.

**Do not update the PLAN note after each step** — the plan is a reference, not a live dashboard. Focus on the actual work.

### 4a. Create Git Branch (if not already on one)

```bash
git checkout -b <task-slug>-impl
```

### 4b. Implement

- Write elegant, minimal, modular code
- Adhere strictly to existing code patterns and conventions
- When the task involves code changes, write failing tests first, then implement to make them pass

### 4c. When Implementation Is Complete

```bash
notecove task comments add <task-slug> "Implementation complete. <brief summary of changes>"
```

**Request user attention.** Tell the user what was implemented and test results. **Stop and wait.**

When the user continues, set the task back to Doing.

---

## Phase 5: GitHub PR Creation

### 5a. Commit

Review changes with `git status` and `git diff --stat`. Stage relevant files (avoid secrets or unrelated files). Commit with a conventional message that references the task:

```bash
git commit -m "$(cat <<'EOF'
<type>(<scope>): <short summary> [<task-slug>]

- <what changed and why>
- <what changed and why>

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

Where `<type>` is one of: `feat`, `fix`, `refactor`, `test`, `docs`, `chore`. If the work spans multiple logical changes, use separate commits.

### 5b. Push & Create PR

```bash
git push -u origin <branch-name>
gh pr create --title "<type>(<scope>): <short summary>" --body "$(cat <<'EOF'
## Summary
<1-3 sentences: what this PR does and why, referencing the task>

## Changes
<bullet list of key files/modules changed>

## Test plan
<how to verify — commands to run, behavior to check>

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

### 5c. Finalize

```bash
notecove task change <task-slug> --state "Attention"
notecove task comments add <task-slug> "PR created: <PR-URL>"
```

Return the PR link to the user.

---

## NoteCove Conventions

| Artifact | Location | Naming |
|---|---|---|
| Questions | Task folder | `<task-slug>/QUESTIONS-<N>` |
| Plan | Task folder | `<task-slug>/PLAN` |

**Task states:** To Do, Ready, Doing, Attention, Blocked, In Review, Done, Won't Do

**Link syntax:**
```
Task link:    [[T:longid|display text]]
Note link:    [[longid|display text]]
Folder link:  [[F:longid|folder path]]
```

**Deriving longid:** From `--json` output, strip the project prefix and colon from the `id` field.
Example: `"PROJ-k7r:gk0z65pfqd32qgwzkdw1d29"` -> `"k7rgk0z65pfqd32qgwzkdw1d29"`

**Heredoc pattern:** Prefer `--content-file -` with heredoc over temp files.

---

## Global Principles

### Requesting User Attention

Whenever the agent needs user action (questions answered, plan reviewed, implementation approved):
1. Set the task to `"Attention"`: `notecove task change <task-slug> --state "Attention"`
2. If the command fails (state doesn't exist), stop and ask the user to create the "Attention" state in project settings
3. Tell the user what's needed
4. **Stop and wait** for the user to say 'continue'
5. On continue, set the task back to `"Doing"` and proceed

### Questions at Any Phase

Ask questions at any phase when you encounter ambiguities. Create a `<task-slug>/QUESTIONS-<N>` note in the task folder, request attention, and wait. Clarity is more valuable than speed.

### No Unnecessary Task Creation

Do not create new tasks in NoteCove unless the user explicitly asks — it adds clutter and API overhead without helping. Track progress through notes and task comments only.
