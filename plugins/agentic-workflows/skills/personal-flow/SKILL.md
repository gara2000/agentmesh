---
name: personal-flow
description: Personal feature implementation workflow with NoteCove integration for notes, plans, and task tracking
disable-model-invocation: true
allowed-tools: Bash(notecove *, git *, gh pr *), Read, Glob, Grep, Edit, Write
hint: "Describe the feature to implement. Required flags: --project <key-or-name>, --task-code <code> (e.g. XYZ-123). Optional: --profile <id-or-name>"
---

# Personal Flow — Feature Implementation Workflow (NoteCove Edition)

**Task:** $ARGUMENTS

---

## NoteCove Setup

> **ALL files, plans, and questions created during this workflow live in NoteCove — not on disk.**
> Use the `notecove` CLI for every artifact: notes, tasks, and task comments.
> The desktop app must be running for the CLI to work.

### Step 1: Resolve NoteCove Context

Parse `$ARGUMENTS` for optional flags:
- `--profile <id-or-name>` — profile ID or profile name (case-insensitive)
- `--project <key-or-name>` — project key or project name (case-insensitive)
- `--task-code <code>` - Jira task code (e.g. XYZ-123) (should be rendered to upper case)

**Resolve profile ID:** If a `--profile` value is provided, check if it looks like a name (not a long alphanumeric ID). If so, resolve it to an ID by running:
```bash
notecove profiles
```
Match the provided name (case-insensitive) against the listed profile names and extract the full ID.

**Resolve project key:** If a `--project` value is provided, check if it looks like a name rather than an all-caps key. If so, resolve it by running:
```bash
notecove project list --json
```
Match the name (case-insensitive) against the listed projects and extract the slug prefix.

**Default profile:** If `--profile` is not provided, use `kmq9h71tepf95rac2b59xdbsq2` (the "Agents" profile) without asking.

If `--project` is missing entirely, ask the user **before doing anything else**:
```
Before we start, I need your NoteCove project key (e.g. MYPROJ):
```

If `--task-code` is missing entirely, ask the user **before doing anything else**:
```
Before we start, I need the Jira task code for this feature (e.g. XYZ-123):
```

Wait for the user's response, resolve any names to keys as described above, then confirm:
```
Got it. I'll use profile <resolved-profile-id> (<profile-name>) and project <KEY> for all NoteCove interactions.
```

### Step 2: Initialize CLI Access

Ensure the CLI is initialized for the current working directory with notes access:

```bash
notecove init --profile <id> --tasks-project <KEY> --notes
```

Approve the access request in the NoteCove desktop app when prompted.
If the directory is already initialized, `init` is a no-op — proceed.

### Step 2.5: Detect Existing Work (Resumption)

Before creating anything new, check whether a previous agent already started work on this task.

#### Search for existing root folder

```bash
notecove folder list --json
```

Parse the JSON output and look for a folder whose name matches `<task-code>` (case-insensitive).

- **If NO folder is found** → This is a **fresh start**. Skip to **Step 3** below.
- **If a folder IS found** → This is a **resumption**. Follow the detection steps below.

#### Resumption Detection

##### A. Recover Folder Structure

The root folder ID is already in the JSON output from the previous command. From the same output, identify the **Notes** and **Tasks** subfolders by looking for folders whose parent matches the root folder ID. Extract their IDs.

If the Notes or Tasks subfolders are missing, create whichever is absent (see Step 3a) before continuing.

##### B. Inventory Existing Artifacts

```bash
notecove task list --folder <tasks-folder-id> --json
notecove note list --folder <notes-folder-id> --json
```

From the **task list**, classify each task:
| Pattern | Type |
|---|---|
| `<task-code>-*: *` | **Feature task** — capture its ID and current state |
| `Answer QUESTIONS-* for <task-code>/*` | **Question task** — note its state |
| `Phase *: * [<task-code>/*]` | **Phase task** — note its state |
| `Answer QUESTIONS-PLAN-* for <task-code>/*` | **Plan-question task** — note its state |

From the **notes list**, classify each note:
| Pattern | Type |
|---|---|
| `<task-code>/*/QUESTIONS-*` | **Questions note** |
| `<task-code>/*/PLAN` | **Plan note** |
| `<task-code>/*/PLAN-PHASE-*` | **Plan-phase note** |

Extract the **slug** from existing artifact names (the second path segment, after `<task-code>/`).

##### C. Check Git Branch

```bash
git branch --list "<task-code>-*"
```

If a matching branch exists:
```bash
git checkout <branch-name>
git log --oneline -10
git status
```

If no branch exists, you will create one when the workflow reaches that point.

##### D. Read Existing Content

Read **all** existing notes to recover full context — you have NO prior conversation history:

```bash
# For each note found:
notecove note show <note-id>
```

Also read key tasks for their descriptions and comments:
```bash
notecove task show <task-slug>
```

##### E. Determine Resume Point

Use this decision tree to determine where to resume:

| # | Condition | Resume At |
|---|-----------|-----------|
| 1 | Folders exist but **no notes and no tasks** | **Step 3** — create feature task + branch, then Phase 1 |
| 2 | Feature task exists but **no QUESTIONS notes** | **Phase 1** — start analysis & questions |
| 3 | QUESTIONS notes exist, **some question tasks NOT Done** | **Phase 1** — prompt user to answer open questions, then continue Q&A |
| 4 | All question tasks Done, **no PLAN note** | **Phase 2** — create the plan |
| 5 | PLAN note exists, **no phase tasks** | **Phase 3** — critique the plan |
| 6 | Phase tasks exist, **some NOT Done** | **Phase 4** — continue implementation from first incomplete task |
| 7 | All phase tasks Done, feature task Done | **Phase 5** — check if PR exists; create one if not |

**Handling each state:**

**State 3 — Unanswered questions:**
- Read all QUESTIONS notes to see what was already asked
- Identify which question tasks are still open
- Tell the user: *"I found unanswered questions in NoteCove. Please answer them, then say 'continue'."*
- After answers arrive, mark question tasks Done and decide if more questions are needed

**State 6 — Partial implementation:**
- Read the PLAN note for the current progress percentage and task statuses
- Check git branch commits to verify what code was actually written
- Verify "Done" tasks by confirming their code and tests exist in the codebase
- Resume from the **first task that is NOT confirmed Done**
- Do NOT redo completed work

**State 7 — All implementation done:**
- Check for an existing PR:
  ```bash
  gh pr list --head <branch-name> --state all
  ```
- If a PR exists → inform the user that work is complete and share the PR link
- If no PR → proceed to Phase 5

**Announce the detected state:**
```
Detected existing work for <task-code>.
Current state: <brief description of what was found>.
Resuming from <Phase/Step N>.
```

Then **skip directly** to the identified phase. Do NOT re-execute any prior phases or recreate existing artifacts. Use the recovered folder IDs, feature task ID, and slug for all subsequent commands.

---

### Step 3: Fresh Start Setup

> **Skip this step entirely if Step 2.5 detected existing work (resumption).**

#### 3a. Create Folders

```bash
notecove folder create <task-code>
```

```bash
notecove folder create "Notes" --parent <root folder ID>
```

```bash
notecove folder create "Tasks" --parent <root folder ID>
```

Note the folder IDs — they **MUST** be used in every subsequent notecove command:
- All notes go inside the **Notes** folder
- All tasks go inside the **Tasks** folder

#### 3b. Create the Feature Tracking Task

Derive a kebab-case slug from the task description (e.g., "add dark mode" → `add-dark-mode`).

Create the top-level tracking task in NoteCove:

```bash
notecove task create "<task-code>-<slug>: <short description>" --folder <tasks folder ID>
```

Capture the returned task ID (e.g., `MYPROJ-42`) — this is the **feature task**. All subsequent tasks are children or blockers of this task.

Add a comment with the full original prompt:

```bash
notecove task comments add <FEATURE-TASK-ID> "Original prompt: <$ARGUMENTS>"
```

#### 3c. Create Git Branch

```bash
git checkout -b <task-code>-<slug>
```

---

## NoteCove Conventions Used in This Workflow

| Artifact | NoteCove Command |
|---|---|
| PROMPT (original request) | Comment on the feature task |
| QUESTIONS-*.md | Note: `<task-code>/<slug>/QUESTIONS-<N>` |
| PLAN.md | Note: `<task-code>/<slug>/PLAN` |
| PLAN-PHASE-{N}.md | Note: `<task-code>/<slug>/PLAN-PHASE-<N>` |
| Notes creation | `notecove note create --folder <notes folder ID> ...` |
| Phase/step tasks | `notecove task create "..." --folder <tasks folder ID>` |
| Progress updates | `notecove task change <ID> --state "In Progress"` / `"Done"` |
| Blockers | `notecove task change <ID> --block <BLOCKER-ID>` |

**Mapping task states:**
- 🟥 To Do → create task, leave in default state
- 🟨 In Progress → `notecove task change <ID> --state "In Progress"`
- 🟩 Done → `notecove task change <ID> --state "Done"`

---

## Global Principle: Questions at Any Phase

**You may initiate a questions iteration at any phase — including during plan critique or implementation — whenever you encounter ambiguities or missing context.**

The process is always the same regardless of which phase triggers it:
1. Create a questions note: `<task-code>/<slug>/QUESTIONS-<N>` (or `<task-code>/<slug>/QUESTIONS-PLAN-<N>` if during plan critique) inside the Notes folder
2. Create a corresponding task inside the Tasks folder and block the feature task on it
3. Tell the user the note is ready and ask them to answer
4. After answers arrive, mark the task Done and continue from where you left off

Do NOT skip questions out of eagerness to proceed. Clarity is more valuable than speed.

---

## Phase 1: Analysis & Questions

Your task is NOT to implement yet, but to fully understand and prepare.

**Responsibilities:**

- Analyze and understand the existing codebase thoroughly — use Read, Glob, Grep tools extensively
- Determine exactly how this feature integrates, including dependencies, structure, edge cases, and constraints

### Determine Plan Location

After initial exploration:

1. **Identify the component/service** being modified based on files you'll be working with
2. **Determine the notes folder** for this feature:
   - Logical component root maps to the notes folder name, e.g. `<task-code>/<slug>`
3. **Confirm with user** if ambiguous — then proceed

### Questions Round

- Clearly identify anything unclear or ambiguous
- Ask SPECIFIC, DETAILED questions (not vague yes/no)
- Cover: Architecture decisions, API design, data models, error handling, testing approach, edge cases, integration points

**Create a NoteCove note for each questions round:**

```bash
notecove note create "<task-code>/<slug>/QUESTIONS-<N>" --folder <notes folder ID>
```

Then open the note in NoteCove (it will appear in the desktop app). Populate it with this template:

```markdown
<!-- INSTRUCTIONS FOR ANSWERING QUESTIONS -->
<!--
- Answer each question inline below the question
- You can edit the questions if they're unclear
- Add your answers under each question
- When done, let me know
-->

## Q1: Your first question here

## Q2: Your second question here

---

## Anything else you'd like to mention?

**Additional context or clarifications:**
```

**After creating the note**, create a NoteCove task for this questions round and block the feature task on it:

```bash
notecove task create "Answer QUESTIONS-<N> for <task-code>/<slug>" --folder <tasks folder ID>
notecove task change <FEATURE-TASK-ID> --block <QUESTIONS-TASK-ID>
```

**Quality of questions matters:**

- Ask about specific technical decisions (e.g., "Should the endpoint return just `{id}` or include `{id, name, status}`?")
- Ask about error cases (e.g., "What should happen when X fails?")
- Ask about constraints (e.g., "What's the expected scale/volume?")
- Ask about integration (e.g., "Should this use the existing AuthService or create new?")
- Be thorough — 5–10 well-thought-out questions is better than 2–3 vague ones

**Important:**

- Do NOT assume any requirements or scope beyond explicitly described details
- Do NOT implement anything yet — just explore, plan, and ask questions
- This phase is iterative: after the user answers QUESTIONS-1, you may write QUESTIONS-2, etc.
- Continue until all ambiguities are resolved

**ITERATIVE Q&A:**

- ASK AS MANY ROUNDS OF QUESTIONS AS YOU NEED — don't rush to planning!
- After each answer round, mark the corresponding task Done:
  ```bash
  notecove task change <QUESTIONS-TASK-ID> --state "Done"
  ```
- If more questions arise, create QUESTIONS-{N+1} note + task, and re-block the feature task
- Only when you are 100% confident you understand everything should you move to planning

**When the user says "I've answered your questions. Please continue.":**

- Review what you know from ALL answered questions
- If ANYTHING is still unclear → ASK MORE QUESTIONS (QUESTIONS-{N+1})
- Only when you are 100% confident should you create a plan
- If in doubt, ASK — don't assume

**DO NOT create a plan until:**

1. You have asked all necessary questions
2. You have received and reviewed all answers
3. You have NO remaining ambiguities
4. You are completely confident in your understanding

**When all questions are resolved**, proceed automatically to Phase 2 — do NOT wait for the user to say "continue".

---

## Phase 2: Plan Creation

Based on the full exchange, produce a markdown plan and save it as a NoteCove note.

**Create the PLAN note:**

```bash
notecove note create "<task-code>/<slug>/PLAN" --folder <notes folder ID>
```

Open the note in the desktop app and populate it with the full plan using the format below.
After writing the plan, create NoteCove tasks for each phase and link them to the feature task:

```bash
# Create a task for each phase
notecove task create "Phase <N>: <phase name> [<task-code>/<slug>]" --folder <tasks folder ID>

# Block the feature task on each phase task
notecove task change <FEATURE-TASK-ID> --block <PHASE-TASK-ID>
```

**Requirements for the plan:**

- Include clear, minimal, concise steps
- Track status using emojis:
  - 🟩 Done
  - 🟨 In Progress
  - 🟥 To Do
- Include dynamic tracking of overall progress percentage (at top)
- Do NOT add extra scope or unnecessary complexity
- Steps should be modular, elegant, minimal, and integrate seamlessly with the existing codebase
- Use TDD: tests MUST be written BEFORE implementation code
- Every implementation task should have a corresponding test task
- Test commands should be listed for each task
- If subsidiary phase plans are needed, create them as separate notes: `<task-code>/<slug>/PLAN-PHASE-<N>`

**CRITICAL FORMAT REQUIREMENTS:**

- First line MUST be: **Overall Progress:** `0%`
- Use checkbox format: `- [ ]` (space between brackets)
- EVERY task MUST have an emoji: 🟥 (To Do), 🟨 (In Progress), or 🟩 (Done)
- Start all tasks as 🟥 (To Do)
- Use **bold** for task names
- Nest sub-tasks with indentation
- Group into phases if complex
- Tests BEFORE implementation (TDD)

**Plan Maintenance:**

- Every step must end with a subitem to update the plan
- Plan updates include: updating progress %, step statuses, and noting deviations
- Update the NoteCove note for PLAN (and PLAN-PHASE-{N} if it exists) after each step

**Template Example:**

```markdown
# Feature Implementation Plan

**Overall Progress:** `0%`

## Phase 1: Authentication Module

- [ ] 🟥 **Task 1.1: Setup authentication service**
  - [ ] 🟥 Write test: Test authentication service initialization
  - [ ] 🟥 Implement: Create authentication service class
  - [ ] 🟥 Test: Run `npm test auth.service.test.js`
  - [ ] 🟥 Update PLAN note (and PLAN-PHASE-1 note if exists)

- [ ] 🟥 **Task 1.2: JWT token handling**
  - [ ] 🟥 Write test: Test JWT generation and validation
  - [ ] 🟥 Implement: Add JWT token handling methods
  - [ ] 🟥 Test: Run `npm test jwt.test.js`
  - [ ] 🟥 Update PLAN note (and PLAN-PHASE-1 note if exists)
```

**⏸ CHECKPOINT**: When PLAN note is ready, say "Plan created. Say 'continue' for Phase 3"

---

## Phase 3: Plan Critique

Review the plan as a staff engineer using this comprehensive checklist.

**IMPORTANT:** Ensure the plan follows TDD:
- Tests written BEFORE implementation code
- Every task has corresponding test tasks
- Test commands are listed

### Review Checklist

#### 1. Task Sequencing & Visibility (Including TDD)
- Tests written FIRST, then implementation (strict TDD)
- Early tasks show visible progress without extra work
- Tasks that don't belong are identified for removal
- Missing tasks are identified and added
- Each implementation task has corresponding test task(s)

#### 2. Dependencies & Task Ordering
- Prerequisites completed before dependent tasks
- Independent tasks identified for parallel execution
- Read/understand steps precede modification steps

#### 3. Risk Management & Validation
- High-risk/uncertain tasks scheduled early (fail-fast principle)
- Verification/validation step exists for each major change
- Rollback strategy defined if changes break functionality

#### 4. Scope Control
- Task granularity appropriate (neither too fine nor too coarse)
- Scope creep and tangential work avoided
- Clear stopping point defined (not open-ended)

#### 5. Technical Readiness
- Required files, dependencies, and permissions identified
- Breaking changes identified and mitigation planned
- Backwards compatibility addressed if needed

#### 6. Efficiency & Reuse
- Existing solutions checked before building new ones
- Existing patterns/code identified for reuse
- Unnecessary exploration avoided when path is known

#### 7. Communication & Checkpoints
- Natural checkpoints exist to show user progress
- User input/decisions required identified upfront
- Output/deliverable clearly defined

**Additional requirements:**

- If this phase generates questions, create a `<task-code>/<slug>/QUESTIONS-PLAN-<N>` note (using `--folder <notes folder ID>`) and a corresponding NoteCove task (using `--folder <tasks folder ID>`, blocking the feature task), same as Phase 1 questions
- After review and any final questions, update the PLAN note with the finalized plan

**⏸ CHECKPOINT**: When plan is finalized, say "Plan finalized. Say 'continue' for Phase 4"

---

## Phase 4: Implementation

Now implement precisely as planned, in full.

**If resuming into this phase:** You inherited context from Step 2.5. Read the PLAN note for the current progress and task statuses. Check the git branch to see what code already exists. Start from the **first incomplete task** — do NOT redo work that is already Done. Verify completed tasks by confirming their code/tests exist before skipping them.

**At the start of Phase 4**, mark the feature task In Progress (if not already):

```bash
notecove task change <FEATURE-TASK-ID> --state "In Progress"
```

**Implementation Requirements:**

- Write elegant, minimal, modular code
- Adhere strictly to existing code patterns, conventions, and best practices
- Include clear comments/documentation within the code where needed
- Follow TDD: write failing tests first, then implement to make them pass
- Update the PLAN note after each task completes

**After each task completes**, update NoteCove:

```bash
# Mark the corresponding NoteCove task as done
notecove task change <TASK-ID> --state "Done"

# Add a progress comment to the feature task
notecove task comments add <FEATURE-TASK-ID> "Completed: <task name>. Overall progress: <N>%"
```

**Update the PLAN note** to reflect the new progress percentage and task statuses.

**When all tasks are done**, mark the feature task complete:

```bash
notecove task change <FEATURE-TASK-ID> --state "Done"
notecove task comments add <FEATURE-TASK-ID> "Implementation complete. All tasks done. Ready for review."
```

**⏸ CHECKPOINT**: Implementation is complete. Tell the user what was implemented and what tests pass. Wait for their explicit approval before moving to Phase 5 (PR creation).

---

## Phase 5: GitHub PR Creation

Once you have user approval, commit the changes, push the branch, and open a PR.

### 5a. Stage and Commit

Review what changed:
```bash
git status
git diff --stat
```

Stage relevant files (avoid committing secrets or unrelated files):
```bash
git add <file1> <file2> ...
```

Commit using a conventional commit message that summarizes the work:
```bash
git commit -m "$(cat <<'EOF'
<type>(<scope>): <short summary>

<body — bullet points describing what was changed and why>

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

Where `<type>` is one of: `feat`, `fix`, `refactor`, `test`, `docs`, `chore`.

### 5b. Push Branch

```bash
git push -u origin <branch-name>
```

### 5c. Create PR

```bash
gh pr create --title "<type>(<scope>): <short summary>" --body "$(cat <<'EOF'
## Summary

<1–3 bullet points describing what this PR does>

## Changes

<bullet list of key files/modules changed and why>

## Test plan

<bulleted checklist of how to verify the changes work>

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Return the PR link to the user.
