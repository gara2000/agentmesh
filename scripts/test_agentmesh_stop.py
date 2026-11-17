"""
Unit tests for `agentmesh stop` levels and `agentmesh clean`.

Each level is cumulative and has to leave the system in a state the next
`agentmesh start` can repair without losing a reply:

  1  daemons only — workers, sidecars and pr-monitors keep running
  2  + sidecars and pr-monitors — workers stay; every baseline is kept
  3  + workers — the registry and per-process flags go, so the next start does
     not read the stop as a crash of every worker; inboxes and baselines stay
  4  + every signal file except the description backups

agentmesh.sh is driven against the stub tmux from test_bootstrap.py, inside a
throwaway copy of the repo layout. Tests run without a terminal, so they also
cover the refusal to pick a level, or confirm level 4, on nobody's behalf.
"""
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from test_bootstrap import TMUX_STUB

SCRIPTS = Path(__file__).parent

DAEMONS = ["watchdog", "folder-cleanup", "reaper", "launcher"]


class StopHarness(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        root = Path(self._tmp.name)
        self.scripts = root / "scripts"
        self.signals = root / "signals"
        self.stub = root / "stub"
        for d in (self.scripts, self.signals, self.stub):
            d.mkdir()
        shutil.copy(SCRIPTS / "agentmesh.sh", self.scripts / "agentmesh.sh")
        tmux = self.stub / "tmux"
        tmux.write_text(TMUX_STUB)
        tmux.chmod(0o755)
        self._running_system()

    def _running_system(self):
        (self.stub / "windows.orchestrator").write_text("".join(
            f"{w}\n" for w in [*DAEMONS, "side-WORK-abc", "pr-mon-WORK-abc"]))
        (self.stub / "windows.workers").write_text("zsh\nWORK-abc\n")
        (self.signals / "workers").write_text(
            "# format: <task-slug> <tmux-window-name> <agent-type>\n"
            "WORK-abc WORK-abc implementer\n")
        (self.signals / "launcher.heartbeat").write_text("stamp\n")
        (self.signals / "events.log").write_text("history\n")
        for suffix, body in ((".inbox", '{"kind":"comment"}\n'),
                             (".seen-comments", "c1\n"),
                             (".seen-state", "attention\n"),
                             (".prs", "https://github.com/o/r/pull/1\n"),
                             (".pr-seen-comments", "1\n"),
                             (".full-slug", "WORK-abc:long\n"),
                             (".crash-count", "1"),
                             (".description-backup", "the old description"),
                             (".ready", ""), (".pending-delivery", ""),
                             (".launching", ""), (".backoff", "")):
            (self.signals / f"WORK-abc{suffix}").write_text(body)

    def run_cli(self, *args) -> subprocess.CompletedProcess:
        env = dict(os.environ)
        env["PATH"] = f"{self.stub}{os.pathsep}{env.get('PATH', '')}"
        env["STUB_DIR"] = str(self.stub)
        return subprocess.run(
            ["bash", str(self.scripts / "agentmesh.sh"), *args],
            capture_output=True, text=True, env=env, timeout=60,
            stdin=subprocess.DEVNULL)

    def windows(self, session):
        p = self.stub / f"windows.{session}"
        return p.read_text().split() if p.exists() else None

    def exists(self, name):
        return (self.signals / name).exists()


class TestLevels(StopHarness):
    def test_level_1_stops_only_the_daemons(self):
        r = self.run_cli("stop", "--level", "1")

        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.windows("orchestrator"),
                         ["side-WORK-abc", "pr-mon-WORK-abc"])
        self.assertEqual(self.windows("workers"), ["zsh", "WORK-abc"])
        self.assertFalse(self.exists("launcher.heartbeat"))
        self.assertIn("WORK-abc WORK-abc", (self.signals / "workers").read_text())
        self.assertTrue(self.exists("WORK-abc.ready"))

    def test_level_2_also_stops_sidecars_and_pr_monitors_but_keeps_baselines(self):
        r = self.run_cli("stop", "--level", "2")

        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.windows("orchestrator"), [])
        self.assertEqual(self.windows("workers"), ["zsh", "WORK-abc"])
        # The replacement sidecar diffs against these, so a reply that arrives
        # while it is down is still reported rather than absorbed as history.
        for f in ("WORK-abc.seen-comments", "WORK-abc.seen-state",
                  "WORK-abc.pr-seen-comments", "WORK-abc.prs", "WORK-abc.ready"):
            self.assertTrue(self.exists(f), f)

    def test_level_3_stops_workers_and_reads_as_a_stop_not_a_crash(self):
        r = self.run_cli("stop", "--level", "3")

        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIsNone(self.windows("workers"))
        # An entry whose window is gone is what the watchdog reads as a crash.
        registry = (self.signals / "workers").read_text()
        self.assertNotIn("WORK-abc WORK-abc", registry)
        self.assertIn("# format", registry)
        for f in ("WORK-abc.ready", "WORK-abc.pending-delivery",
                  "WORK-abc.launching", "WORK-abc.backoff"):
            self.assertFalse(self.exists(f), f)
        # Adoption resumes the task from these, pending reply included.
        for f in ("WORK-abc.inbox", "WORK-abc.seen-comments", "WORK-abc.prs",
                  "WORK-abc.full-slug", "events.log"):
            self.assertTrue(self.exists(f), f)

    def test_level_4_clears_everything_but_description_backups(self):
        r = self.run_cli("stop", "--level", "4", "--yes")

        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(sorted(p.name for p in self.signals.iterdir()),
                         ["WORK-abc.description-backup"])
        self.assertEqual(self.windows("orchestrator"), [])
        self.assertIsNone(self.windows("workers"))

    def test_clean_is_level_4(self):
        r = self.run_cli("clean", "--yes")

        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(sorted(p.name for p in self.signals.iterdir()),
                         ["WORK-abc.description-backup"])


class TestNoGuessing(StopHarness):
    def _untouched(self):
        self.assertEqual(len(self.windows("orchestrator")), 6)
        self.assertEqual(self.windows("workers"), ["zsh", "WORK-abc"])
        self.assertTrue(self.exists("WORK-abc.inbox"))

    def test_no_level_without_a_terminal_is_refused(self):
        r = self.run_cli("stop")

        self.assertNotEqual(r.returncode, 0)
        self.assertIn("--level", r.stderr)
        self._untouched()

    def test_level_4_without_a_terminal_needs_yes(self):
        r = self.run_cli("stop", "--level", "4")

        self.assertNotEqual(r.returncode, 0)
        self.assertIn("--yes", r.stderr)
        self._untouched()

    def test_clean_without_yes_is_refused(self):
        r = self.run_cli("clean")

        self.assertNotEqual(r.returncode, 0)
        self._untouched()

    def test_an_unknown_level_is_refused(self):
        r = self.run_cli("stop", "--level", "5")

        self.assertNotEqual(r.returncode, 0)
        self._untouched()


class TestStartRefusesClean(StopHarness):
    def test_start_clean_points_at_agentmesh_clean(self):
        r = self.run_cli("start", "--project", "WORK", "--clean")

        self.assertNotEqual(r.returncode, 0)
        self.assertIn("agentmesh clean", r.stderr)
        self.assertTrue(self.exists("WORK-abc.inbox"))


if __name__ == "__main__":
    unittest.main()
