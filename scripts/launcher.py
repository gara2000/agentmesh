#!/usr/bin/env python3
"""
launcher.py — AgentMesh worker launcher.

Picks up Ready tasks from NoteCove and launches a worker agent plus its sidecar
for each one. That is the whole job.

It does not route events, does not talk to running agents, and does not change
task state. Once a worker is launched, all further communication happens
directly between that agent and the user through NoteCove comments, with the
agent's sidecar waking it when the user replies.

Usage: python3 launcher.py --project <key> [--max-workers <n>] [--profile <id>]
                           [--poll-interval <seconds>]
"""
import argparse
import json
import subprocess
import threading
import time
from pathlib import Path

AGENTMESH = Path(__file__).parent.parent
SCRIPTS = AGENTMESH / "scripts"
SIGNALS = AGENTMESH / "signals"

NOTECOVE_BIN = "node /Applications/NoteCove.app/Contents/Resources/cli/cli.cjs"

# How long a .launching flag stays authoritative. Covers Claude's boot time
# (10-60s observed) with margin; past this the worker is presumed dead on boot
# and the task becomes eligible again rather than being wedged in Ready forever.
LAUNCHING_TIMEOUT_SECS = 300

# ---------------------------------------------------------------------------
# Type -> agent-type mapping.
#
# This is the complete triage policy. A task whose type does not resolve here is
# refused and left in Ready — there is no LLM fallback and no default agent.
# ---------------------------------------------------------------------------

TYPE_MAP: dict[str, str] = {
    "feature":         "implementer",
    "bug":             "implementer",
    "plan":            "planner",
    "brainstorming":   "brainstormer",
    "documentation":   "documenter",
    "design":          "designer",
    "investigation":   "investigator",
    "ticketing":       "ticketer",
    "skilling":        "skill-creator",
    "rfc":             "rfc-creator",
}

# Comment posted once when a task cannot be triaged. Deduped via a flag file:
# the scan repeats every poll interval, so commenting per cycle would bury the task
# under thousands of identical comments a day.
UNTYPED_COMMENT = (
    "Cannot pick up this task: its type does not map to any agent. "
    "Set a supported type and it will be picked up on the next scan. "
    "Supported types: " + ", ".join(sorted(TYPE_MAP)) + "."
)


# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------

def log(component: str, event_type: str, slug: str = "-") -> None:
    ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    with open(SIGNALS / "events.log", "a") as f:
        f.write(f"{ts}\t{component:<12}\t{event_type}\t{slug}\n")


def notecove(args: str) -> str:
    result = subprocess.run(
        f"{NOTECOVE_BIN} {args}", shell=True, capture_output=True, text=True
    )
    if result.returncode != 0:
        log("launcher     ", f"notecove-error: {result.stderr.strip()[:120]}")
    return result.stdout.strip()


def run_bash(cmd: str) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, shell=True, capture_output=True, text=True)


def tmux(args: str) -> subprocess.CompletedProcess:
    return subprocess.run(f"tmux {args}", shell=True, capture_output=True, text=True)


def _print(msg: str) -> None:
    print(f"[launcher] {msg}", flush=True)


# ---------------------------------------------------------------------------
# Launcher
# ---------------------------------------------------------------------------

class Launcher:
    def __init__(self, project: str, max_workers: int, profile: str, poll_interval: int) -> None:
        self.project = project
        self.max_workers = max_workers
        self.profile = profile
        self.poll_interval = poll_interval
        self._lock = threading.Lock()
        self._stop = threading.Event()

    # -----------------------------------------------------------------------
    # Main entry point
    # -----------------------------------------------------------------------

    def run(self) -> None:
        _print(f"project={self.project} max-workers={self.max_workers} poll={self.poll_interval}s")
        log("launcher     ", "bootstrap-complete")
        self._write_heartbeat()

        t_heartbeat = threading.Thread(target=self._heartbeat_loop, daemon=True, name="heartbeat")
        t_heartbeat.start()

        # Single loop: scan for Ready tasks, launch what fits, sleep. There is no
        # event loop any more because nothing reports back to the launcher.
        while not self._stop.is_set():
            with self._lock:
                self.pick_up_ready_tasks()
            self._stop.wait(self.poll_interval)

    # -----------------------------------------------------------------------
    # Heartbeat — read by `agentmesh status`
    # -----------------------------------------------------------------------

    def _write_heartbeat(self) -> None:
        try:
            ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
            (SIGNALS / "launcher.heartbeat").write_text(ts)
        except OSError:
            pass

    def _heartbeat_loop(self) -> None:
        while not self._stop.is_set():
            self._stop.wait(30)
            if not self._stop.is_set():
                self._write_heartbeat()

    # -----------------------------------------------------------------------
    # In-flight guard
    #
    # The launcher no longer sets Doing — the worker does, as its first action.
    # That leaves the task in Ready while Claude boots, so without a guard the
    # next scan would launch a second worker for the same task.
    # -----------------------------------------------------------------------

    def _launching_flag(self, slug: str) -> Path:
        return SIGNALS / f"{slug}.launching"

    def _is_launching(self, slug: str) -> bool:
        flag = self._launching_flag(slug)
        try:
            age = time.time() - flag.stat().st_mtime
        except OSError:
            return False
        if age > LAUNCHING_TIMEOUT_SECS:
            # Worker died during boot and never claimed the task. Drop the flag
            # so this scan can retry it.
            log("launcher     ", "launching-flag-expired", slug)
            _print(f"{slug}: launching flag expired after {int(age)}s — retrying")
            flag.unlink(missing_ok=True)
            return False
        return True

    # -----------------------------------------------------------------------
    # Spawning
    # -----------------------------------------------------------------------

    def _spawn_worker(self, slug: str, agent_type: str) -> None:
        """Launch the worker agent and its sidecar, and register the worker."""
        self._launching_flag(slug).touch()

        subprocess.run([
            "bash", str(SCRIPTS / "spawn-agent.sh"),
            "workers", slug, f"/{agent_type}", slug, self.project,
        ])
        with open(SIGNALS / "workers", "a") as f:
            f.write(f"{slug} {slug} {agent_type}\n")
        log("launcher     ", f"{agent_type}-spawned", slug)
        _print(f"spawned {agent_type} for {slug}")

        self._spawn_sidecar(slug, agent_type)

    def _spawn_sidecar(self, slug: str, agent_handle: str) -> None:
        """Launch the sidecar window for slug (idempotent).

        Sidecars live in the `orchestrator` session, not `workers`, so that
        `workers` stays exclusively Claude agents — the watchdog's window
        liveness check and `agentmesh status` both read it that way. The sidecar
        is deliberately NOT added to signals/workers: it is not a worker, and
        registering it would make the watchdog treat its exit as a task crash.
        """
        window = f"side-{slug}"
        running = run_bash(
            f"tmux list-windows -t orchestrator -F '#{{window_name}}' 2>/dev/null | grep -qxF '{window}'"
        )
        if running.returncode == 0:
            return

        # The agent handle doubles as the comment author name the sidecar filters
        # on. spawn-agent.sh passes the skill name, and skills set --user to the
        # capitalised role, so map handle -> author name the same way here.
        author = AGENT_AUTHOR.get(agent_handle, agent_handle.capitalize())

        # -d so the launcher does not lose focus; 'orchestrator:' with a trailing
        # colon appends at the end of the window list, avoiding index collisions
        # when several windows are created in quick succession.
        result = None
        for attempt in range(3):
            result = tmux(
                f"new-window -d -t 'orchestrator:' -n {window} "
                f"'bash {SCRIPTS}/sidecar.sh --task {slug} --agent-handle \"{author}\"'"
            )
            if result.returncode == 0:
                break
            if attempt < 2:
                time.sleep(0.5)

        if result is None or result.returncode != 0:
            stderr = result.stderr.strip() if result else "no result"
            log("launcher     ", "sidecar-spawn-failed", slug)
            _print(f"ERROR: failed to create sidecar window for {slug} ({stderr!r})")
            return

        log("launcher     ", "sidecar-spawned", slug)
        _print(f"spawned sidecar for {slug}")

    # -----------------------------------------------------------------------
    # Task pickup
    # -----------------------------------------------------------------------

    def pick_up_ready_tasks(self) -> None:
        self._write_heartbeat()

        workers_file = SIGNALS / "workers"
        active_count = 0
        if workers_file.exists():
            active_count = len([
                l for l in workers_file.read_text().splitlines()
                if l.strip() and not l.startswith("#")
            ])

        launching = len([
            f for f in SIGNALS.glob("*.launching")
            if self._is_launching(f.name[: -len(".launching")])
        ])

        slots = self.max_workers - active_count - launching
        if slots <= 0:
            return

        result = run_bash(
            f"{NOTECOVE_BIN} task list --state Ready --project {self.project} --limit 50 --json"
        )
        try:
            tasks = json.loads(result.stdout)
        except (json.JSONDecodeError, ValueError):
            return
        if not tasks:
            return

        # Lower priority number = higher priority (P0 > P1 > P2); untriaged
        # priorities sort last.
        tasks.sort(key=lambda t: t.get("priority") if t.get("priority") is not None else float("inf"))

        for task in tasks:
            if slots <= 0:
                break

            slug_obj = task.get("slug", {})
            slug = slug_obj.get("short", "") if isinstance(slug_obj, dict) else str(slug_obj)
            if not slug:
                continue
            # Use the full slug (short prefix + unique id) for mutations, so two
            # tasks sharing a short prefix cannot produce an ambiguous-slug error.
            full_slug = slug_obj.get("full", slug) if isinstance(slug_obj, dict) else slug

            if self._is_launching(slug):
                continue

            agent_type = self._triage(task)
            if agent_type is None:
                self._refuse_untyped(slug, full_slug, task)
                continue

            title = task.get("title", "")
            log("launcher     ", "task-picked-up", slug)
            _print(f"picked up {slug}: {title} -> {agent_type}")
            (SIGNALS / f"{slug}.untyped").unlink(missing_ok=True)

            self._spawn_worker(slug, agent_type)
            slots -= 1

    def _triage(self, task: dict) -> str | None:
        """Resolve a task's type to an agent type, or None if unsupported.

        typeIds is checked first, then typeNames — projects differ in which one
        carries the meaningful value (some use opaque ids like "chore" or a UUID
        while the display name is accurate). First match wins, case-insensitive.
        """
        for key in ("typeIds", "typeNames"):
            for value in task.get(key) or []:
                mapped = TYPE_MAP.get(str(value).lower())
                if mapped:
                    return mapped
        return None

    def _refuse_untyped(self, slug: str, full_slug: str, task: dict) -> None:
        """Leave an untriageable task in Ready, commenting at most once.

        The task is deliberately left untouched — pickup fails rather than
        guessing an agent, and the task stays Ready so it is retried as soon as
        someone sets a usable type.
        """
        log("launcher     ", "task-refused-untyped", slug)
        flag = SIGNALS / f"{slug}.untyped"
        if flag.exists():
            return
        types = (task.get("typeNames") or task.get("typeIds") or []) or ["none"]
        _print(f"refusing {slug}: type {types} maps to no agent — left in Ready")
        notecove(f'task comments add {full_slug} --user "Launcher" "{UNTYPED_COMMENT}"')
        flag.touch()


# Agent handle -> the --user value that agent's skill writes comments with.
# Kept beside TYPE_MAP because the sidecar filters the agent's own comments by
# author name, so these must stay in step with each skill's `agent-user`.
AGENT_AUTHOR: dict[str, str] = {
    "implementer":   "Implementer",
    "planner":       "Planner",
    "brainstormer":  "Brainstormer",
    "documenter":    "Documenter",
    "designer":      "Designer",
    "investigator":  "Investigator",
    "ticketer":      "Ticketer",
    "skill-creator": "SkillCreator",
    "rfc-creator":   "RFCCreator",
}


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(description="AgentMesh Worker Launcher")
    parser.add_argument("--project", required=True, help="NoteCove project key")
    parser.add_argument("--max-workers", type=int, default=30)
    parser.add_argument("--profile", default="kmq9h71tepf95rac2b59xdbsq2")
    parser.add_argument("--poll-interval", type=int, default=30,
                        help="Seconds between Ready-task scans (default: 30)")
    args = parser.parse_args()

    Launcher(
        project=args.project,
        max_workers=args.max_workers,
        profile=args.profile,
        poll_interval=args.poll_interval,
    ).run()


if __name__ == "__main__":
    main()
