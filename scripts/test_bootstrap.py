"""
Unit tests for bootstrap.sh — idempotent, self-repairing start.

`agentmesh start` has to be safe to run against a live system: that is the only
way to bring back a daemon that died, or to introduce a new one, without an
`agentmesh stop` — which destroys every running worker along with it.

bootstrap.sh is driven end-to-end against stub `tmux` and `notecove` binaries on
PATH, inside a throwaway copy of the repo layout.

What is asserted:
  - a cold start (nothing running) wipes the runtime state, as it always did
  - a warm start preserves every per-task file, the registry, and the event log
  - a warm start still creates whatever daemon window is missing, and only that
  - a wedged launcher — window up, heartbeat stale — is replaced
  - a healthy launcher is left strictly alone
"""
import os
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).parent


TMUX_STUB = r"""#!/usr/bin/env bash
# Stub tmux. Window state lives in $STUB/windows.<session>, one name per line.
# Commands that mutate state are also appended to $STUB/calls.log so the tests
# can assert on what bootstrap tried to do, not just on the end state.
set -uo pipefail
STUB="$STUB_DIR"
cmd="$1"; shift
echo "$cmd $*" >> "$STUB/calls.log"
case "$cmd" in
  list-windows)
    session=""
    while [[ $# -gt 0 ]]; do
      case "$1" in -t) session="${2%:}"; shift 2 ;; *) shift ;; esac
    done
    [[ -f "$STUB/windows.$session" ]] || exit 1
    cat "$STUB/windows.$session"
    ;;
  list-panes)
    session=""
    while [[ $# -gt 0 ]]; do
      case "$1" in -t) session="${2%:}"; shift 2 ;; *) shift ;; esac
    done
    [[ -f "$STUB/panes.$session" ]] || exit 1
    cat "$STUB/panes.$session"
    ;;
  has-session)
    session=""
    while [[ $# -gt 0 ]]; do
      case "$1" in -t) session="${2%:}"; shift 2 ;; *) shift ;; esac
    done
    [[ -f "$STUB/windows.$session" ]]
    ;;
  new-session)
    session=""
    while [[ $# -gt 0 ]]; do
      case "$1" in -s) session="$2"; shift 2 ;; *) shift ;; esac
    done
    # Mirrors the real `new-session -d` + `|| true` idiom: fails if it exists.
    [[ -f "$STUB/windows.$session" ]] && exit 1
    : > "$STUB/windows.$session"
    ;;
  new-window)
    session="" name=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -t) session="${2%:}"; shift 2 ;;
        -n) name="$2";       shift 2 ;;
        *)  shift ;;
      esac
    done
    echo "$name" >> "$STUB/windows.$session"
    echo "$session:$name" >> "$STUB/created.log"
    ;;
  kill-window)
    target=""
    while [[ $# -gt 0 ]]; do
      case "$1" in -t) target="$2"; shift 2 ;; *) shift ;; esac
    done
    session="${target%%:*}"
    name="${target#*:}"
    echo "$target" >> "$STUB/killed.log"
    [[ -f "$STUB/windows.$session" ]] || exit 1
    grep -vxF "$name" "$STUB/windows.$session" > "$STUB/windows.$session.tmp" || true
    mv "$STUB/windows.$session.tmp" "$STUB/windows.$session"
    ;;
  *) exit 0 ;;
esac
"""

NOTECOVE_STUB = r"""#!/usr/bin/env bash
# Stub notecove CLI: enough for `init` and the Triage folder lookup.
set -uo pipefail
case "${1:-}" in
  init)   echo "initialized" ;;
  folder) echo '[{"id": "triage-folder-id", "name": "Triage", "parentId": null}]' ;;
  *)      exit 1 ;;
esac
"""


class BootstrapHarness(unittest.TestCase):
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

        shutil.copy(SCRIPTS / "bootstrap.sh", self.scripts / "bootstrap.sh")
        for name, body in (("tmux", TMUX_STUB), ("notecove", NOTECOVE_STUB)):
            p = self.stub / name
            p.write_text(body)
            p.chmod(0o755)

    # -- fixture helpers ---------------------------------------------------

    def set_windows(self, session: str, names: list):
        (self.stub / f"windows.{session}").write_text(
            "".join(f"{n}\n" for n in names))

    def set_panes(self, session: str, commands: list):
        (self.stub / f"panes.{session}").write_text(
            "".join(f"{c}\n" for c in commands))

    def windows(self, session: str) -> list:
        p = self.stub / f"windows.{session}"
        return p.read_text().split() if p.exists() else []

    def created(self) -> list:
        p = self.stub / "created.log"
        return p.read_text().split() if p.exists() else []

    def killed(self) -> list:
        p = self.stub / "killed.log"
        return p.read_text().split() if p.exists() else []

    def set_heartbeat_age(self, secs: int):
        hb = self.signals / "launcher.heartbeat"
        hb.write_text("stamp\n")
        past = time.time() - secs
        os.utime(hb, (past, past))

    def run_bootstrap(self, *extra) -> subprocess.CompletedProcess:
        env = dict(os.environ)
        env["PATH"] = f"{self.stub}{os.pathsep}{env.get('PATH', '')}"
        env["STUB_DIR"] = str(self.stub)
        env["AGENTMESH_NOTECOVE"] = "notecove"
        return subprocess.run(
            ["bash", str(self.scripts / "bootstrap.sh"),
             "--project", "WORK", *extra],
            capture_output=True, text=True, env=env, timeout=120)


class TestColdStart(BootstrapHarness):
    """With nothing running, the destructive reset still happens."""

    def test_cold_start_wipes_runtime_state_and_starts_everything(self):
        (self.signals / "workers").write_text("")
        (self.signals / "events.log").write_text("stale\tline\there\t-\n")
        (self.signals / "WORK-old.inbox").write_text('{"kind":"comment"}\n')
        (self.signals / "WORK-old.terminal-since").touch()
        (self.signals / "WORK-old.ready").touch()
        (self.signals / "WORK-old.pending-delivery").touch()
        (self.signals / "WORK-old.self-state").write_text("Attention")
        self.set_heartbeat_age(10_000)

        r = self.run_bootstrap()

        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("cold start", r.stdout)
        self.assertFalse((self.signals / "WORK-old.inbox").exists())
        self.assertFalse((self.signals / "WORK-old.terminal-since").exists())
        # A surviving .ready would let a sidecar type into a window that no
        # longer holds the worker it was gating on.
        self.assertFalse((self.signals / "WORK-old.ready").exists())
        self.assertFalse((self.signals / "WORK-old.pending-delivery").exists())
        self.assertFalse((self.signals / "WORK-old.self-state").exists())
        self.assertNotIn("stale", (self.signals / "events.log").read_text())
        # The heartbeat is never pre-stamped: it means "a scan completed", and
        # stamping it here makes a launcher that dies on startup look healthy.
        self.assertFalse((self.signals / "launcher.heartbeat").exists())
        for daemon in ("watchdog", "folder-cleanup", "reaper", "launcher"):
            self.assertIn(daemon, self.windows("orchestrator"), daemon)

    def test_a_lone_sidecar_counts_as_live(self):
        # The liveness test deliberately errs towards "live": an empty registry
        # plus a surviving sidecar is treated as a warm start even though no
        # worker window is left. Wrongly skipping the wipe costs a few stale
        # files; wrongly running it kills a sidecar whose worker is blocked on
        # the inbox it is about to delete.
        (self.signals / "workers").write_text("")
        (self.signals / "WORK-old.inbox").write_text('{"kind":"comment"}\n')
        self.set_windows("orchestrator", ["side-WORK-old", "pr-mon-WORK-old"])
        self.set_panes("workers", [])

        r = self.run_bootstrap()

        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("warm start", r.stdout)
        self.assertEqual(self.killed(), [])
        self.assertTrue((self.signals / "WORK-old.inbox").exists())


class TestWarmStart(BootstrapHarness):
    """Against a live system, nothing running may be disturbed."""

    def _live_system(self, orchestrator_windows):
        (self.signals / "workers").write_text(
            "# format: <task-slug> <tmux-window-name> <agent-type>\n"
            "WORK-abc WORK-abc implementer\n")
        (self.signals / "events.log").write_text("history\tline\there\t-\n")
        (self.signals / "WORK-abc.inbox").write_text('{"kind":"comment"}\n')
        (self.signals / "WORK-abc.pending-delivery").touch()
        (self.signals / "WORK-abc.ready").touch()
        (self.signals / "WORK-abc.seen-comments").write_text("abc123\n")
        self.set_windows("orchestrator", orchestrator_windows)
        self.set_windows("workers", ["WORK-abc"])
        self.set_panes("workers", ["claude"])
        self.set_heartbeat_age(5)

    def test_warm_start_with_everything_up_changes_nothing(self):
        self._live_system(["watchdog", "folder-cleanup", "reaper", "launcher",
                           "side-WORK-abc"])

        r = self.run_bootstrap()

        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("warm start", r.stdout)
        self.assertEqual(self.created(), [])
        self.assertEqual(self.killed(), [])
        # The reply waiting for the worker must survive, and so must the two
        # files that get it delivered: .ready is the sidecar's gate, and without
        # .pending-delivery an undelivered nudge is never retried.
        self.assertEqual((self.signals / "WORK-abc.inbox").read_text(),
                         '{"kind":"comment"}\n')
        self.assertTrue((self.signals / "WORK-abc.ready").exists())
        self.assertTrue((self.signals / "WORK-abc.pending-delivery").exists())
        self.assertTrue((self.signals / "WORK-abc.seen-comments").exists())
        self.assertIn("history", (self.signals / "events.log").read_text())
        self.assertIn("WORK-abc WORK-abc implementer",
                      (self.signals / "workers").read_text())

    def test_warm_start_revives_only_the_missing_daemon(self):
        # The case this whole mechanism exists for: add (or lose) one daemon and
        # get it running without taking the workers down with it.
        self._live_system(["watchdog", "folder-cleanup", "launcher",
                           "side-WORK-abc"])

        r = self.run_bootstrap()

        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.created(), ["orchestrator:reaper"])
        self.assertEqual(self.killed(), [])
        self.assertTrue((self.signals / "WORK-abc.inbox").exists())

    def test_warm_start_is_detected_from_live_claude_panes_alone(self):
        # bootstrap.sh truncates signals/workers on a cold start, so a registry
        # emptied by an earlier run must not be the only evidence considered —
        # otherwise the second start of a pair wipes the first one's workers.
        (self.signals / "workers").write_text("")
        (self.signals / "WORK-abc.inbox").write_text('{"kind":"comment"}\n')
        self.set_windows("orchestrator", ["watchdog", "folder-cleanup",
                                          "reaper", "launcher"])
        self.set_windows("workers", ["WORK-abc"])
        self.set_panes("workers", ["claude"])
        self.set_heartbeat_age(5)

        r = self.run_bootstrap()

        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("warm start", r.stdout)
        self.assertTrue((self.signals / "WORK-abc.inbox").exists())

    def test_clean_forces_the_reset_on_a_live_system(self):
        self._live_system(["watchdog", "folder-cleanup", "reaper", "launcher",
                           "side-WORK-abc"])

        r = self.run_bootstrap("--clean")

        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("cold start", r.stdout)
        self.assertFalse((self.signals / "WORK-abc.inbox").exists())
        self.assertIn("orchestrator:side-WORK-abc", self.killed())


class TestLauncherHealth(BootstrapHarness):
    """The launcher's window existing is not proof of life — the heartbeat is."""

    def _up_except_launcher_health(self, heartbeat_age):
        (self.signals / "workers").write_text("WORK-abc WORK-abc implementer\n")
        self.set_windows("orchestrator", ["watchdog", "folder-cleanup",
                                          "reaper", "launcher"])
        self.set_windows("workers", ["WORK-abc"])
        self.set_panes("workers", ["claude"])
        self.set_heartbeat_age(heartbeat_age)

    def test_healthy_launcher_is_left_alone(self):
        self._up_except_launcher_health(5)

        r = self.run_bootstrap()

        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.killed(), [])
        self.assertEqual(self.created(), [])

    def test_wedged_launcher_is_replaced(self):
        # Window up, no scan completed in a long time: restarting it is the only
        # thing that gets tasks picked up again.
        self._up_except_launcher_health(600)

        r = self.run_bootstrap()

        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.killed(), ["orchestrator:launcher"])
        self.assertEqual(self.created(), ["orchestrator:launcher"])
        # Only the launcher — the workers and the other daemons stay up.
        self.assertIn("WORK-abc", self.windows("workers"))
        self.assertIn("watchdog", self.windows("orchestrator"))


if __name__ == "__main__":
    unittest.main()
