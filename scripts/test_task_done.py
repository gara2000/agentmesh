"""
Unit tests for task-done.sh — terminal-state cleanup.

Unblocking dependents is the one step here that nothing else will ever do. The
watchdog eventually tidies windows and signal files; no other component looks at
a blocked task's blocker list. So a bug in the matching is permanent: the
dependent stays Blocked forever, with nothing logged and nothing to notice it.

Which is what the short slug risked. The old test was
`b['slug']['short'] != '$SLUG'` — comparing a slug the worker was handed when it
booted against the blocker's slug.short as it reads *now*. A task created in
between lengthens the prefix, the two stop being equal, this task is not
recognised as one of its own dependent's blockers, and the unblock is skipped.
Matching on slug.full removes the failure mode: it never changes.

Driven end-to-end through a stub CLI on PATH.
"""
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).parent

NOTECOVE_STUB = r"""#!/usr/bin/env bash
set -uo pipefail
STUB="$STUB_DIR"
echo "$*" >> "$STUB/calls.log"

case "$1 ${2:-}" in
  "task list")
    # Serve either the blocked list or the full list, depending on the flags.
    case "$*" in
      *"--state Blocked"*) cat "$STUB/blocked.json" 2>/dev/null ;;
      *)                   cat "$STUB/all.json" 2>/dev/null ;;
    esac
    ;;
  "task show")
    ref="$3"
    cat "$STUB/show.$ref.json" 2>/dev/null || exit 1
    ;;
  "task change")
    ref="$3"; state=""
    while [ $# -gt 0 ]; do
      case "$1" in --state) state="$2"; shift 2 ;; *) shift ;; esac
    done
    echo "$ref|$state" >> "$STUB/changed.log"
    ;;
esac
exit 0
"""


def _blocker(full: str, short: str, terminal: bool) -> dict:
    return {"slug": {"short": short, "full": full},
            "state": {"isTerminal": terminal}}


class TaskDoneHarness(unittest.TestCase):
    SLUG = "WORK-abc"
    FULL = "WORK-abc:longid"

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        root = Path(self._tmp.name)
        self.scripts = root / "scripts"
        self.signals = root / "signals"
        self.stub = root / "stub"
        for d in (self.scripts, self.signals, self.stub):
            d.mkdir()

        for name in ("task-done.sh", "notecove-ref.sh"):
            shutil.copy(SCRIPTS / name, self.scripts / name)
        (self.scripts / "task-done.sh").chmod(0o755)
        (self.signals / "events.log").touch()
        (self.signals / "workers").write_text(f"{self.SLUG} {self.SLUG} implementer\n")
        (self.signals / f"{self.SLUG}.full-slug").write_text(self.FULL)

        p = self.stub / "nc"
        p.write_text(NOTECOVE_STUB)
        p.chmod(0o755)
        # tmux is called to kill side windows; a no-op stub keeps the test from
        # touching the real server.
        t = self.stub / "tmux"
        t.write_text("#!/usr/bin/env bash\nexit 0\n")
        t.chmod(0o755)

    def set_blocked(self, tasks: list):
        (self.stub / "blocked.json").write_text(json.dumps(tasks))

    def set_dependent(self, full: str, blockers: list):
        (self.stub / f"show.{full}.json").write_text(json.dumps({"blockers": blockers}))

    def run_task_done(self) -> subprocess.CompletedProcess:
        env = dict(os.environ)
        env["PATH"] = f"{self.stub}{os.pathsep}{env.get('PATH', '')}"
        env["STUB_DIR"] = str(self.stub)
        env["AGENTMESH_NOTECOVE"] = "nc"
        return subprocess.run(
            ["bash", str(self.scripts / "task-done.sh"), self.SLUG, "WORK"],
            capture_output=True, text=True, env=env, timeout=120)

    def changed(self) -> list:
        p = self.stub / "changed.log"
        return p.read_text().splitlines() if p.exists() else []


class TestUnblocking(TaskDoneHarness):
    def test_sole_blocker_releases_the_dependent(self):
        self.set_blocked([{"slug": {"short": "WORK-dep", "full": "WORK-dep:dd"}}])
        self.set_dependent("WORK-dep:dd", [_blocker(self.FULL, self.SLUG, True)])
        r = self.run_task_done()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.changed(), ["WORK-dep:dd|Ready"])

    def test_matching_survives_a_lengthened_short_slug(self):
        """
        The regression this change is for. The worker holds `WORK-abc`; by the
        time it finishes, another task has pushed the blocker's short slug to
        `WORK-abcd`. Comparing short slugs misses, and the dependent is blocked
        forever with nothing logged.
        """
        self.set_blocked([{"slug": {"short": "WORK-dep", "full": "WORK-dep:dd"}}])
        self.set_dependent("WORK-dep:dd", [_blocker(self.FULL, "WORK-abcd", True)])
        self.run_task_done()
        self.assertEqual(self.changed(), ["WORK-dep:dd|Ready"])

    def test_dependent_with_another_open_blocker_stays_blocked(self):
        self.set_blocked([{"slug": {"short": "WORK-dep", "full": "WORK-dep:dd"}}])
        self.set_dependent("WORK-dep:dd", [
            _blocker(self.FULL, self.SLUG, True),
            _blocker("WORK-oth:oo", "WORK-oth", False),
        ])
        self.run_task_done()
        self.assertEqual(self.changed(), [],
                         "releasing a task with an open blocker would start work early")

    def test_dependent_with_another_finished_blocker_is_released(self):
        self.set_blocked([{"slug": {"short": "WORK-dep", "full": "WORK-dep:dd"}}])
        self.set_dependent("WORK-dep:dd", [
            _blocker(self.FULL, self.SLUG, True),
            _blocker("WORK-oth:oo", "WORK-oth", True),
        ])
        self.run_task_done()
        self.assertEqual(self.changed(), ["WORK-dep:dd|Ready"])

    def test_blocked_task_we_do_not_block_is_untouched(self):
        self.set_blocked([{"slug": {"short": "WORK-dep", "full": "WORK-dep:dd"}}])
        self.set_dependent("WORK-dep:dd", [_blocker("WORK-xyz:xx", "WORK-xyz", False)])
        self.run_task_done()
        self.assertEqual(self.changed(), [])

    def test_no_blocked_tasks_is_not_an_error(self):
        self.set_blocked([])
        r = self.run_task_done()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.changed(), [])


class TestCleanup(TaskDoneHarness):
    def test_registry_entry_is_removed(self):
        self.set_blocked([])
        self.run_task_done()
        self.assertEqual((self.signals / "workers").read_text().strip(), "")

    def test_signal_files_are_removed(self):
        self.set_blocked([])
        for suffix in ("inbox", "ready", "self-state", "seen-comments", "seen-state",
                       "full-slug", "task-id", "summary-posted"):
            (self.signals / f"{self.SLUG}.{suffix}").write_text("x")
        self.run_task_done()
        leftover = sorted(p.name for p in self.signals.glob(f"{self.SLUG}.*"))
        self.assertEqual(leftover, [], f"stale signal files left behind: {leftover}")

    def test_cleanup_is_logged(self):
        self.set_blocked([])
        self.run_task_done()
        self.assertIn("cleanup-complete", (self.signals / "events.log").read_text())


if __name__ == "__main__":
    unittest.main(verbosity=2)
