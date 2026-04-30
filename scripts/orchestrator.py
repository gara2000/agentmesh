#!/usr/bin/env python3
"""
orchestrator.py — Always-running Python daemon for AgentMesh event routing.

Handles all event routing, worker/reviewer spawning, and lifecycle management.
Forwards user-attention events to the Spokesman via spokesman-queue.
Receives and executes commands from Spokesman via orchestrator-cmds.

Usage: python3 orchestrator.py --project <key> [--mode standard|auto-review]
                                 [--max-workers <n>] [--profile <id>]
"""
import argparse
import json
import os
import re
import subprocess
import threading
from pathlib import Path

AGENTMESH = Path(__file__).parent.parent
SCRIPTS = AGENTMESH / "scripts"
SIGNALS = AGENTMESH / "signals"

NOTECOVE_BIN = "node /Applications/NoteCove.app/Contents/Resources/cli/cli.cjs"


# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------

def log(component: str, event_type: str, slug: str = "-") -> None:
    ts = subprocess.run(
        ["date", "-u", "+%Y-%m-%dT%H:%M:%SZ"],
        capture_output=True, text=True
    ).stdout.strip()
    line = f"{ts}\t{component:<12}\t{event_type}\t{slug}\n"
    with open(SIGNALS / "events.log", "a") as f:
        f.write(line)


def notecove(args: str) -> str:
    result = subprocess.run(
        f"{NOTECOVE_BIN} {args}",
        shell=True, capture_output=True, text=True
    )
    if result.returncode != 0:
        log("orchestrator ", f"notecove-error: {result.stderr.strip()[:120]}")
    return result.stdout.strip()


def run_bash(cmd: str) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, shell=True, capture_output=True, text=True)


def tmux(args: str) -> subprocess.CompletedProcess:
    return subprocess.run(f"tmux {args}", shell=True, capture_output=True, text=True)


def tmux_signal(signal_name: str) -> None:
    subprocess.run(["tmux", "wait-for", "-S", signal_name])


def get_task_state(slug: str) -> str:
    """Return the task's state name, lowercased (e.g. 'doing', 'attention', 'in review').

    Prefers the nested state.name field; falls back to stateName (flat string always
    present in notecove --json output) so the function is robust to schema changes.
    """
    result = run_bash(f"{NOTECOVE_BIN} task show {slug} --json")
    try:
        data = json.loads(result.stdout)
        state_obj = data.get("state", {})
        if isinstance(state_obj, dict) and state_obj.get("name"):
            return state_obj["name"].lower()
        return data.get("stateName", "").lower()
    except (json.JSONDecodeError, AttributeError):
        return ""


def get_task_seq(slug: str) -> int:
    seq_file = SIGNALS / f"{slug}.seq"
    try:
        return int(seq_file.read_text().strip())
    except (FileNotFoundError, ValueError):
        return 0


def spawn_agent(session: str, window: str, skill: str, slug: str, project: str) -> None:
    subprocess.run(
        ["bash", str(SCRIPTS / "spawn-agent.sh"), session, window, skill, slug, project]
    )


def task_done(slug: str, project: str, resume_sig: str = "") -> None:
    args = ["bash", str(SCRIPTS / "task-done.sh"), slug, project]
    if resume_sig:
        args.append(resume_sig)
    subprocess.run(args)


def append_spokesman_queue(slug: str, event_type: str) -> None:
    entry = f"{slug}:{event_type}\n"
    with open(SIGNALS / "spokesman-queue", "a") as f:
        f.write(entry)


# ---------------------------------------------------------------------------
# Orchestrator
# ---------------------------------------------------------------------------

class Orchestrator:
    def __init__(self, project: str, mode: str, max_workers: int, profile: str) -> None:
        self.project = project
        self.mode = mode
        self.max_workers = max_workers
        self.profile = profile
        # Lock protects shared signal files and active-worker state
        self._lock = threading.Lock()
        # Set when orchestrator should stop (all workers done, no Ready tasks)
        self._stop = threading.Event()
        # Slugs forwarded to Spokesman for triage but not yet spawned
        self._in_flight: set[str] = set()

    # -----------------------------------------------------------------------
    # Main entry point
    # -----------------------------------------------------------------------

    def run(self) -> None:
        print(f"[orchestrator] project={self.project} mode={self.mode} max-workers={self.max_workers}", flush=True)
        log("orchestrator ", "bootstrap-complete")

        # Initial task pickup
        self.pick_up_ready_tasks()

        # Worker-event thread
        t_worker = threading.Thread(target=self._worker_event_loop, daemon=True, name="worker-events")
        t_worker.start()

        # Spokesman-command thread
        t_cmd = threading.Thread(target=self._cmd_event_loop, daemon=True, name="spokesman-cmds")
        t_cmd.start()

        # Block until _stop is set (by _maybe_shutdown or shutdown command)
        self._stop.wait()

    # -----------------------------------------------------------------------
    # Event loops
    # -----------------------------------------------------------------------

    def _worker_event_loop(self) -> None:
        while not self._stop.is_set():
            subprocess.run(["tmux", "wait-for", "orchestrator-event"])
            if self._stop.is_set():
                break
            with self._lock:
                self._drain_worker_queue()

    def _cmd_event_loop(self) -> None:
        while not self._stop.is_set():
            subprocess.run(["tmux", "wait-for", "orchestrator-cmd-event"])
            if self._stop.is_set():
                break
            with self._lock:
                self._drain_commands()

    # -----------------------------------------------------------------------
    # Worker queue drain
    # -----------------------------------------------------------------------

    def _drain_worker_queue(self) -> None:
        queue_file = SIGNALS / "queue"
        while queue_file.exists() and queue_file.stat().st_size > 0:
            # Atomic drain: rename queue so new worker appends go to a fresh file
            tmp = queue_file.with_suffix(".draining")
            try:
                os.rename(queue_file, tmp)
            except FileNotFoundError:
                break
            content = tmp.read_text().strip()
            tmp.unlink(missing_ok=True)
            for entry in content.splitlines():
                entry = entry.strip()
                if entry:
                    self._handle_queue_entry(entry)

    def _handle_queue_entry(self, entry: str) -> None:
        """Dispatch on '<slug>:<event-type>' queue entries."""
        if ":" in entry:
            # Format: <slug>:event:<rest>  or  <slug>:event:pr-ready:<url>
            slug, _, rest = entry.partition(":")
            event_type = rest if rest.startswith("event:") else f"event:{rest}"
        else:
            # Legacy bare slug — fall back to reading task comments
            slug = entry
            event_type = self._event_type_from_comments(slug)

        slug = slug.strip()
        event_type = event_type.strip()

        log("orchestrator ", f"handling-event:{event_type}", slug)

        seq = get_task_seq(slug)
        resume_sig = f"{slug}-resume-{seq}"

        if event_type == "event:crash-detected":
            self._handle_crash(slug)
        elif event_type == "event:pr-merged":
            self._handle_pr_merged(slug, resume_sig)
        elif event_type == "event:completion":
            self._handle_completion(slug, resume_sig)
        elif event_type == "event:plan-ready":
            if self.mode == "auto-review":
                self._auto_spawn_plan_reviewer(slug)
            else:
                self._forward_to_spokesman(slug, event_type)
        elif event_type == "event:plan-review-complete":
            if self.mode == "auto-review":
                self._auto_pass_plan_review(slug, resume_sig)
            else:
                self._forward_to_spokesman(slug, event_type)
        elif event_type.startswith("event:pr-ready:"):
            pr_url = event_type[len("event:pr-ready:"):]
            reviewed_flag = SIGNALS / f"{slug}.reviewed"
            if self.mode == "auto-review" and not reviewed_flag.exists():
                self._auto_spawn_pr_reviewer(slug, pr_url)
            elif reviewed_flag.exists():
                # Auto-review mode, post-review: PR has been validated — forward as pr-ready
                reviewed_flag.unlink()
                self._spawn_pr_monitor(slug, pr_url)
                self._forward_to_spokesman(slug, event_type)
            else:
                # Standard mode: worker submitted PR, needs user decision (review or approve)
                self._spawn_pr_monitor(slug, pr_url)
                self._forward_to_spokesman(slug, f"event:pr-submitted:{pr_url}")
        elif event_type == "event:pr-review-complete":
            if self.mode == "auto-review":
                self._auto_pass_pr_review(slug, resume_sig)
            else:
                self._forward_to_spokesman(slug, event_type)
        elif event_type in ("event:questions", "event:ideas-ready", "event:selection-ready"):
            self._forward_to_spokesman(slug, event_type)
        else:
            log("orchestrator ", f"unknown-event:{event_type}", slug)
            self._forward_to_spokesman(slug, event_type)

    def _forward_to_spokesman(self, slug: str, event_type: str) -> None:
        log("orchestrator ", f"forwarding-to-spokesman:{event_type}", slug)
        append_spokesman_queue(slug, event_type)
        tmux_signal("spokesman-event")

    # -----------------------------------------------------------------------
    # Command drain (from Spokesman)
    # -----------------------------------------------------------------------

    def _drain_commands(self) -> None:
        cmds_file = SIGNALS / "orchestrator-cmds"
        if not cmds_file.exists() or cmds_file.stat().st_size == 0:
            return
        tmp = cmds_file.with_suffix(".draining")
        try:
            os.rename(cmds_file, tmp)
        except FileNotFoundError:
            return
        content = tmp.read_text().strip()
        tmp.unlink(missing_ok=True)
        for line in content.splitlines():
            line = line.strip()
            if line:
                self._execute_command(line)

    def _execute_command(self, cmd_line: str) -> None:
        """Execute '<slug>|<cmd>[|<args>]' command from Spokesman."""
        parts = cmd_line.split("|", 2)
        slug = parts[0].strip()
        cmd = parts[1].strip() if len(parts) > 1 else ""
        args = parts[2].strip() if len(parts) > 2 else ""

        seq = get_task_seq(slug)
        resume_sig = f"{slug}-resume-{seq}"

        log("orchestrator ", f"executing-cmd:{cmd}", slug)

        if cmd == "spawn":
            # Spokesman has triaged the task and decided the agent type
            agent_type = args if args in ("worker", "planner", "brainstormer") else "worker"
            self._in_flight.discard(slug)
            spawn_agent("workers", slug, f"/{agent_type}", slug, self.project)
            with open(SIGNALS / "workers", "a") as f:
                f.write(f"{slug} {slug}\n")
            log("orchestrator ", f"{agent_type}-spawned", slug)
            # Called with self._lock held — pick_up_ready_tasks() must not acquire the lock
            self.pick_up_ready_tasks()
        elif cmd == "resume":
            tmux_signal(resume_sig)
        elif cmd in ("done", "pr-approved"):
            log("orchestrator ", "review-approved", slug)
            self._handle_pr_approved(slug, resume_sig)
        elif cmd == "abort":
            task_done(slug, self.project)
            tmux(f"kill-window -t orchestrator:pr-mon-{slug} 2>/dev/null || true")
            (SIGNALS / f"{slug}.merged").unlink(missing_ok=True)
            (SIGNALS / f"{slug}.reviewed").unlink(missing_ok=True)
            self.pick_up_ready_tasks()
        elif cmd == "spawn-plan-reviewer":
            notecove(f"task change {slug} --state 'In Review'")
            spawn_agent("workers", f"plan-rev-{slug}", "/plan-reviewer", slug, self.project)
            log("orchestrator ", "plan-reviewer-spawned", slug)
        elif cmd == "spawn-pr-reviewer":
            notecove(f"task change {slug} --state 'In Review'")
            spawn_agent("workers", f"pr-rev-{slug}", "/pr-reviewer", slug, self.project)
            log("orchestrator ", "reviewer-spawned", slug)
        elif cmd == "kill-pr-monitor":
            tmux(f"kill-window -t orchestrator:pr-mon-{slug} 2>/dev/null || true")
            (SIGNALS / f"{slug}.merged").unlink(missing_ok=True)
            (SIGNALS / f"{slug}.reviewed").unlink(missing_ok=True)
        else:
            log("orchestrator ", f"unknown-cmd:{cmd}", slug)

    # -----------------------------------------------------------------------
    # Auto-review handlers
    # -----------------------------------------------------------------------

    def _spawn_pr_monitor(self, slug: str, pr_url: str) -> None:
        tmux(f"new-window -t orchestrator -n pr-mon-{slug} 2>/dev/null || true")
        tmux(f"send-keys -t 'orchestrator:pr-mon-{slug}' 'bash {SCRIPTS}/pr-monitor.sh {slug} {pr_url}' Enter")
        log("orchestrator ", "pr-monitor-spawned", slug)

    def _handle_pr_approved(self, slug: str, resume_sig: str) -> None:
        """Shared cleanup for all PR approval paths (user-approved and pr-merged).

        Sets task state to Done internally — callers must not set it beforehand.
        """
        notecove(f"task change {slug} --state Done")
        task_done(slug, self.project, resume_sig)
        tmux(f"kill-window -t orchestrator:pr-mon-{slug} 2>/dev/null || true")
        (SIGNALS / f"{slug}.merged").unlink(missing_ok=True)
        (SIGNALS / f"{slug}.reviewed").unlink(missing_ok=True)
        self.pick_up_ready_tasks()

    def _auto_spawn_plan_reviewer(self, slug: str) -> None:
        log("orchestrator ", "plan-reviewer-spawned", slug)
        notecove(f"task change {slug} --state 'In Review'")
        spawn_agent("workers", f"plan-rev-{slug}", "/plan-reviewer", slug, self.project)

    def _auto_pass_plan_review(self, slug: str, resume_sig: str) -> None:
        log("orchestrator ", "attention-resumed", slug)
        notecove(
            f'task comments add {slug} --user "Orchestrator" '
            f'"Plan review complete (auto-review mode). Review the reviewer\'s comment '
            f'and the REVIEW note in your task folder before implementing."'
        )
        notecove(f"task change {slug} --state Doing")
        tmux_signal(resume_sig)
        tmux(f"kill-window -t workers:plan-rev-{slug} 2>/dev/null || true")

    def _auto_spawn_pr_reviewer(self, slug: str, pr_url: str) -> None:
        log("orchestrator ", "reviewer-spawning", slug)
        notecove(f"task change {slug} --state 'In Review'")
        spawn_agent("workers", f"pr-rev-{slug}", "/pr-reviewer", slug, self.project)
        log("orchestrator ", "reviewer-spawned", slug)
        self._spawn_pr_monitor(slug, pr_url)

    def _auto_pass_pr_review(self, slug: str, resume_sig: str) -> None:
        log("orchestrator ", "pr-review-passed-to-worker", slug)
        notecove(
            f'task comments add {slug} --user "Orchestrator" '
            f'"PR review complete (auto-review mode). Read the reviewer\'s comment '
            f'and the GitHub PR comments. Apply any needed fixes and re-signal when ready."'
        )
        notecove(f"task change {slug} --state Doing")
        # Kill pr-monitor now so the orchestrator can spawn a fresh one on the worker's next PR signal
        tmux(f"kill-window -t orchestrator:pr-mon-{slug} 2>/dev/null || true")
        (SIGNALS / f"{slug}.reviewed").touch()
        tmux_signal(resume_sig)
        tmux(f"kill-window -t workers:pr-rev-{slug} 2>/dev/null || true")

    # -----------------------------------------------------------------------
    # Other event handlers
    # -----------------------------------------------------------------------

    def _handle_completion(self, slug: str, resume_sig: str) -> None:
        log("orchestrator ", "agent-completion-ack", slug)
        notecove(f"task change {slug} --state Done")
        task_done(slug, self.project, resume_sig)
        # Notify spokesman for display purposes
        append_spokesman_queue(slug, "event:completion")
        tmux_signal("spokesman-event")
        self.pick_up_ready_tasks()

    def _handle_pr_merged(self, slug: str, resume_sig: str) -> None:
        state = get_task_state(slug)
        if state not in ("attention", "in review"):
            return
        log("orchestrator ", "pr-auto-approved", slug)
        self._handle_pr_approved(slug, resume_sig)
        # Notify spokesman of the auto-approval
        append_spokesman_queue(slug, "event:pr-merged-auto-approved")
        tmux_signal("spokesman-event")

    def _handle_crash(self, slug: str) -> None:
        log("orchestrator ", "worker-crash-requeued", slug)
        notecove(f'task comments add {slug} --user "Orchestrator" "Worker crashed — restarting automatically."')
        tmux(f"kill-window -t orchestrator:pr-mon-{slug} 2>/dev/null || true")
        (SIGNALS / f"{slug}.merged").unlink(missing_ok=True)
        task_done(slug, self.project)
        notecove(f"task change {slug} --state Doing")
        spawn_agent("workers", slug, "/worker", slug, self.project)
        with open(SIGNALS / "workers", "a") as f:
            f.write(f"{slug} {slug}\n")

    # -----------------------------------------------------------------------
    # Shutdown detection
    # -----------------------------------------------------------------------

    def _maybe_shutdown(self) -> None:
        """Signal Spokesman and stop if no active workers, no in-flight tasks, and no Ready tasks remain."""
        if self._in_flight:
            return
        workers_file = SIGNALS / "workers"
        active = 0
        if workers_file.exists():
            active = sum(
                1 for l in workers_file.read_text().splitlines()
                if l.strip() and not l.startswith("#")
            )
        if active > 0:
            return

        result = run_bash(
            f"{NOTECOVE_BIN} task list --state Ready --project {self.project} --limit 1 --json"
        )
        try:
            if json.loads(result.stdout):
                return
        except (json.JSONDecodeError, ValueError):
            pass

        log("orchestrator ", "shutdown")
        append_spokesman_queue("-", "event:shutdown")
        tmux_signal("spokesman-event")
        self._stop.set()

    # -----------------------------------------------------------------------
    # Task pickup
    # -----------------------------------------------------------------------

    def pick_up_ready_tasks(self) -> None:
        workers_file = SIGNALS / "workers"
        active_count = 0
        if workers_file.exists():
            lines = [l for l in workers_file.read_text().splitlines() if l.strip() and not l.startswith("#")]
            active_count = len(lines)

        slots = self.max_workers - active_count - len(self._in_flight)
        if slots <= 0:
            return

        result = run_bash(
            f"{NOTECOVE_BIN} task list --state Ready --project {self.project} --limit {slots} --json"
        )
        try:
            tasks = json.loads(result.stdout)
        except (json.JSONDecodeError, ValueError):
            return

        if not tasks:
            self._maybe_shutdown()
            return

        for task in tasks:
            slug_obj = task.get("slug", {})
            slug = slug_obj.get("short", "") if isinstance(slug_obj, dict) else str(slug_obj)
            if not slug:
                continue

            notecove(f"task change {slug} --state Doing")
            log("orchestrator ", "task-picked-up", slug)
            self._in_flight.add(slug)
            append_spokesman_queue(slug, "event:task-ready")
            log("orchestrator ", "task-triage-forwarded", slug)

        tmux_signal("spokesman-event")

    # -----------------------------------------------------------------------
    # Helpers
    # -----------------------------------------------------------------------

    def _event_type_from_comments(self, slug: str) -> str:
        """Legacy: derive event type from last task comment (no queue event type)."""
        result = run_bash(f"{NOTECOVE_BIN} task show {slug} --format markdown-with-comments")
        for line in reversed(result.stdout.splitlines()):
            if line.startswith("- ") and "event:" in line:
                m = re.search(r"event:\S+", line)
                if m:
                    return m.group(0)
        return "event:unknown"


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(description="AgentMesh Orchestrator Daemon")
    parser.add_argument("--project", required=True, help="NoteCove project key")
    parser.add_argument("--mode", default="standard", choices=["standard", "auto-review"])
    parser.add_argument("--max-workers", type=int, default=5)
    parser.add_argument("--profile", default="kmq9h71tepf95rac2b59xdbsq2")
    args = parser.parse_args()

    orch = Orchestrator(
        project=args.project,
        mode=args.mode,
        max_workers=args.max_workers,
        profile=args.profile,
    )
    orch.run()


if __name__ == "__main__":
    main()
