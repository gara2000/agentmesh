#!/usr/bin/env python3
"""Anomaly detection for the AgentMesh orchestrator.

AnomalyChecker encapsulates the 4 structural invariant checks that run after
every event-queue drain.  It is instantiated once by the Orchestrator and its
run() method is called from within the orchestrator's lock, so no internal
locking is required.
"""
import json
import subprocess
import time
from pathlib import Path


class AnomalyChecker:
    """Runs structural invariant checks on the AgentMesh signal directory."""

    def __init__(self, signals: Path, notecove_bin: str) -> None:
        self._signals = signals
        self._notecove_bin = notecove_bin
        self._active_anomalies: set = set()

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def run(self) -> None:
        """Run all 4 invariant checks; escalate new violations to Spokesman."""
        current: set = set()

        # Compute tmux window list once; shared by checks 2 and 3.
        windows_result = self._list_worker_windows()

        self._check_reviewer_stuck(current)
        self._check_orphaned_reviewer(current, windows_result)
        self._check_stale_registry(current, windows_result)
        self._check_contradictory_flags(current)

        self._report_changes(current)
        self._active_anomalies = current

    # ------------------------------------------------------------------
    # Invariant checks
    # ------------------------------------------------------------------

    def _list_worker_windows(self) -> subprocess.CompletedProcess:
        return self._run_bash(
            "tmux list-windows -t workers -F '#{window_name}' 2>/dev/null || true"
        )

    def _check_reviewer_stuck(self, current: set) -> None:
        """Check 1: reviewer stuck >15 minutes (review-start flag older than 900s)."""
        for flag in self._signals.glob("*.review-start"):
            slug = flag.stem
            try:
                age = time.time() - flag.stat().st_mtime
            except OSError:
                continue
            if age > 900:
                current.add(f"reviewer-stuck:{slug}")

    def _check_orphaned_reviewer(
        self, current: set, windows_result: subprocess.CompletedProcess
    ) -> None:
        """Check 2: orphaned reviewer window (window exists but task not in-review)."""
        for window in windows_result.stdout.splitlines():
            window = window.strip()
            slug = None
            if window.startswith("plan-rev-"):
                slug = window[len("plan-rev-"):]
            elif window.startswith("pr-rev-"):
                slug = window[len("pr-rev-"):]
            if slug:
                state = self._get_task_state(slug)
                if state and state != "in review":
                    current.add(f"orphaned-reviewer:{slug}:{window}")

    def _check_stale_registry(
        self, current: set, windows_result: subprocess.CompletedProcess
    ) -> None:
        """Check 3: stale worker registry entry (slug in workers file but window gone)."""
        workers_file = self._signals / "workers"
        if workers_file.exists():
            live_windows = {w.strip() for w in windows_result.stdout.splitlines()}
            for line in workers_file.read_text().splitlines():
                if not line.strip() or line.startswith("#"):
                    continue
                parts = line.split()
                if len(parts) >= 2 and parts[1].strip() not in live_windows:
                    current.add(f"stale-registry:{parts[0].strip()}")

    def _check_contradictory_flags(self, current: set) -> None:
        """Check 4: contradictory flags (both .reviewed and .merged exist for same slug)."""
        for reviewed_flag in self._signals.glob("*.reviewed"):
            slug = reviewed_flag.stem
            if (self._signals / f"{slug}.merged").exists():
                current.add(f"contradictory-flags:{slug}")

    def _report_changes(self, current: set) -> None:
        """Report new anomalies to Spokesman; log resolved ones."""
        new_anomalies = current - self._active_anomalies
        for anomaly in sorted(new_anomalies):
            slug = anomaly.split(":")[1] if ":" in anomaly else "-"
            self._log(f"anomaly-detected:{anomaly}", slug)
            self._append_spokesman_queue(slug, f"event:anomaly-detected:{anomaly}")
            self._tmux_signal("spokesman-event")

        for anomaly in sorted(self._active_anomalies - current):
            slug = anomaly.split(":")[1] if ":" in anomaly else "-"
            self._log(f"anomaly-resolved:{anomaly}", slug)

    # ------------------------------------------------------------------
    # Helpers (inlined to avoid circular imports with orchestrator.py)
    # ------------------------------------------------------------------

    def _run_bash(self, cmd: str) -> subprocess.CompletedProcess:
        return subprocess.run(cmd, shell=True, capture_output=True, text=True)

    def _get_task_state(self, slug: str) -> str:
        result = self._run_bash(f"{self._notecove_bin} task show {slug} --json")
        try:
            data = json.loads(result.stdout)
            state_obj = data.get("state", {})
            if isinstance(state_obj, dict) and state_obj.get("name"):
                return state_obj["name"].lower()
            return data.get("stateName", "").lower()
        except (json.JSONDecodeError, AttributeError):
            return ""

    def _log(self, event_type: str, slug: str = "-") -> None:
        ts = subprocess.run(
            ["date", "-u", "+%Y-%m-%dT%H:%M:%SZ"],
            capture_output=True, text=True,
        ).stdout.strip()
        line = f"{ts}\torchestrator \t{event_type}\t{slug}\n"
        with open(self._signals / "events.log", "a") as f:
            f.write(line)

    def _append_spokesman_queue(self, slug: str, event_type: str) -> None:
        entry = f"{slug}:{event_type}\n"
        with open(self._signals / "spokesman-queue", "a") as f:
            f.write(entry)

    def _tmux_signal(self, signal_name: str) -> None:
        subprocess.run(["tmux", "wait-for", "-S", signal_name])
