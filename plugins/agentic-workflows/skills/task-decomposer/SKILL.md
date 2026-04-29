---
name: task-decomposer
description: Brainstorm with the user, decompose a large task into logical subtasks, and produce a self-contained plan for each that can be executed by personal-flow agents
disable-model-invocation: true
allowed-tools: Bash(notecove *), Read, Glob, Grep
hint: "Describe the large task to decompose into subtasks. Required flags: --project <key-or-name>, --task-code <code> (e.g. XYZ-123). Optional: --profile <id-or-name>"
---

# Task Decomposer — Brainstorm, Decompose, Plan

**Task:** $ARGUMENTS

---

## NoteCove Setup

> **ALL brainstorming notes, plans, and tasks created during this workflow live in NoteCove — not on disk.**
> Use the `notecove` CLI for every artifact.
> The desktop app must be running for the CLI to work.

### Step 1: Resolve NoteCove Context

Parse `$ARGUMENTS` for optional flags:
- `--profile <id-or-name>` — profile ID or profile name (case-insensitive)
- `--project <key-or-name>` — project key or project name (case-insensitive)
- `--task-code <code>` — Jira task code (e.g. XYZ-123) (should be rendered to upper case)

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
Before we start, I need the Jira task code for this task (e.g. XYZ-123):
```

Wait for the user's response, resolve any names to keys as described above, then confirm:
```
Got it. I'll use profile <resolved-profile-id> (<profile-name>) and project <KEY> for all NoteCove interactions.
```

### Step 2: Initialize CLI Access

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

The root folder ID is already in the JSON output. From the same output, identify the **Brainstorming**, **Tasks**, and **Plans** subfolders by looking for folders whose parent matches the root folder ID. Extract their IDs.

If any subfolder is missing, create it (see Step 3a) before continuing.

##### B. Inventory Existing Artifacts

```bash
notecove task list --folder <tasks-folder-id> --json
notecove note list --folder <brainstorming-folder-id> --json
notecove note list --folder <plans-folder-id> --json
```

From the **task list**, classify each task:
| Pattern | Type |
|---|---|
| `<task-code>-decompose: *` | **Main decomposition task** — capture its ID and state |
| `Review BRAINSTORM-* for <task-code>` | **Brainstorming review task** — note its state |
| `Subtask *: * [<task-code>]` | **Subtask task** — note its state |

From the **brainstorming notes**, identify:
| Pattern | Type |
|---|---|
| `<task-code>/BRAINSTORM-*` | **Brainstorming note** — count and note IDs |

From the **plans notes**, identify:
| Pattern | Type |
|---|---|
| `<task-code>/DECOMPOSITION` | **Decomposition summary** |
| `<task-code>/PLAN-*` | **Subtask plan** — count how many |

##### C. Read Existing Content

Read **all** existing notes to recover full context — you have NO prior conversation history:

```bash
# For each note found (brainstorming and plans):
notecove note show <note-id>
```

Also read key tasks for their descriptions and comments:
```bash
notecove task show <task-slug>
```

##### D. Determine Resume Point

| # | Condition | Resume At |
|---|-----------|-----------|
| 1 | Folders exist but **no notes and no tasks** | **Step 3** — create main task, then Phase 1 |
| 2 | Main task exists but **no brainstorming notes** | **Phase 1** — start brainstorming |
| 3 | Brainstorming notes exist, **some review tasks NOT Done** | **Phase 1** — prompt user to answer open brainstorming notes |
| 4 | All brainstorming review tasks Done, **no DECOMPOSITION note** | **Phase 2** — decompose into subtasks |
| 5 | DECOMPOSITION note exists, **some subtask plans missing** | **Phase 3** — create remaining subtask plans |
| 6 | All subtask plans exist | **Phase 4** — review and finalize |

**Handling each state:**

**State 3 — Unanswered brainstorming:**
- Read all brainstorming notes to see what was already proposed
- Identify which review tasks are still open
- Tell the user: *"I found brainstorming notes that haven't been reviewed yet. Please review them in NoteCove, then say 'continue'."*
- After answers arrive, mark review tasks Done and decide if more brainstorming is needed

**State 5 — Partial plan creation:**
- Read the DECOMPOSITION note for the full subtask list
- Check which subtask plans already exist in the Plans folder
- Create plans only for subtasks that don't have one yet

**Announce the detected state:**
```
Detected existing work for <task-code>.
Current state: <brief description of what was found>.
Resuming from <Phase/Step N>.
```

Then **skip directly** to the identified phase. Do NOT recreate existing artifacts. Use the recovered folder IDs, main task ID, and context for all subsequent commands.

---

### Step 3: Fresh Start Setup

> **Skip this step entirely if Step 2.5 detected existing work (resumption).**

#### 3a. Create Folders

```bash
notecove folder create <task-code>
```

```bash
notecove folder create "Brainstorming" --parent <root folder ID>
```

```bash
notecove folder create "Tasks" --parent <root folder ID>
```

```bash
notecove folder create "Plans" --parent <root folder ID>
```

Note the folder IDs — they **MUST** be used in every subsequent notecove command:
- Brainstorming notes go inside the **Brainstorming** folder
- All tasks go inside the **Tasks** folder
- Plan notes go inside the **Plans** folder

#### 3b. Create the Main Decomposition Task

Derive a kebab-case slug from the task description (e.g., "redesign auth system" → `redesign-auth-system`).

```bash
notecove task create "<task-code>-decompose: <short description>" --folder <tasks folder ID>
```

Capture the returned task ID — this is the **main task**. All subsequent tasks block this task.

Add a comment with the full original prompt:

```bash
notecove task comments add <MAIN-TASK-ID> "Original prompt: <$ARGUMENTS>"
```

---

## NoteCove Conventions Used in This Workflow

| Artifact | Location | Naming |
|---|---|---|
| Brainstorming notes | Brainstorming folder | `<task-code>/BRAINSTORM-<N>` |
| Decomposition summary | Plans folder | `<task-code>/DECOMPOSITION` |
| Subtask plans | Plans folder | `<task-code>/PLAN-<subtask-slug>` |
| Main task | Tasks folder | `<task-code>-decompose: <description>` |
| Brainstorming review tasks | Tasks folder | `Review BRAINSTORM-<N> for <task-code>` |
| Subtask tasks | Tasks folder | `Subtask <N>: <description> [<task-code>]` |

**Task state mapping:**
- 🟥 To Do → create task, leave in default state
- 🟨 In Progress → `notecove task change <ID> --state "In Progress"`
- 🟩 Done → `notecove task change <ID> --state "Done"`

---

## Global Principle: Brainstorming at Any Phase

**You may initiate a brainstorming iteration at any phase whenever you encounter ambiguities, missing context, or want to explore options with the user.**

The process is always the same:
1. Create a brainstorming note `<task-code>/BRAINSTORM-<N>` in the Brainstorming folder
2. Create a review task `Review BRAINSTORM-<N> for <task-code>` in the Tasks folder and block the main task on it
3. Tell the user the note is ready and ask them to review
4. After answers arrive, mark the task Done and continue from where you left off

Clarity and alignment with the user are more valuable than speed.

---

## Phase 1: Analysis & Brainstorming

Your goal is to deeply understand the task and brainstorm approaches **with the user**. Do NOT decompose or plan yet.

### Codebase Exploration

Before writing anything, explore the codebase thoroughly:
- Use Read, Glob, Grep tools extensively
- Understand the architecture, patterns, and conventions in use
- Identify all areas of the codebase that the task touches
- Map out dependencies, integration points, and potential risks

### Brainstorming Iterations

Each brainstorming round produces a note in NoteCove. The goal is to **think out loud with the user** — propose, question, refine.

**Create a brainstorming note:**

```bash
notecove note create "<task-code>/BRAINSTORM-<N>" --folder <brainstorming folder ID>
```

Populate it with this structure:

```markdown
<!-- INSTRUCTIONS -->
<!--
- Read through the analysis, ideas, and questions below
- Add your thoughts, corrections, and answers inline
- Feel free to add new ideas or reject proposed ones
- When done, let me know
-->

## Current Understanding

<Your summary of the task and what you've learned from the codebase>

## Ideas & Options

### Option A: <name>
<Description, trade-offs, pros/cons>

### Option B: <name>
<Description, trade-offs, pros/cons>

## Open Questions

### Q1: <specific question>

### Q2: <specific question>

## Risks & Concerns

<Any risks, edge cases, or concerns you've identified>

---

## Your Thoughts

**Anything else you'd like to add or change?**
```

**After creating the note**, create a review task and block the main task:

```bash
notecove task create "Review BRAINSTORM-<N> for <task-code>" --folder <tasks folder ID>
notecove task change <MAIN-TASK-ID> --block <REVIEW-TASK-ID>
```

### Iterative Refinement

- After the user reviews BRAINSTORM-1, read their feedback carefully
- Mark the review task Done:
  ```bash
  notecove task change <REVIEW-TASK-ID> --state "Done"
  ```
- If more exploration is needed, create BRAINSTORM-2 with:
  - Updated understanding incorporating user feedback
  - Refined or new ideas based on the discussion
  - Deeper questions that emerged from the previous round
  - Narrowed options where the user has expressed preferences
- **Each iteration should build on the previous ones** — don't repeat resolved topics, focus on what's still open

### When to Move On

Do NOT proceed to Phase 2 until:
1. You and the user agree on the general approach
2. All major architectural decisions are settled
3. The scope is clearly defined — what's in and what's out
4. You have a clear mental model of all the work involved
5. No significant open questions remain

**When brainstorming is complete**, proceed automatically to Phase 2 — do NOT wait for the user to say "continue".

---

## Phase 2: Task Decomposition

Based on the brainstorming, decompose the task into logical subtasks.

### Grouping Principles

- **Cohesion:** Group actions that are tightly related — one cannot function without the others
- **Independence:** Each subtask should be implementable on its own (after its dependencies are done) and result in a working, testable state
- **Size balance:** Merge very small groups with related ones rather than leaving them as standalone subtasks
- **Clear boundaries:** Each subtask should touch a well-defined area of the codebase with minimal overlap with other subtasks

### Dependency Identification

For each subtask, determine:
- Which other subtasks must be completed **before** this one can start
- Which subtasks are fully **independent** and can be done in parallel
- The critical path — the longest chain of dependent subtasks

### Create the Decomposition Summary

```bash
notecove note create "<task-code>/DECOMPOSITION" --folder <plans folder ID>
```

Populate it with:

```markdown
# Task Decomposition: <task description>

## Overview

<1–2 paragraph summary of the overall task and the chosen approach from brainstorming>

## Subtasks

### Subtask 1: <name>
- **Slug:** `<subtask-slug>`
- **Description:** <what this subtask accomplishes>
- **Depends on:** <list of subtask numbers, or "None">
- **Key areas:** <files/modules this subtask will touch>

### Subtask 2: <name>
- **Slug:** `<subtask-slug>`
- **Description:** <what this subtask accomplishes>
- **Depends on:** Subtask 1
- **Key areas:** <files/modules this subtask will touch>

...

## Dependency Graph

<text representation of the dependency order, e.g.:>
Subtask 1 → Subtask 2 → Subtask 4
Subtask 1 → Subtask 3 → Subtask 4
(Subtasks 2 and 3 can be done in parallel after Subtask 1)

## Execution Order

1. **First:** Subtask 1 (no dependencies)
2. **Then (parallel):** Subtasks 2, 3
3. **Finally:** Subtask 4 (depends on 2 and 3)
```

### Create Subtask Tasks

For each subtask, create a NoteCove task and set up dependencies:

```bash
# Create the subtask task
notecove task create "Subtask <N>: <description> [<task-code>]" --folder <tasks folder ID>

# Block the main task on this subtask
notecove task change <MAIN-TASK-ID> --block <SUBTASK-TASK-ID>

# If this subtask depends on another, block it on the dependency
notecove task change <SUBTASK-TASK-ID> --block <DEPENDENCY-SUBTASK-TASK-ID>
```

**⏸ CHECKPOINT**: Present the decomposition to the user:
```
Here's the task decomposition — <N> subtasks identified.
Review the DECOMPOSITION note in NoteCove.
Say 'continue' when you're happy with the grouping, or tell me what to change.
```

---

## Phase 3: Subtask Plan Creation

For each subtask, create a high-level plan note in the Plans folder.

### Plan Format

These plans will be picked up by **other AI agents** running the `personal-flow` skill. They must be:
- **Self-contained** — the agent has NO context from this brainstorming session
- **High-level** — describe WHAT to do, not every line of code
- **Precise** — no vague statements; name specific files, modules, patterns, and APIs
- **Clear on scope** — explicitly state what's included and what's NOT included

**Create a plan note for each subtask:**

```bash
notecove note create "<task-code>/PLAN-<subtask-slug>" --folder <plans folder ID>
```

Populate with this structure:

```markdown
# Subtask Plan: <subtask name>

**Parent task:** <task-code>
**Subtask:** <N> of <total>
**Depends on:** <list of subtask slugs that must be completed first, or "None">
**Blocked by:** <list of subtask slugs that depend on this one, or "None">

## Objective

<Clear, 2–3 sentence description of what this subtask accomplishes and why it matters in the context of the parent task>

## Scope

**In scope:**
- <specific thing 1>
- <specific thing 2>

**Out of scope:**
- <thing explicitly NOT covered by this subtask>

## Context

<Relevant background from the brainstorming that the implementing agent needs to know — architectural decisions, constraints, conventions, user preferences. Include enough context that the agent doesn't need to re-discover what was already discussed.>

## Key Areas

| File / Module | What changes |
|---|---|
| `path/to/file.ts` | <brief description of the change> |
| `path/to/other.ts` | <brief description of the change> |

## Approach

<High-level description of the approach. Name specific patterns, APIs, or existing code to follow. Don't write pseudocode — describe the strategy.>

## Acceptance Criteria

- [ ] <Criterion 1 — testable, specific>
- [ ] <Criterion 2>
- [ ] <Criterion 3>

## Dependencies & Integration Notes

<How this subtask integrates with the others. What interfaces does it expose or consume? What assumptions does it make about the state of the codebase when it starts?>
```

### After Each Plan

Add a comment to the corresponding subtask task:
```bash
notecove task comments add <SUBTASK-TASK-ID> "Plan created: <task-code>/PLAN-<subtask-slug>"
```

---

## Phase 4: Review & Finalize

Review the full decomposition for completeness and consistency.

### Review Checklist

#### 1. Coverage
- Every action from the original task is covered by at least one subtask
- No gaps — nothing was lost between brainstorming and decomposition

#### 2. No Overlaps
- Each subtask has a clear boundary
- No two subtasks modify the same files in conflicting ways
- If two subtasks touch the same area, the dependency order prevents conflicts

#### 3. Dependencies Are Correct
- The dependency graph has no cycles
- Independent subtasks are truly independent — they don't implicitly depend on each other
- The execution order makes sense

#### 4. Plans Are Self-Contained
- Each plan can be understood without reading the brainstorming notes
- Key decisions and context are included in each plan, not just referenced
- File paths and module names are specific and current (verify they exist)

#### 5. Plans Are Appropriately Scoped
- Each subtask is large enough to be meaningful but small enough to be a single PR
- No subtask is so large that it should be further decomposed
- No subtask is so small that it should be merged with another

### Finalize

Mark the main task as Done:
```bash
notecove task change <MAIN-TASK-ID> --state "Done"
notecove task comments add <MAIN-TASK-ID> "Decomposition complete. <N> subtasks with plans ready for execution."
```

**Present the final summary to the user:**

```
Decomposition complete for <task-code>.

<N> subtasks ready for execution:
1. Subtask 1: <name> — no dependencies
2. Subtask 2: <name> — depends on Subtask 1
3. ...

Suggested execution order: <order>

Each subtask has a self-contained plan in the Plans folder
that can be picked up by a personal-flow agent.
```
