"""
Unit tests for spawn-agent.sh — typing the skill invocation into a new worker.

The first prompt to a freshly spawned Claude REPL was occasionally left sitting in
the input box as an unsent draft. The command and Enter went out in a single
send-keys, which Claude Code can read as a paste (the Enter is inserted, not
acted on), and nothing checked whether the submit took. A task stranded that way
stayed in Ready behind a .launching flag, with a live window that adoption would
never repair.

spawn-agent.sh is driven through a stub `tmux` on PATH that models the one piece
of REPL behaviour that matters: the input line. It shows the typed text after the
prompt (❯ + NBSP) until enough Enters have arrived, then echoes the command into
the history with a plain space and leaves an empty prompt.

What is asserted, in order of how badly each failure would hurt:
  - a draft that never submits is not reported as a running worker
  - a swallowed Enter is retried until the draft clears
  - the command is typed literally and submitted by a separate Enter
  - a window that dies before the prompt is still a failure
"""
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).parent

TMUX_STUB = r"""#!/usr/bin/env bash
# Stub tmux. State lives in $STUB_DIR:
#   windows.<session>  — one window name per line
#   typed              — text typed into the input line so far
#   enters             — Enters received since the text was typed
#   enters-needed      — Enters it takes to submit (absent = never submits)
#   no-prompt          — the REPL never draws its prompt
#   die-on-enter       — the window vanishes on the first Enter
# Every send-keys is appended to sent.log as "<target>|<args>".
set -uo pipefail
S="$STUB_DIR"
NBSP=$'\xc2\xa0'

target_of() {
  while [[ $# -gt 0 ]]; do
    case "$1" in -t) echo "$2"; return ;; *) shift ;; esac
  done
}

cmd="$1"; shift
case "$cmd" in
  list-windows)
    session=$(target_of "$@"); session="${session%:}"
    [[ -f "$S/windows.$session" ]] || exit 1
    cat "$S/windows.$session"
    ;;
  new-window)
    name=""; session=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -t) session="${2%%:*}"; shift 2 ;;
        -n) name="$2"; shift 2 ;;
        *)  shift ;;
      esac
    done
    echo "$name" >> "$S/windows.$session"
    ;;
  kill-window)
    t=$(target_of "$@"); session="${t%%:*}"; name="${t#*:}"
    grep -vxF "$name" "$S/windows.$session" > "$S/w.tmp" || true
    mv "$S/w.tmp" "$S/windows.$session"
    echo "$t|KILLED" >> "$S/sent.log"
    ;;
  capture-pane)
    [[ -f "$S/no-prompt" ]] && { echo "Claude Code starting…"; exit 0; }
    typed=$(cat "$S/typed" 2>/dev/null || true)
    enters=$(cat "$S/enters" 2>/dev/null || echo 0)
    needed=$(cat "$S/enters-needed" 2>/dev/null || echo 999)
    if [[ -n "$typed" && "$enters" -ge "$needed" ]]; then
      printf '❯ %s\n\n❯%s\n' "$typed" "$NBSP"
    else
      printf '❯%s%s\n' "$NBSP" "$typed"
    fi
    ;;
  send-keys)
    t=$(target_of "$@"); rest=()
    while [[ $# -gt 0 ]]; do
      case "$1" in -t) shift 2 ;; *) rest+=("$1"); shift ;; esac
    done
    echo "$t|${rest[*]}" >> "$S/sent.log"
    if [[ "${rest[0]}" == "-l" ]]; then
      printf '%s' "${rest[1]}" > "$S/typed"
      echo 0 > "$S/enters"
    elif [[ "${rest[*]}" == *Enter* ]]; then
      if [[ -f "$S/die-on-enter" ]]; then
        session="${t%%:*}"; : > "$S/windows.$session"
      fi
      echo $(( $(cat "$S/enters" 2>/dev/null || echo 0) + 1 )) > "$S/enters"
    fi
    ;;
  *) exit 0 ;;
esac
"""


class SpawnHarness(unittest.TestCase):
    SLUG = "WORK-abc"
    SKILL = "/implementer"

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        root = Path(self._tmp.name)
        self.scripts = root / "scripts"
        self.signals = root / "signals"
        self.stub = root / "stub"
        for d in (self.scripts, self.signals, self.stub):
            d.mkdir()
        shutil.copy(SCRIPTS / "spawn-agent.sh", self.scripts / "spawn-agent.sh")
        (self.signals / "events.log").touch()
        p = self.stub / "tmux"
        p.write_text(TMUX_STUB)
        p.chmod(0o755)
        (self.stub / "windows.workers").write_text("zsh\n")
        self.enters_needed(1)

    def enters_needed(self, n):
        f = self.stub / "enters-needed"
        if n is None:
            f.unlink(missing_ok=True)
        else:
            f.write_text(str(n))

    def run_spawn(self) -> subprocess.CompletedProcess:
        env = dict(os.environ)
        env["PATH"] = f"{self.stub}{os.pathsep}{env.get('PATH', '')}"
        env["STUB_DIR"] = str(self.stub)
        env.update(SPAWN_SETTLE="0", SPAWN_SUBMIT_SETTLE="0",
                   SPAWN_VERIFY_DELAY="0", SPAWN_SUBMIT_TRIES="5")
        return subprocess.run(
            ["bash", str(self.scripts / "spawn-agent.sh"),
             "workers", self.SLUG, self.SKILL, self.SLUG, "WORK"],
            capture_output=True, text=True, env=env, timeout=90)

    def sent(self) -> list:
        p = self.stub / "sent.log"
        return p.read_text().splitlines() if p.exists() else []

    def enters(self) -> int:
        return sum(1 for line in self.sent() if line.endswith("|Enter"))

    def windows(self) -> list:
        return (self.stub / "windows.workers").read_text().split()

    def events(self) -> str:
        return (self.signals / "events.log").read_text()


class TestSubmission(SpawnHarness):

    def test_command_typed_literally_then_submitted_separately(self):
        r = self.run_spawn()
        self.assertEqual(r.returncode, 0, r.stderr)
        sent = self.sent()
        target = f"workers:{self.SLUG}"
        self.assertEqual(
            sent[0], f"{target}|-l {self.SKILL} --task {self.SLUG} --project WORK",
            "the command must be typed literally, with no Enter attached")
        self.assertEqual(sent[1], f"{target}|Enter")
        self.assertIn("spawn-submitted", self.events())

    def test_single_enter_when_the_first_one_takes(self):
        self.run_spawn()
        self.assertEqual(self.enters(), 1)
        self.assertNotIn("spawn-submit-retried", self.events())

    def test_swallowed_enter_is_retried_until_the_draft_clears(self):
        self.enters_needed(3)
        r = self.run_spawn()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.enters(), 3)
        self.assertIn("spawn-submit-retried:3", self.events())
        self.assertIn(self.SLUG, self.windows(), "a submitted worker is left running")


class TestUnsubmittedDraft(SpawnHarness):
    """The original bug: a live window holding an unsent prompt."""

    def test_never_submitted_draft_fails_and_frees_the_window(self):
        self.enters_needed(None)
        r = self.run_spawn()
        self.assertNotEqual(r.returncode, 0,
                            "an unsent draft must not be reported as a running worker")
        self.assertEqual(self.enters(), 5, "every allowed retry should be spent")
        self.assertIn("spawn-submit-unconfirmed", self.events())
        self.assertNotIn(self.SLUG, self.windows(),
                         "the window must be killed so the launcher can retry the task")

    def test_window_dying_after_enter_is_a_failure(self):
        (self.stub / "die-on-enter").touch()
        r = self.run_spawn()
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("died after", r.stderr)


class TestPromptWait(SpawnHarness):

    def test_window_dying_before_prompt_fails_without_typing(self):
        (self.stub / "no-prompt").touch()
        # Make the window vanish immediately by having new-window target a
        # different session file than list-windows reads.
        stub = (self.stub / "tmux").read_text().replace(
            'echo "$name" >> "$S/windows.$session"', ':')
        (self.stub / "tmux").write_text(stub)
        r = self.run_spawn()
        self.assertEqual(r.returncode, 1)
        self.assertIn("died before the REPL appeared", r.stderr)
        self.assertEqual(self.sent(), [], "nothing may be typed into a dead window")

    def test_refuses_duplicate_window(self):
        (self.stub / "windows.workers").write_text(f"{self.SLUG}\n")
        r = self.run_spawn()
        self.assertEqual(r.returncode, 1)
        self.assertIn("already exists", r.stderr)
        self.assertEqual(self.sent(), [])


if __name__ == "__main__":
    unittest.main()
