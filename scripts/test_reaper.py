"""
Unit tests for reaper.sh — the daemon that kills workers whose tasks are done.

reaper.sh is driven end-to-end with `--once` against stub `tmux` and `notecove`
binaries placed on PATH, inside a throwaway copy of the repo layout. Stubbing at
the process boundary rather than refactoring the script into functions keeps the
tests honest about the thing that actually matters here: which windows get
killed.

What is asserted, in order of how badly each failure would hurt:
  - a non-terminal task is never touched
  - a task reopened during the grace window is never reaped
  - a tmux that cannot be queried skips the pass rather than reaping everything
  - a NoteCove lookup that fails is not read as "terminal"
  - a genuinely terminal task loses its worker, sidecar, pr-monitor and slot
"""
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).parent


TMUX_STUB = r"""#!/usr/bin/env bash
# Stub tmux. Window state lives in $STUB/windows.<session>, one name per line.
set -uo pipefail
STUB="$STUB_DIR"

if [[ -f "$STUB/tmux-fail" ]]; then
  # A tmux that cannot be reached at all: every subcommand fails, and
  # has-session fails too, which is what distinguishes it from "no such session".
  exit 1
fi

cmd="$1"; shift
case "$cmd" in
  list-windows)
    session=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -t) session="$2"; shift 2 ;;
        *)  shift ;;
      esac
    done
    [[ -f "$STUB/windows.$session" ]] || exit 1
    cat "$STUB/windows.$session"
    ;;
  list-sessions)
    # Succeeds while the (stub) server is answering at all — this is what lets
    # reaper.sh tell "no such session" apart from "tmux is down".
    ls "$STUB"/windows.* >/dev/null 2>&1
    ;;
  has-session)
    session=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -t) session="$2"; shift 2 ;;
        *)  shift ;;
      esac
    done
    [[ -f "$STUB/windows.$session" ]]
    ;;
  kill-window)
    target=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -t) target="$2"; shift 2 ;;
        *)  shift ;;
      esac
    done
    session="${target%%:*}"
    name="${target#*:}"
    echo "$target" >> "$STUB/killed.log"
    [[ -f "$STUB/windows.$session" ]] || exit 1
    grep -vxF "$name" "$STUB/windows.$session" > "$STUB/windows.$session.tmp" || true
    mv "$STUB/windows.$session.tmp" "$STUB/windows.$session"
    ;;
  *)
    exit 0
    ;;
esac
"""

NOTECOVE_STUB = r"""#!/usr/bin/env bash
# Stub notecove CLI. Serves $STUB_DIR/task.<slug>.json for `task show <slug>`.
set -uo pipefail
STUB="$STUB_DIR"
if [[ "${1:-}" == "task" && "${2:-}" == "show" ]]; then
  slug="$3"
  [[ -f "$STUB/task.$slug.json" ]] || exit 1
  cat "$STUB/task.$slug.json"
  exit 0
fi
exit 1
"""


class ReaperHarness(unittest.TestCase):
    """A throwaway repo layout with reaper.sh in it and stubs on PATH."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        root = Path(self._tmp.name)

        self.root = root
        self.scripts = root / "scripts"
        self.signals = root / "signals"
        self.stub = root / "stub"
        for d in (self.scripts, self.signals, self.stub):
            d.mkdir()

        shutil.copy(SCRIPTS / "reaper.sh", self.scripts / "reaper.sh")
        (self.scripts / "reaper.sh").chmod(0o755)
        # reaper.sh sources this for nc_run/nc_ref, so the throwaway layout needs
        # it too — the daemon locates it relative to its own path.
        shutil.copy(SCRIPTS / "notecove-ref.sh", self.scripts / "notecove-ref.sh")
        (self.signals / "workers").write_text(
            "# format: <task-slug> <tmux-window-name> <agent-type>\n")
        (self.signals / "events.log").touch()

        self._write_stub("tmux", TMUX_STUB)
        self._write_stub("notecove", NOTECOVE_STUB)

    # -- fixture helpers ---------------------------------------------------

    def _write_stub(self, name: str, body: str):
        p = self.stub / name
        p.write_text(body)
        p.chmod(0o755)

    def set_windows(self, session: str, names: list):
        (self.stub / f"windows.{session}").write_text(
            "".join(f"{n}\n" for n in names))

    def set_task(self, slug: str, *, terminal: bool, state: str = "done"):
        (self.stub / f"task.{slug}.json").write_text(
            '{"slug": {"short": "%s"}, "isTerminal": %s, '
            '"state": {"name": "%s"}}' % (slug, "true" if terminal else "false", state))

    def register(self, slug: str, agent: str = "implementer"):
        with (self.signals / "workers").open("a") as fh:
            fh.write(f"{slug} {slug} {agent}\n")

    def killed(self) -> list:
        p = self.stub / "killed.log"
        return p.read_text().split() if p.exists() else []

    def registry(self) -> list:
        return [ln for ln in (self.signals / "workers").read_text().splitlines()
                if ln and not ln.startswith("#")]

    def events(self) -> str:
        return (self.signals / "events.log").read_text()

    def run_reaper(self, *extra) -> subprocess.CompletedProcess:
        env = dict(os.environ)
        # Stubs first; the rest of PATH is kept so `timeout` and `python3` still
        # resolve — reaper.sh depends on both.
        env["PATH"] = f"{self.stub}{os.pathsep}{env.get('PATH', '')}"
        env["STUB_DIR"] = str(self.stub)
        env["AGENTMESH_NOTECOVE"] = "notecove"
        return subprocess.run(
            ["bash", str(self.scripts / "reaper.sh"), "--once", *extra],
            capture_output=True, text=True, env=env, timeout=120)


class TestReaperLeavesLiveWork(ReaperHarness):
    """Anything short of a confirmed terminal state must be left alone."""

    def test_non_terminal_task_is_untouched(self):
        self.set_windows("workers", ["WORK-abc"])
        self.set_windows("orchestrator", ["watchdog", "reaper", "side-WORK-abc"])
        self.set_task("WORK-abc", terminal=False, state="doing")
        self.register("WORK-abc")

        r = self.run_reaper("--grace", "0")

        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.killed(), [])
        self.assertEqual(self.registry(), ["WORK-abc WORK-abc implementer"])
        self.assertFalse((self.signals / "WORK-abc.terminal-since").exists())

    def test_notecove_failure_is_not_read_as_terminal(self):
        # No task.<slug>.json fixture → the stub exits 1, as a NoteCove outage
        # or a hung CLI would. Reaping on that would kill live workers whenever
        # NoteCove restarts.
        self.set_windows("workers", ["WORK-abc"])
        self.set_windows("orchestrator", ["reaper"])
        self.register("WORK-abc")

        r = self.run_reaper("--grace", "0")

        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.killed(), [])
        self.assertEqual(len(self.registry()), 1)

    def test_tmux_unavailable_skips_the_pass(self):
        # The dangerous failure: treating an unanswerable tmux as "no windows
        # exist" would reap every registered task at once.
        self.set_windows("workers", ["WORK-abc"])
        self.set_windows("orchestrator", ["reaper"])
        self.set_task("WORK-abc", terminal=True)
        self.register("WORK-abc")
        (self.stub / "tmux-fail").touch()

        r = self.run_reaper("--grace", "0")

        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.killed(), [])
        self.assertEqual(len(self.registry()), 1)
        self.assertIn("reap-skipped-tmux-unavailable", self.events())

    def test_booting_worker_is_left_to_the_launcher(self):
        # A live .launching flag means a worker is mid-boot with no window yet.
        self.set_windows("workers", [])
        self.set_windows("orchestrator", ["reaper", "side-WORK-abc"])
        self.set_task("WORK-abc", terminal=True)
        self.register("WORK-abc")
        (self.signals / "WORK-abc.launching").touch()

        r = self.run_reaper("--grace", "0")

        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.killed(), [])


class TestReaperGracePeriod(ReaperHarness):
    """The first terminal sighting defers; only a later pass reaps."""

    def test_first_sighting_defers_and_records(self):
        self.set_windows("workers", ["WORK-abc"])
        self.set_windows("orchestrator", ["reaper", "side-WORK-abc"])
        self.set_task("WORK-abc", terminal=True)
        self.register("WORK-abc")

        r = self.run_reaper("--grace", "60")

        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.killed(), [])
        self.assertTrue((self.signals / "WORK-abc.terminal-since").exists())
        self.assertIn("reap-deferred-grace", self.events())

    def test_still_inside_grace_does_not_reap(self):
        self.set_windows("workers", ["WORK-abc"])
        self.set_windows("orchestrator", ["reaper", "side-WORK-abc"])
        self.set_task("WORK-abc", terminal=True)
        self.register("WORK-abc")
        (self.signals / "WORK-abc.terminal-since").touch()

        r = self.run_reaper("--grace", "3600")

        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.killed(), [])
        self.assertTrue((self.signals / "WORK-abc.terminal-since").exists())

    def test_reopened_during_grace_stands_down(self):
        # The case the grace period exists for: the user closes a task, changes
        # their mind, and reopens it before the reaper acts.
        self.set_windows("workers", ["WORK-abc"])
        self.set_windows("orchestrator", ["reaper", "side-WORK-abc"])
        self.set_task("WORK-abc", terminal=False, state="doing")
        self.register("WORK-abc")
        (self.signals / "WORK-abc.terminal-since").touch()

        r = self.run_reaper("--grace", "0")

        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.killed(), [])
        self.assertFalse((self.signals / "WORK-abc.terminal-since").exists())
        self.assertIn("reap-cancelled-reopened", self.events())

    def test_dry_run_reports_without_killing(self):
        self.set_windows("workers", ["WORK-abc"])
        self.set_windows("orchestrator", ["reaper", "side-WORK-abc"])
        self.set_task("WORK-abc", terminal=True)
        self.register("WORK-abc")
        (self.signals / "WORK-abc.terminal-since").touch()

        r = self.run_reaper("--grace", "0", "--dry-run")

        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.killed(), [])
        self.assertEqual(len(self.registry()), 1)
        self.assertIn("reap-dry-run", self.events())


class TestReaperReaps(ReaperHarness):
    """Past the grace period, everything belonging to the task goes."""

    def test_terminal_task_loses_worker_sidecar_and_monitor(self):
        self.set_windows("workers", ["WORK-abc", "WORK-other"])
        self.set_windows("orchestrator",
                         ["watchdog", "reaper", "side-WORK-abc",
                          "pr-mon-WORK-abc", "side-WORK-other"])
        self.set_task("WORK-abc", terminal=True, state="done")
        self.set_task("WORK-other", terminal=False, state="doing")
        self.register("WORK-abc")
        self.register("WORK-other", "investigator")
        (self.signals / "WORK-abc.terminal-since").touch()
        (self.signals / "WORK-abc.inbox").write_text('{"kind":"comment"}\n')
        (self.signals / "WORK-abc.ready").touch()
        (self.signals / "WORK-abc.pending-delivery").touch()
        (self.signals / "WORK-abc.self-state").write_text("Done")

        r = self.run_reaper("--grace", "0")

        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertCountEqual(
            self.killed(),
            ["workers:WORK-abc", "orchestrator:side-WORK-abc",
             "orchestrator:pr-mon-WORK-abc"])
        # The slot is freed here rather than one watchdog poll later.
        self.assertEqual(self.registry(), ["WORK-other WORK-other investigator"])
        # .ready in particular: leaving it behind would let a sidecar for a task
        # reopened under the same slug type into the REPL before the new worker
        # has reached its skill.
        for suffix in ("inbox", "ready", "pending-delivery", "self-state",
                       "terminal-since"):
            self.assertFalse((self.signals / f"WORK-abc.{suffix}").exists(), suffix)
        self.assertIn("worker-reaped", self.events())

    def test_sidecar_outliving_a_dead_worker_is_still_reaped(self):
        # The worker window is already gone — crashed, or killed by hand. Nothing
        # else would ever collect its sidecar or its registry line, so the
        # candidate set has to include side-/pr-mon- windows and the registry,
        # not just live worker windows.
        self.set_windows("workers", [])
        self.set_windows("orchestrator", ["reaper", "side-WORK-abc"])
        self.set_task("WORK-abc", terminal=True, state="won't do")
        self.register("WORK-abc")
        (self.signals / "WORK-abc.terminal-since").touch()

        r = self.run_reaper("--grace", "0")

        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("orchestrator:side-WORK-abc", self.killed())
        self.assertEqual(self.registry(), [])

    def test_duplicate_window_names_are_all_killed(self):
        # tmux kill-window removes only the first match; a survivor would keep
        # the slug's window "live" and make the task un-pickupable forever.
        self.set_windows("workers", ["WORK-abc", "WORK-abc"])
        self.set_windows("orchestrator", ["reaper"])
        self.set_task("WORK-abc", terminal=True)
        self.register("WORK-abc")
        (self.signals / "WORK-abc.terminal-since").touch()

        r = self.run_reaper("--grace", "0")

        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(
            (self.stub / "windows.workers").read_text().strip(), "")

    def test_no_candidates_is_a_quiet_no_op(self):
        self.set_windows("workers", [])
        self.set_windows("orchestrator", ["watchdog", "reaper"])

        r = self.run_reaper("--grace", "0")

        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.killed(), [])
        self.assertNotIn("worker-reaped", self.events())


if __name__ == "__main__":
    unittest.main()
