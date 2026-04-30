#!/usr/bin/env python3
"""
orchestrator.py — Always-running Python daemon for AgentMesh event routing.

Handles all event routing, worker/reviewer spawning, and lifecycle management.
Forwards user-attention events to the Spokesman via spokesman-queue.
Receives and executes commands from Spokesman via orchestrator-cmds.

Usage: python3 orchestrator.py --project <key> [--mode standard|auto-review]
                                 [--max-workers <n>] [--profile <id>]
                                 [--review-limit <n>]
"""
import argparse
import json
import os
import re
import subprocess
import threading
from pathlib import Path

from anomaly_checks import AnomalyChecker

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


def append_spokesman_ack(cmd_seq: int, slug: str, cmd: str) -> None:
    """Write ACK to spokesman-acks and fire the sequenced ACK signal."""
    entry = f"{cmd_seq}|{slug}|confirm|{cmd}\n"
    with open(SIGNALS / "spokesman-acks", "a") as f:
        f.write(entry)
    tmux_signal(f"spokesman-ack-{cmd_seq}")


def _print(msg: str) -> None:
    """Print an [orchestrator]-prefixed message to stdout."""
    print(f"[orchestrator] {msg}", flush=True)


# ---------------------------------------------------------------------------
# Orchestrator
# ---------------------------------------------------------------------------

class Orchestrator:
    def __init__(self, project: str, mode: str, max_workers: int, profile: str, review_limit: int) -> None:
        self.project = project
        self.mode = mode
        self.max_workers = max_workers
        self.profile = profile
        self.review_limit = review_limit
        # Lock protects shared signal files and active-worker state
        self._lock = threading.Lock()
        # Set when orchestrator should stop (all workers done, no Ready tasks)
        self._stop = threading.Event()
        # Slugs forwarded to Spokesman for triage but not yet spawned
        self._in_flight: set[str] = set()
        self._anomaly_checker = AnomalyChecker(SIGNALS, NOTECOVE_BIN)

    # -----------------------------------------------------------------------
    # Main entry point
    # -----------------------------------------------------------------------

    def run(self) -> None:
        _print(f"project={self.project} mode={self.mode} max-workers={self.max_workers} review-limit={self.review_limit}")
        log("orchestrator ", "bootstrap-complete")

        # Write initial heartbeat immediately so Spokesman sees a fresh timestamp on startup
        self._write_heartbeat()

        # Initial task pickup
        self.pick_up_ready_tasks()

        # Worker-event thread
        t_worker = threading.Thread(target=self._worker_event_loop, daemon=True, name="worker-events")
        t_worker.start()

        # Spokesman-command thread
        t_cmd = threading.Thread(target=self._cmd_event_loop, daemon=True, name="spokesman-cmds")
        t_cmd.start()

        # Heartbeat thread — writes timestamp every 30s so Spokesman can detect a dead orchestrator
        t_heartbeat = threading.Thread(target=self._heartbeat_loop, daemon=True, name="heartbeat")
        t_heartbeat.start()

        # Block until _stop is set (by _maybe_shutdown or shutdown command)
        self._stop.wait()

    # -----------------------------------------------------------------------
    # Heartbeat
    # -----------------------------------------------------------------------

    def _write_heartbeat(self) -> None:
        """Write current UTC timestamp to signals/orchestrator.heartbeat."""
        try:
            ts = subprocess.run(
                ["date", "-u", "+%Y-%m-%dT%H:%M:%SZ"],
                capture_output=True, text=True
            ).stdout.strip()
            (SIGNALS / "orchestrator.heartbeat").write_text(ts)
        except Exception:
            pass

    def _heartbeat_loop(self) -> None:
        """Background thread: refresh heartbeat file every 30 seconds."""
        while not self._stop.is_set():
            self._stop.wait(30)
            if not self._stop.is_set():
                self._write_heartbeat()

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
        self._write_heartbeat()
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
        self._anomaly_checker.run()

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
        _print(f"event {event_type} from {slug}")

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
        _print(f"forwarding to spokesman: {event_type} ({slug})")
        append_spokesman_queue(slug, event_type)
        tmux_signal("spokesman-event")

    # -----------------------------------------------------------------------
    # Command drain (from Spokesman)
    # -----------------------------------------------------------------------

    def _drain_commands(self) -> None:
        self._write_heartbeat()
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
        self._anomaly_checker.run()

    def _execute_command(self, cmd_line: str) -> None:
        """Execute '<cmd-seq>|<slug>|<cmd>[|<args>]' command from Spokesman.

        New format (4 parts, first is numeric): <cmd-seq>|<slug>|<cmd>[|<args>]
        Legacy format (2-3 parts):              <slug>|<cmd>[|<args>]
        """
        parts = cmd_line.split("|", 3)
        if len(parts) >= 3 and parts[0].strip().isdigit():
            # New typed-command format with ACK sequence
            cmd_seq: int | None = int(parts[0].strip())
            slug = parts[1].strip()
            cmd = parts[2].strip()
            args = parts[3].strip() if len(parts) > 3 else ""
        else:
            # Backward-compatible: old <slug>|<cmd>[|<args>] format
            cmd_seq = None
            slug = parts[0].strip()
            cmd = parts[1].strip() if len(parts) > 1 else ""
            args = parts[2].strip() if len(parts) > 2 else ""

        seq = get_task_seq(slug)
        resume_sig = f"{slug}-resume-{seq}"

        log("orchestrator ", f"executing-cmd:{cmd}", slug)
        _print(f"cmd {cmd} ({slug})" + (f" args={args}" if args else ""))

        if cmd == "spawn":
            # Spokesman has triaged the task and decided the agent type
            agent_type = args if args in ("worker", "planner", "brainstormer") else "worker"
            self._in_flight.discard(slug)
            spawn_agent("workers", slug, f"/{agent_type}", slug, self.project)
            with open(SIGNALS / "workers", "a") as f:
                f.write(f"{slug} {slug}\n")
            log("orchestrator ", f"{agent_type}-spawned", slug)
            _print(f"spawned {agent_type} for {slug}")
            # Called with self._lock held — pick_up_ready_tasks() must not acquire the lock
            self.pick_up_ready_tasks()
        elif cmd == "resume":
            _print(f"resuming {slug} via {resume_sig}")
            tmux_signal(resume_sig)
        elif cmd in ("done", "pr-approved"):
            log("orchestrator ", "review-approved", slug)
            self._handle_pr_approved(slug, resume_sig)
        elif cmd == "abort":
            _print(f"aborting {slug}")
            task_done(slug, self.project)
            tmux(f"kill-window -t orchestrator:pr-mon-{slug} 2>/dev/null || true")
            (SIGNALS / f"{slug}.merged").unlink(missing_ok=True)
            (SIGNALS / f"{slug}.reviewed").unlink(missing_ok=True)
            (SIGNALS / f"{slug}.review-start").unlink(missing_ok=True)
            self._clear_review_counts(slug)
            self.pick_up_ready_tasks()
        elif cmd == "spawn-plan-reviewer":
            notecove(f"task change {slug} --state 'In Review'")
            spawn_agent("workers", f"plan-rev-{slug}", "/plan-reviewer", slug, self.project)
            log("orchestrator ", "plan-reviewer-spawned", slug)
            _print(f"spawned plan-reviewer for {slug}")
            (SIGNALS / f"{slug}.review-start").touch()
        elif cmd == "spawn-pr-reviewer":
            notecove(f"task change {slug} --state 'In Review'")
            spawn_agent("workers", f"pr-rev-{slug}", "/pr-reviewer", slug, self.project)
            log("orchestrator ", "reviewer-spawned", slug)
            _print(f"spawned pr-reviewer for {slug}")
            (SIGNALS / f"{slug}.review-start").touch()
        elif cmd == "spawn-pr-monitor":
            self._spawn_pr_monitor(slug, args)
        elif cmd == "kill-pr-monitor":
            _print(f"killing pr-monitor for {slug}")
            tmux(f"kill-window -t orchestrator:pr-mon-{slug} 2>/dev/null || true")
            (SIGNALS / f"{slug}.merged").unlink(missing_ok=True)
            (SIGNALS / f"{slug}.reviewed").unlink(missing_ok=True)
            (SIGNALS / f"{slug}.review-start").unlink(missing_ok=True)
        else:
            log("orchestrator ", f"unknown-cmd:{cmd}", slug)
            _print(f"unknown cmd: {cmd} ({slug})")

        # Send ACK back to Spokesman (new typed-command protocol)
        if cmd_seq is not None:
            append_spokesman_ack(cmd_seq, slug, cmd)

    # -----------------------------------------------------------------------
    # Review counter helpers
    # -----------------------------------------------------------------------

    def _get_review_count(self, slug: str, review_type: str) -> int:
        """Return the current review cycle count for this slug and review type (0 if no file)."""
        counter_file = SIGNALS / f"{slug}.{review_type}-review-count"
        try:
            return int(counter_file.read_text().strip())
        except (FileNotFoundError, ValueError):
            return 0

    def _increment_review_count(self, slug: str, review_type: str) -> int:
        """Increment and persist the review cycle counter. Returns the new count."""
        count = self._get_review_count(slug, review_type) + 1
        (SIGNALS / f"{slug}.{review_type}-review-count").write_text(str(count))
        return count

    def _clear_review_counts(self, slug: str) -> None:
        """Remove both plan and PR review counter files for slug (terminal cleanup)."""
        (SIGNALS / f"{slug}.plan-review-count").unlink(missing_ok=True)
        (SIGNALS / f"{slug}.pr-review-count").unlink(missing_ok=True)

    # -----------------------------------------------------------------------
    # Auto-review handlers
    # -----------------------------------------------------------------------

    def _spawn_pr_monitor(self, slug: str, pr_url: str) -> None:
        tmux(f"new-window -t orchestrator -n pr-mon-{slug} 2>/dev/null || true")
        tmux(f"send-keys -t 'orchestrator:pr-mon-{slug}' 'bash {SCRIPTS}/pr-monitor.sh {slug} {pr_url}' Enter")
        log("orchestrator ", "pr-monitor-spawned", slug)
        _print(f"spawned pr-monitor for {slug} ({pr_url})")

    def _handle_pr_approved(self, slug: str, resume_sig: str) -> None:
        """Shared cleanup for all PR approval paths (user-approved and pr-merged).

        Sets task state to Done internally — callers must not set it beforehand.
        """
        _print(f"PR approved — marking {slug} done and resuming worker")
        notecove(f"task change {slug} --state Done")
        task_done(slug, self.project, resume_sig)
        tmux(f"kill-window -t orchestrator:pr-mon-{slug} 2>/dev/null || true")
        (SIGNALS / f"{slug}.merged").unlink(missing_ok=True)
        (SIGNALS / f"{slug}.reviewed").unlink(missing_ok=True)
        (SIGNALS / f"{slug}.review-start").unlink(missing_ok=True)
        self._clear_review_counts(slug)
        self.pick_up_ready_tasks()

    def _auto_spawn_plan_reviewer(self, slug: str) -> None:
        count = self._increment_review_count(slug, "plan")
        if count > self.review_limit:
            log("orchestrator ", "review-limit-reached:plan", slug)
            _print(f"review-limit-reached:plan count={count} slug={slug}")
            self._forward_to_spokesman(slug, "event:review-limit-reached:plan")
            return
        log("orchestrator ", "plan-reviewer-spawned", slug)
        _print(f"auto-spawning plan-reviewer for {slug} (cycle {count})")
        notecove(f"task change {slug} --state 'In Review'")
        spawn_agent("workers", f"plan-rev-{slug}", "/plan-reviewer", slug, self.project)
        (SIGNALS / f"{slug}.review-start").touch()

    def _auto_pass_plan_review(self, slug: str, resume_sig: str) -> None:
        log("orchestrator ", "attention-resumed", slug)
        _print(f"plan review complete — passing result to worker {slug}")
        notecove(
            f'task comments add {slug} --user "Orchestrator" '
            f'"Plan review complete (auto-review mode). Review the reviewer\'s comment '
            f'and the REVIEW note in your task folder before implementing."'
        )
        notecove(f"task change {slug} --state Doing")
        tmux_signal(resume_sig)
        tmux(f"kill-window -t workers:plan-rev-{slug} 2>/dev/null || true")
        (SIGNALS / f"{slug}.review-start").unlink(missing_ok=True)

    def _auto_spawn_pr_reviewer(self, slug: str, pr_url: str) -> None:
        count = self._increment_review_count(slug, "pr")
        if count > self.review_limit:
            log("orchestrator ", "review-limit-reached:pr", slug)
            _print(f"review-limit-reached:pr count={count} slug={slug}")
            self._forward_to_spokesman(slug, f"event:review-limit-reached:pr:{pr_url}")
            return
        log("orchestrator ", "reviewer-spawning", slug)
        _print(f"auto-spawning pr-reviewer for {slug} (cycle {count})")
        notecove(f"task change {slug} --state 'In Review'")
        spawn_agent("workers", f"pr-rev-{slug}", "/pr-reviewer", slug, self.project)
        log("orchestrator ", "reviewer-spawned", slug)
        (SIGNALS / f"{slug}.review-start").touch()
        self._spawn_pr_monitor(slug, pr_url)

    def _auto_pass_pr_review(self, slug: str, resume_sig: str) -> None:
        log("orchestrator ", "pr-review-passed-to-worker", slug)
        _print(f"PR review complete — passing result to worker {slug}")
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
        (SIGNALS / f"{slug}.review-start").unlink(missing_ok=True)

    # -----------------------------------------------------------------------
    # Other event handlers
    # -----------------------------------------------------------------------

    def _handle_completion(self, slug: str, resume_sig: str) -> None:
        log("orchestrator ", "agent-completion-ack", slug)
        _print(f"agent completion ack for {slug} — marking done")
        notecove(f"task change {slug} --state Done")
        task_done(slug, self.project, resume_sig)
        self._clear_review_counts(slug)
        # Notify spokesman for display purposes
        append_spokesman_queue(slug, "event:completion")
        tmux_signal("spokesman-event")
        self.pick_up_ready_tasks()

    def _handle_pr_merged(self, slug: str, resume_sig: str) -> None:
        state = get_task_state(slug)
        if state not in ("attention", "in review"):
            return
        log("orchestrator ", "pr-auto-approved", slug)
        _print(f"PR merged — auto-approving {slug}")
        self._handle_pr_approved(slug, resume_sig)
        # Notify spokesman of the auto-approval
        append_spokesman_queue(slug, "event:pr-merged-auto-approved")
        tmux_signal("spokesman-event")

    def _handle_crash(self, slug: str) -> None:
        log("orchestrator ", "worker-crash-requeued", slug)
        _print(f"CRASH detected for {slug} — restarting worker")
        notecove(f'task comments add {slug} --user "Orchestrator" "Worker crashed — restarting automatically."')
        tmux(f"kill-window -t orchestrator:pr-mon-{slug} 2>/dev/null || true")
        (SIGNALS / f"{slug}.merged").unlink(missing_ok=True)
        (SIGNALS / f"{slug}.reviewed").unlink(missing_ok=True)
        (SIGNALS / f"{slug}.review-start").unlink(missing_ok=True)
        self._clear_review_counts(slug)
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

        # Don't shut down if there are pending commands from Spokesman (e.g. spawn after restart)
        cmds_file = SIGNALS / "orchestrator-cmds"
        if cmds_file.exists() and cmds_file.stat().st_size > 0:
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
        _print("all tasks complete — shutting down")
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
            f"{NOTECOVE_BIN} task list --state Ready --project {self.project} --limit 50 --json"
        )
        try:
            tasks = json.loads(result.stdout)
        except (json.JSONDecodeError, ValueError):
            return

        if not tasks:
            self._maybe_shutdown()
            return

        # Sort by priority ascending so higher-priority tasks are picked first.
        # Lower number = higher priority (P0 > P1 > P2 …); tasks with no priority go last.
        tasks.sort(key=lambda t: t.get("priority") if t.get("priority") is not None else float("inf"))
        tasks = tasks[:slots]

        for task in tasks:
            slug_obj = task.get("slug", {})
            slug = slug_obj.get("short", "") if isinstance(slug_obj, dict) else str(slug_obj)
            if not slug:
                continue
            # Use full slug (includes unique ID) to avoid ambiguous-slug errors when two
            # tasks share the same short prefix (e.g. WORK-g93 matching WORK-g934 and WORK-g93w).
            full_slug = slug_obj.get("full", slug) if isinstance(slug_obj, dict) else slug

            title = task.get("title", "")
            notecove(f"task change {full_slug} --state Doing")
            log("orchestrator ", "task-picked-up", slug)
            _print(f"picked up {slug}: {title}")
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
    parser.add_argument("--review-limit", type=int, default=3,
                        help="Max auto-review cycles per task before escalating to Spokesman (default: 3)")
    args = parser.parse_args()

    orch = Orchestrator(
        project=args.project,
        mode=args.mode,
        max_workers=args.max_workers,
        profile=args.profile,
        review_limit=args.review_limit,
    )
    orch.run()


if __name__ == "__main__":
    main()
