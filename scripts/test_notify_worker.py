"""
Unit tests for notify-worker.sh — sidecar/pr-monitor → worker message delivery.

Delivery replaced `tmux wait-for -S <slug>-nudge-<seq>`, which could only reach a
worker already blocked inside `tmux wait-for`. Typing into the worker's Claude
REPL reaches it whether it is idle or mid-turn, but it introduces failure modes a
fire-and-forget signal did not have — the window may be gone, the REPL may still
be booting, tmux may not answer at all — so the retry sentinel is what keeps a
change from being silently dropped.

notify-worker.sh is driven through a stub `tmux` on PATH. Stubbing at the process
boundary keeps the tests honest about the thing that matters: what actually gets
typed, and into which window.

What is asserted, in order of how badly each failure would hurt:
  - a change is never dropped: a delivery that cannot go through stays pending
  - nothing is typed into a window that is not there, or into a REPL that has not
    reached its skill yet (the .ready gate)
  - a tmux that cannot be queried fails closed rather than typing blind
  - a successful delivery types the text literally, then submits it
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
# Every send-keys invocation is appended to $STUB/sent.log as "<target>|<args>".
set -uo pipefail
STUB="$STUB_DIR"

if [[ -f "$STUB/tmux-fail" ]]; then
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
  send-keys)
    target=""; rest=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -t) target="$2"; shift 2 ;;
        *)  rest+=("$1"); shift ;;
      esac
    done
    if [[ -f "$STUB/send-fail" ]]; then
      echo "$target|FAILED ${rest[*]:-}" >> "$STUB/sent.log"
      exit 1
    fi
    echo "$target|${rest[*]:-}" >> "$STUB/sent.log"
    ;;
  *)
    exit 0
    ;;
esac
"""


class NotifyHarness(unittest.TestCase):
    """A throwaway repo layout with notify-worker.sh in it and tmux stubbed."""

    SLUG = "WORK-abc"

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

        shutil.copy(SCRIPTS / "notify-worker.sh", self.scripts / "notify-worker.sh")
        (self.scripts / "notify-worker.sh").chmod(0o755)
        (self.signals / "events.log").touch()

        p = self.stub / "tmux"
        p.write_text(TMUX_STUB)
        p.chmod(0o755)

        # The happy path, which individual tests then break in one way each.
        self.set_windows("workers", [self.SLUG])
        self.set_ready(True)

    # -- fixture helpers ---------------------------------------------------

    def set_windows(self, session: str, names: list):
        (self.stub / f"windows.{session}").write_text(
            "".join(f"{n}\n" for n in names))

    def set_ready(self, ready: bool):
        f = self.signals / f"{self.SLUG}.ready"
        if ready:
            f.touch()
        elif f.exists():
            f.unlink()

    def sent(self) -> list:
        p = self.stub / "sent.log"
        return p.read_text().splitlines() if p.exists() else []

    def pending(self) -> bool:
        return (self.signals / f"{self.SLUG}.pending-delivery").exists()

    def events(self) -> str:
        return (self.signals / "events.log").read_text()

    def run_fn(self, call: str) -> subprocess.CompletedProcess:
        """Source notify-worker.sh and run one of its functions."""
        env = dict(os.environ)
        env["PATH"] = f"{self.stub}{os.pathsep}{env.get('PATH', '')}"
        env["STUB_DIR"] = str(self.stub)
        env["NUDGE_SETTLE"] = "0"  # no need to wait out the real settle in tests
        script = (
            f'source "{self.scripts}/notify-worker.sh"\n'
            f'{call}\n'
        )
        return subprocess.run(
            ["bash", "-c", script],
            capture_output=True, text=True, env=env, timeout=60,
            cwd=str(self.root),
        )


class TestNothingIsDropped(NotifyHarness):
    """The sentinel is the only thing standing between a failed send and a lost
    change: the sidecar's diff has already absorbed the change into its baseline
    by the time delivery is attempted, so it will never be reported again."""

    def test_failed_delivery_stays_pending(self):
        self.set_ready(False)
        self.run_fn(f'notify_worker "{self.SLUG}"')
        self.assertTrue(self.pending(),
                        "a delivery that could not go through must stay pending")

    def test_successful_delivery_clears_pending(self):
        self.run_fn(f'notify_worker "{self.SLUG}"')
        self.assertFalse(self.pending())

    def test_retry_delivers_once_the_worker_is_ready(self):
        self.set_ready(False)
        self.run_fn(f'notify_worker "{self.SLUG}"')
        self.assertTrue(self.pending())
        self.set_ready(True)
        self.run_fn(f'retry_pending_nudge "{self.SLUG}"')
        self.assertFalse(self.pending())
        self.assertTrue(self.sent(), "the retry should have typed the message")

    def test_retry_is_a_noop_with_nothing_pending(self):
        self.run_fn(f'retry_pending_nudge "{self.SLUG}"')
        self.assertEqual(self.sent(), [])


class TestDeliveryGate(NotifyHarness):
    """Typing into the wrong place is worse than not typing at all."""

    def test_no_delivery_without_a_worker_window(self):
        self.set_windows("workers", ["WORK-other"])
        r = self.run_fn(f'deliver_nudge "{self.SLUG}"')
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.sent(), [])
        self.assertIn("delivery-deferred-not-ready", self.events())

    def test_no_delivery_before_the_skill_is_running(self):
        # spawn-agent.sh send-keys the skill invocation into the REPL once the
        # prompt appears. A nudge arriving in that window would be typed into
        # the middle of that command line. .ready is what closes the gap.
        self.set_ready(False)
        r = self.run_fn(f'deliver_nudge "{self.SLUG}"')
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.sent(), [])

    def test_unqueryable_tmux_fails_closed(self):
        (self.stub / "tmux-fail").touch()
        r = self.run_fn(f'deliver_nudge "{self.SLUG}"')
        self.assertNotEqual(r.returncode, 0, "no answer from tmux is not 'the window is there'")
        self.assertEqual(self.sent(), [])

    def test_send_failure_is_not_reported_as_delivered(self):
        (self.stub / "send-fail").touch()
        self.run_fn(f'notify_worker "{self.SLUG}"')
        self.assertTrue(self.pending())
        self.assertIn("delivery-failed-send", self.events())


class TestWhatGetsTyped(NotifyHarness):
    """The message has to arrive as one submitted line in the right window."""

    def test_message_is_typed_literally_then_submitted(self):
        r = self.run_fn(f'deliver_nudge "{self.SLUG}"')
        self.assertEqual(r.returncode, 0, r.stderr)
        sent = self.sent()
        self.assertEqual(len(sent), 2, f"expected text then Enter, got {sent}")

        target, args = sent[0].split("|", 1)
        self.assertEqual(target, f"workers:{self.SLUG}")
        # -l keeps tmux from reading any character of the text as a key name.
        self.assertTrue(args.startswith("-l "), f"text must be sent literally: {args}")
        self.assertIn(self.SLUG, args)

        target, args = sent[1].split("|", 1)
        self.assertEqual(target, f"workers:{self.SLUG}")
        self.assertEqual(args, "Enter")

    def test_message_is_a_single_line(self):
        # A newline anywhere in the text would submit it halfway through.
        r = self.run_fn(f'nudge_message "{self.SLUG}"')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("\n", r.stdout)
        self.assertIn(self.SLUG, r.stdout)

    def test_delivery_is_logged(self):
        self.run_fn(f'deliver_nudge "{self.SLUG}"')
        self.assertIn("nudge-delivered", self.events())


if __name__ == "__main__":
    unittest.main(verbosity=2)
