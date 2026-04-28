#!/usr/bin/env bash
# folder-cleanup.sh — async folder housekeeping daemon
# Polls for Done/Won't-Do tasks and moves their subfolders into the adjacent
# Done folder. Runs in a background tmux window. Never exits.
set -euo pipefail

# cd to agentmesh so notecove can find its .notecove config
cd /Users/firas.gara/agentmesh

NOTECOVE="node /Applications/NoteCove.app/Contents/Resources/cli/cli.cjs"
LOG=/Users/firas.gara/agentmesh/signals/events.log
POLL_INTERVAL=60  # seconds

log_event() {
  printf '%s\tfolder-cleanup\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "${2:--}" >> "$LOG"
}

echo "[folder-cleanup] started"

while true; do
  sleep "$POLL_INTERVAL"

  # Fetch all folders and tasks in one shot
  all_folders=$($NOTECOVE folder list --json 2>/dev/null) || continue
  all_tasks=$($NOTECOVE task list --json 2>/dev/null) || continue

  # Find moves needed: for each terminal task, check if its named subfolder
  # still lives in the task's parent folder (not yet moved to Done).
  # Output: one line per move — "<slug>\t<subfolder-id>\t<done-folder-id>"
  moves=$(python3 - <<PYEOF
import sys, json

folders = json.loads("""$all_folders""")
tasks   = json.loads("""$all_tasks""")

folder_by_id           = {f['id']: f for f in folders}
folder_by_name_parent  = {(f['name'], f.get('parentId')): f for f in folders}
done_folder_ids        = {f['id'] for f in folders if f['name'] == 'Done'}

for task in tasks:
    if not task.get('isTerminal'):
        continue

    task_parent = task.get('folderId')
    slug        = task['slug']['short']

    subfolder = folder_by_name_parent.get((slug, task_parent))
    if not subfolder:
        continue

    # Already under a Done folder — nothing to do
    if subfolder.get('parentId') in done_folder_ids:
        continue

    done_folder = folder_by_name_parent.get(('Done', task_parent))
    if not done_folder:
        continue

    print(f"{slug}\t{subfolder['id']}\t{done_folder['id']}")
PYEOF
) || continue

  [ -z "$moves" ] && continue

  while IFS=$'\t' read -r slug subfolder_id done_folder_id; do
    if $NOTECOVE folder move "$subfolder_id" "$done_folder_id" 2>/dev/null; then
      echo "[folder-cleanup] moved $slug folder to Done"
      log_event "folder-moved" "$slug"
    fi
  done <<< "$moves"
done
