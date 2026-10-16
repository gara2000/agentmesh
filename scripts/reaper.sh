#!/usr/bin/env bash
# reaper.sh — kills workers whose tasks have reached a terminal state
# Runs in a background tmux window in the orchestrator session. Never exits.
#
# Nothing else in AgentMesh ever kills a *live* worker window:
#
#   - task-done.sh deliberately skips `workers:<slug>`. The worker is the process
#     running that script, so killing the window there would terminate it
#     mid-run, before dependents are unblocked.
#   - the watchdog only ever inspects windows that are already gone.
#   - the worker does not exit by itself either: spawn-agent.sh launches the
#     interactive Claude REPL, so when the skill's last turn ends Claude returns
#     to its prompt and idles there indefinitely.
#
# So until this daemon existed, the only thing that reaped a finished worker was
# `agentmesh stop`. Parked workers leak a Claude process each, and — because
# spawn-agent.sh refuses duplicate window names and the launcher skips any slug
# with a live window — a task reopened from Done could never be picked up again.
#
# Being a separate process is the whole point: the reaper is not the thing being
# killed, so it works regardless of whether the worker cooperated, noticed the
# state change, or is wedged.
set -euo pipefail

AGENTMESH=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$AGENTMESH"

SIGNALS="$AGENTMESH/signals"
REGISTRY="$SIGNALS/workers"
LOG="$SIGNALS/events.log"
# notecove is a shell function, not a binary, so the CLI is called directly.
# Overridable so the tests can point it at a stub; nothing else sets it.
NOTECOVE="${AGENTMESH_NOTECOVE:-node /Applications/NoteCove.app/Contents/Resources/cli/cli.cjs}"

POLL_INTERVAL=30
# How long a task must have been terminal before its worker is killed.
#
# A worker sets Done and *then* runs task-done.sh, which sleeps 2s and retries
# dependent-unblocking up to three times — reaping instantly would kill it
# mid-cleanup and leave dependents blocked forever. The grace period also leaves
# a moment to read a finished worker's scrollback.
GRACE=60
ONCE=0
DRY_RUN=0
# Upper bound on any single NoteCove call, as in sidecar.sh: a hung CLI must
# cost one cycle, not the daemon.
CALL_TIMEOUT=30
# Matches LAUNCHING_TIMEOUT_SECS in launcher.py.
LAUNCHING_TIMEOUT=300

while [[ $# -gt 0 ]]; do
  case "$1" in
    --poll-interval) POLL_INTERVAL="$2"; shift 2 ;;
    --grace)         GRACE="$2";         shift 2 ;;
    --once)          ONCE=1;             shift ;;
    --dry-run)       DRY_RUN=1;          shift ;;
    *) echo "[reaper] Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# bootstrap.sh normally creates these, but this script must also survive being
# run by hand (`--once --dry-run`) in a tree that has never been bootstrapped:
# under `set -e` a missing log file would otherwise kill it on its first write.
mkdir -p "$SIGNALS"
touch "$LOG" "$REGISTRY"

log_event() {
  printf '%s\treaper       \t%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "${2:--}" >> "$LOG"
}

# Age of a file in whole seconds, or an empty string if it does not exist.
# python3 rather than stat(1) because the two stat flavours disagree and python3
# is already a hard dependency of every other component here.
file_age_secs() {
  python3 - "$1" <<'PYEOF' 2>/dev/null || true
import os, sys, time
try:
    print(int(time.time() - os.path.getmtime(sys.argv[1])))
except OSError:
    pass
PYEOF
}

# Window names in a session, or non-zero if tmux could not be asked.
#
# A session that does not exist is a legitimate empty result; a tmux that cannot
# be queried at all is not, and must not be flattened into "nothing is alive" —
# that would reap every tracked task at once. Same reasoning as
# _live_worker_windows in launcher.py.
list_windows() {
  local session="$1"
  if tmux list-windows -t "$session" -F '#{window_name}' 2>/dev/null; then
    return 0
  fi
  # The listing failed. "That session does not exist" is a legitimate empty
  # result; "tmux did not answer" is not. Telling them apart needs a question the
  # server must be able to answer — has-session alone fails in both cases.
  if tmux list-sessions >/dev/null 2>&1 \
     && ! tmux has-session -t "$session" 2>/dev/null; then
    return 0   # server is up and the session genuinely is not there
  fi
  return 1
}

# Kill a window by name, repeatedly: tmux kill-window removes only the first
# match, and a duplicate name would otherwise survive and keep the slug's window
# "live" forever.
kill_window() {
  local target_session="$1" name="$2" guard=0
  while tmux list-windows -t "$target_session" -F '#{window_name}' 2>/dev/null | grep -qxF "$name"; do
    tmux kill-window -t "${target_session}:${name}" 2>/dev/null || break
    guard=$((guard + 1))
    if [[ $guard -ge 5 ]]; then
      break
    fi
  done
  # A `while` loop exits with the status of the last command run in its body, so
  # without this the whole function fails whenever the final `if` was false —
  # and under `set -e` that takes the daemon down mid-reap.
  return 0
}

# Tear down everything belonging to a finished task.
# Idempotent: every step tolerates its target already being gone.
reap() {
  local slug="$1"

  if [[ $DRY_RUN -eq 1 ]]; then
    log_event "reap-dry-run" "$slug"
    echo "[reaper] $slug: would reap (dry run)"
    return 0
  fi

  kill_window workers "$slug"
  kill_window orchestrator "side-${slug}"
  kill_window orchestrator "pr-mon-${slug}"

  # Free the max-workers slot now rather than waiting for the watchdog's poll.
  sed -i '' "/^${slug} /d" "$REGISTRY" 2>/dev/null || true

  rm -f "${SIGNALS}/${slug}.inbox" \
        "${SIGNALS}/${slug}.seq" \
        "${SIGNALS}/${slug}.launching" \
        "${SIGNALS}/${slug}.untyped" \
        "${SIGNALS}/${slug}.seen-comments" \
        "${SIGNALS}/${slug}.seen-state" \
        "${SIGNALS}/${slug}.merged" \
        "${SIGNALS}/${slug}.sidecar-handle" \
        "${SIGNALS}/${slug}.backoff" \
        "${SIGNALS}/${slug}.crash-count" \
        "${SIGNALS}/${slug}.terminal-since"

  log_event "worker-reaped" "$slug"
  echo "[reaper] $slug: terminal — killed worker, sidecar and pr-monitor"
}

# One pass. Candidate-driven rather than task-list-driven: the only slugs worth
# asking about are those that still have something running or registered, which
# is at most max-workers of them. Listing every task instead would hit the CLI's
# default page size and silently miss tasks beyond it.
reap_pass() {
  local worker_windows orchestrator_windows
  if ! worker_windows=$(list_windows workers); then
    log_event "reap-skipped-tmux-unavailable"
    echo "[reaper] cannot list worker windows — skipping this pass"
    return 0
  fi
  if ! orchestrator_windows=$(list_windows orchestrator); then
    log_event "reap-skipped-tmux-unavailable"
    echo "[reaper] cannot list orchestrator windows — skipping this pass"
    return 0
  fi

  # Candidates: live worker windows, plus the slugs behind any side-/pr-mon-
  # window, plus anything still in the registry. The last two are what catch a
  # task the user closed while its worker was already dead — the worker window
  # is gone, but its sidecar and registry line would otherwise linger forever.
  local candidates
  candidates=$(
    {
      printf '%s\n' "$worker_windows"
      printf '%s\n' "$orchestrator_windows" \
        | sed -n -e 's/^side-//p' -e 's/^pr-mon-//p'
      awk '!/^#/ && NF {print $1}' "$REGISTRY" 2>/dev/null || true
    } | grep -v '^$' | sort -u || true
  )
  # `|| true`: grep exits 1 when every line was blank, and under `pipefail` that
  # would fail the assignment and — with `set -e` — kill the daemon on the
  # perfectly normal "nothing is running" pass.

  [[ -z "$candidates" ]] && return 0

  local slug since_file age task_json is_terminal
  while IFS= read -r slug; do
    [[ -z "$slug" ]] && continue
    since_file="${SIGNALS}/${slug}.terminal-since"

    # A worker mid-boot has no window yet and the task may not be claimed. Leave
    # it to the launcher's own guard rather than racing it.
    if [[ -f "${SIGNALS}/${slug}.launching" ]]; then
      age=$(file_age_secs "${SIGNALS}/${slug}.launching")
      if [[ -n "$age" && $age -lt $LAUNCHING_TIMEOUT ]]; then
        continue
      fi
    fi

    task_json=$(timeout "$CALL_TIMEOUT" $NOTECOVE task show "$slug" --json 2>/dev/null) || true
    # A failed or timed-out lookup is not evidence of anything. Never reap on it.
    [[ -z "$task_json" ]] && continue

    # isTerminal, never a stateId string: only the built-in states have literal
    # IDs. In this project Attention is `e4e1r03fdqm4krnf1rwb0tjdg7` and Won't Do
    # is `8epqdvvnns7rvf5knptf4gafys`, so string matching silently misses them —
    # the bug watchdog.sh still has.
    is_terminal=$(printf '%s' "$task_json" | python3 -c '
import json, sys
try:
    print("yes" if json.load(sys.stdin).get("isTerminal") else "no")
except (json.JSONDecodeError, ValueError):
    pass
' 2>/dev/null || true)

    if [[ "$is_terminal" != "yes" ]]; then
      # Either it was never terminal, or the user reopened it during the grace
      # window. Either way the sighting is void.
      if [[ -f "$since_file" ]]; then
        rm -f "$since_file"
        log_event "reap-cancelled-reopened" "$slug"
        echo "[reaper] $slug: no longer terminal — stand down"
      fi
      continue
    fi

    if [[ ! -f "$since_file" ]]; then
      touch "$since_file"
      log_event "reap-deferred-grace" "$slug"
      echo "[reaper] $slug: terminal — reaping in ${GRACE}s unless reopened"
      continue
    fi

    age=$(file_age_secs "$since_file")
    [[ -z "$age" ]] && continue
    [[ $age -lt $GRACE ]] && continue

    # The isTerminal read above is from this same pass, so it is already the
    # fresh re-check: a task reopened during the grace window took the branch
    # above and never reaches here.
    reap "$slug"
  done <<< "$candidates"
}

echo "[reaper] started (poll: ${POLL_INTERVAL}s, grace: ${GRACE}s, dry-run: ${DRY_RUN})"
log_event "started"

if [[ $ONCE -eq 1 ]]; then
  reap_pass
  exit 0
fi

while true; do
  sleep "$POLL_INTERVAL"
  reap_pass
done
