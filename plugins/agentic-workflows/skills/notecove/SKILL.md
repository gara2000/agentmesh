---
name: notecove
description: Interact with NoteCove (notes, tasks, folders, projects, search) via the CLI. The user's prompt describes what to do; this skill provides the CLI reference and setup instructions.
disable-model-invocation: true
allowed-tools: Bash(notecove *)
hint: "Describe what you want to do with NoteCove (create/edit/list/search notes, tasks, folders, projects). Optional flags: --profile <id-or-name>, --project <key-or-name>, --folder <id-or-name>, --sd <id-or-name>, --task <slug>"
---

# NoteCove — CLI Interaction Guide

**Task:** $ARGUMENTS

---

## Setup

> The NoteCove desktop app must be running for the CLI to work.
> All artifacts (notes, tasks, folders) live in NoteCove — not on disk.

### Step 1: Resolve Context

Parse `$ARGUMENTS` for optional flags:
- `--profile <id-or-name>` — profile ID or name (case-insensitive)
- `--project <key-or-name>` — project key or name (case-insensitive); defaults to **all projects**
- `--folder <id-or-name>` — folder ID or name (case-insensitive); scopes all operations to this folder
- `--sd <id-or-name>` — storage directory ID or name; restricts notes access to that SD. **Only used when `--project` is NOT specified.** If `--project` is provided, ignore `--sd`.
- `--task <slug>` — task slug (e.g. `PERS-42`); fetches the task and provides its content as additional context for the agent's work

#### Resolve profile ID

**Default:** If `--profile` is not provided, use `kmq9h71tepf95rac2b59xdbsq2` (the "Agents" profile) without asking.

If `--profile` looks like a name (not a long alphanumeric ID), resolve it:
```bash
notecove profiles
```
Match the name (case-insensitive) against the listed profiles and extract the ID.

#### Resolve project key

If `--project` looks like a name rather than an all-caps key, resolve it:
```bash
notecove project list --json
```
Match the name (case-insensitive) against the listed projects and extract the slug prefix.

If `--project` is not provided, the agent will be authorized for **all projects** (see Step 2).

#### Resolve folder ID

If `--folder` is provided and looks like a name (not an ID), resolve it after initialization:
```bash
notecove folder list --json
```
Match the name (case-insensitive). If no match, create the folder:
```bash
notecove folder create "<name>"
```
Use the resolved/created folder ID as `--folder <id>` for all commands that support it.

#### Resolve storage directory ID

If `--sd` is provided and looks like a name (not an ID), resolve it after initialization:
```bash
notecove sd list --json
```
Match the name (case-insensitive) against the listed storage directories and extract the ID.

#### Resolve task (post-init)

If `--task` is provided, fetch the task after initialization:
```bash
notecove task show <slug> --format markdown
```

If `--folder` is also provided and was resolved to a folder ID, add a folder link to the task description. First retrieve the folder details:
```bash
notecove folder show <folder-id> --json
```
Extract the folder path from the output, then append the folder link to the task description:
```bash
notecove task change <slug> --content-file - --content-format markdown << 'EOF'
<existing task content>

[[F:<folder-id>|<folder-path>]]
EOF
```

Only add the folder link if the task description does not already contain a `[[F:` link for that folder.

### Step 2: Initialize CLI Access

Build the init command based on resolved arguments:

| Condition | Init command |
|-----------|-------------|
| `--project` provided | `notecove init --profile <id> --tasks-project <KEY> --notes` |
| No project, `--sd` provided | `notecove init --profile <id> --all-tasks --notes --sd <sd-id>` |
| No project, no sd | `notecove init --profile <id> --all-tasks --all-notes` |

```bash
notecove init <flags from table above>
```

Approve the access request in the NoteCove desktop app when prompted.
If already initialized, `init` is a no-op — proceed.

---

## CLI Reference

### Profiles

```bash
notecove profiles                                # list all profiles
```

### Notes

#### List & Read

```bash
notecove note list [--folder <id>] [--limit <n>] [--offset <n>] [--json]
notecove note show <id> [--format text|markdown|json|markdown-with-comments]
notecove note headings <id> [--json]             # list headings (IDs needed for heading links)
notecove note recent [--hot|--cold] [--hot-days <n>] [--cold-days <n>] [--limit <n>] [--json]
```

- Default format for `show` is `markdown`. Use `markdown-with-comments` to get content + comment threads in one call.
- Use `--format text` before adding inline comments (line numbers are 1-indexed from first content line).

#### Create & Edit

```bash
notecove note create [--folder <id>] [--sd <id>] [--content <text>] [--content-file <path>] [--format text|markdown|json] [--json]
notecove note edit <id> --content <text>          # replace content
notecove note edit <id> --content-file <path>     # replace content from file (use - for stdin)
notecove note edit <id> --append <text>           # append content
notecove note edit <id> --append-file <path>      # append content from file (use - for stdin)
notecove note edit <id> --diff <content>          # apply unified diff patch
notecove note edit <id> --diff-file <path>        # apply unified diff from file (use - for stdin)
notecove note edit <id> --title <title>           # rename
notecove note edit <id> --folder <id>             # move to folder (empty string for root)
notecove note edit <id> --replace                 # force full replacement (discards comment anchors)
```

- Note titles are derived from the first line of content on create.
- `--sd <id>` on create is required when multiple storage directories exist and no `--folder` is given.
- Prefer `--diff` / `--diff-file` for surgical edits over full `--content` replacement.
- Prefer heredoc stdin over temp files (see Patterns section).

#### Delete & Organize

```bash
notecove note delete <id>
notecove note pin <id> [--json]
notecove note unpin <id> [--json]
notecove note open <id>                          # open in desktop app
```

#### Comments

```bash
notecove note comments list <note-id>
notecove note comments add <note-id> [content]
notecove note comments reply <note-id> <thread-id> <content>
notecove note comments resolve <note-id> <thread-id>
notecove note comments reopen <note-id> <thread-id>
```

#### History

```bash
notecove note history list <note-id>
notecove note history diff <note-id>             # diff between two history points
notecove note history restore <note-id>          # restore to historical state
notecove note history duplicate <note-id>        # duplicate at historical state
notecove note history tag                        # manage revision tags
```

#### Similarity & Links

```bash
notecove note similar [note-id] [--limit <n>] [--json]   # find semantically similar notes/tasks
```

### Tasks

#### List & Read

```bash
notecove task list [--project <slug>] [--state <state>] [--priority <n>] [--type <type>] [--folder <id>] [--parent <slug>] [--assignee <id>] [--unassigned] [--limit <n>] [--offset <n>] [--json]
notecove task show <slug> [--project <slug>] [--format text|markdown|json|markdown-with-comments] [--timestamp <ts>] [--tag <name>]
notecove task ready [--project <slug>] [--priority <n>] [--limit <n>] [--json]   # tasks with no blockers, not terminal
notecove task recent [--hot|--cold] [--hot-days <n>] [--cold-days <n>] [--limit <n>] [--json]
notecove task tree <slug> [--project <slug>] [--depth <n>] [--json]              # show task hierarchy
```

#### Create

```bash
notecove task create [title] [--project <slug>] [--folder <id>] [--state <name>] [--type <type>] [--priority <n>] [--parent <slug>] [--block <slug>] [--content <text>] [--content-file <path>] [--content-format text|markdown|json] [--assignee <id>] [--discovered-from <slug>] [--json]
```

- `--block` can be used multiple times to add multiple blocking tasks.
- `--assignee` accepts identifiers like `"@drew"`, `"claude"`.

#### Update

```bash
notecove task change <slug> [--project <slug>] [--title <text>] [--state <name>] [--priority <n>] [--type <name>] [--content <text>] [--content-file <path>] [--content-format text|markdown|json] [--replace] [--parent <slug>] [--no-parent] [--block <slug>] [--unblock <slug>] [--assignee <id>] [--no-assignee] [--discovered-from <slug>] [--move-to-project <prefix>] [--move-to-default-folder] [--json]
```

- `--block` / `--unblock` can be used multiple times.
- `--move-to-project` moves a task to a different project; add `--move-to-default-folder` to use the target project's default folder.

#### Delete

```bash
notecove task delete <slug>                      # soft delete
```

#### Search

```bash
notecove task search <query> [--project <slug>] [--state <name>] [--priority <n>] [--limit <n>] [--json]
```

#### Comments

```bash
notecove task comments list <slug>
notecove task comments add <slug> <content>
notecove task comments reply <slug> <thread-id> <content>
```

#### History & Links

```bash
notecove task history list <task-id>
notecove task history tag                        # manage revision tags
notecove task inbound-links <slug> [--project <slug>] [--type all|notes|tasks] [--json]
notecove task similar [slug] [--project <slug>] [--limit <n>] [--json]
```

#### Attachments

```bash
notecove task attachments <id> [--json]          # list attachments
```

#### Open

```bash
notecove task open <slug>                        # open in desktop app
```

### Folders

```bash
notecove folder list [--json]
notecove folder show <id> [--json]
notecove folder create <name> [--parent <id>]
notecove folder rename <id> <new-name>
notecove folder move <id> <parent-id>            # use "root" to move to root level
notecove folder delete <id>
notecove folder open <id>                        # open in desktop app
```

### Projects

```bash
notecove project list [--json]
notecove project show [slug-prefix] [--json]
notecove project create <name> [--json]
notecove project change <slug-prefix>            # change project config (states, types)
notecove project archive <slug-prefix>           # soft delete (reversible)
notecove project restore <slug-prefix>           # restore archived project
```

### Storage Directories

```bash
notecove sd list [--json]
notecove sd create <name>
notecove sd rename <id> <name>
notecove sd remove <id>                          # removes from Notecove, does NOT delete files on disk
```

### Search (Unified)

```bash
notecove search [query] [--type all|notes|tasks] [--folder <id>] [--include-subfolders] [--project <slug>] [--semantic] [--limit <n>] [--offset <n>] [--json] [--sort <field>] [--sort-dir asc|desc] [--state <name>] [--task-type <name>] [--min-priority <n>] [--max-priority <n>] [--tag <name>] [--exclude-tag <name>] [--combine and|or] [--terminal] [--active] [--has-parent] [--no-parent] [--has-children] [--no-children] [--has-blockers] [--no-blockers] [--has-uncompleted-blockers] [--no-uncompleted-blockers] [--created-after <date>] [--created-before <date>] [--modified-after <date>] [--modified-before <date>]
```

- Sort fields: `modified`, `created`, `title`, `state`, `priority`, `type`, `project`.
- Use `--semantic` for vector-based similarity search instead of full-text.
- Filters are combined with `--combine and` (default) or `--combine or`.

### Recent

```bash
notecove recent [--hot|--cold] [--hot-days <n>] [--cold-days <n>] [--limit <n>] [--json]
```

- `--hot` (default): recently modified items (last 7 days).
- `--cold`: items not modified in `--cold-days` days (default 30).

### Open

```bash
notecove open <id>                               # open note or task in desktop app
```

---

## Patterns & Conventions

### Link Syntax

Use these patterns when writing content that links to other NoteCove items:

```
Task link:    [[T:longid|display text]]
Note link:    [[longid|display text]]
Heading link: [[longid#heading-id|display text]]
Folder link:  [[F:longid|folder path]]
```

**Deriving the longid:** From `--json` output, strip the project prefix and colon from the `id` field.
Example: `"NOTE-k7r:gk0z65pfqd32qgwzkdw1d29"` -> `"k7rgk0z65pfqd32qgwzkdw1d29"`

### JSON Output Discovery

Before parsing `--json` output from any command, call the same command with `--json-format` to get the exact field names and types:

```bash
notecove task list --json-format
notecove note show --json-format
notecove folder list --json-format
notecove search --json-format
notecove project list --json-format
notecove sd list --json-format
```

### Heredoc / Stdin Pattern

Prefer heredoc syntax over temp files when content is self-contained — it avoids the `mktemp` -> `write` -> `rm` cycle:

```bash
notecove note create --folder <id> --content-file - --format markdown --json << 'EOF'
# My Note
Content here.
EOF
```

Supported commands with `--content-file -`:
- `notecove note create --content-file -`
- `notecove note edit <id> --content-file -`
- `notecove note edit <id> --append-file -`
- `notecove note edit <id> --diff-file -`
- `notecove task create --content-file -`
- `notecove task change <slug> --content-file -`

### Pagination

Commands that default to **50 results** and silently truncate:
- `note list`
- `task list`
- `search`

Commands with **no limit**: `folder list`, `project list`, `sd list`.

**If result count equals the limit, you are seeing a partial view.** Always paginate with `--offset` when exhaustively processing:

```bash
# Page 1
notecove task list --offset 0 --limit 50 --json
# Page 2
notecove task list --offset 50 --limit 50 --json
# Continue until result count < limit
```

### Content Formats

- `text` — plain text
- `markdown` — formatted markdown (default for most commands)
- `json` — raw ProseMirror structure
- `markdown-with-comments` — markdown + comment threads in one call (for `note show` / `task show`)

### Task States

Default task lifecycle: `"To Do"` -> `"In Progress"` -> `"Done"`.
Projects may define custom states — use `notecove project show <slug>` to see available states.

### General Tips

- Always capture IDs returned by `create` commands — they are needed for subsequent operations.
- Use `--json` when you need to parse output programmatically.
- Notes accept full Markdown content.
- Task priorities range from 1 (lowest) to 5 (highest).
- Use `task ready` to find actionable tasks (no blockers, not terminal).
- Use `note similar` / `task similar` for semantic deduplication or discovery.

---

Now carry out the task described in `$ARGUMENTS` using the CLI above.
