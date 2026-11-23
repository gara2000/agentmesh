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
#   reply              — text shown under the submitted command (Claude's reply)
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
        *)  printf '%s' "$1" > "$S/new-window.cmd"; shift ;;
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
    if [[ -f "$S/trust-dialog" ]]; then
      if [[ "$(cat "$S/trust-cursor" 2>/dev/null)" == yes ]]; then
        printf ' Quick safety check\n   No, exit\n ❯ Yes, I trust this folder\n'
      else
        printf ' Quick safety check\n ❯ No, exit\n   Yes, I trust this folder\n'
      fi
      exit 0
    fi
    [[ -f "$S/no-prompt" ]] && { echo "Claude Code starting…"; exit 0; }
    typed=$(cat "$S/typed" 2>/dev/null || true)
    enters=$(cat "$S/enters" 2>/dev/null || echo 0)
    needed=$(cat "$S/enters-needed" 2>/dev/null || echo 999)
    if [[ -n "$typed" && "$enters" -ge "$needed" ]]; then
      reply=$(cat "$S/reply" 2>/dev/null || true)
      printf '❯ %s\n%s\n❯%s\n' "$typed" "$reply" "$NBSP"
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
    if [[ -f "$S/trust-dialog" ]]; then
      case "${rest[*]}" in
        Down|Up) echo yes > "$S/trust-cursor" ;;
        Enter)
          if [[ "$(cat "$S/trust-cursor" 2>/dev/null)" == yes ]]; then
            rm -f "$S/trust-dialog"
          else   # "No, exit": claude quits and the window dies with it
            session="${t%%:*}"; : > "$S/windows.$session"; echo exited > "$S/trust-exited"
          fi ;;
      esac
      exit 0
    fi
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

    def run_spawn(self, workdir=None, model=None) -> subprocess.CompletedProcess:
        env = dict(os.environ)
        env["PATH"] = f"{self.stub}{os.pathsep}{env.get('PATH', '')}"
        env["STUB_DIR"] = str(self.stub)
        env.update(SPAWN_SETTLE="0", SPAWN_SUBMIT_SETTLE="0",
                   SPAWN_VERIFY_DELAY="0", SPAWN_SUBMIT_TRIES="5",
                   SPAWN_MODEL_TRIES="3", SPAWN_MODEL_POLL="0")
        if model is not None and workdir is None:
            workdir = Path(self._tmp.name)
        return subprocess.run(
            ["bash", str(self.scripts / "spawn-agent.sh"),
             "workers", self.SLUG, self.SKILL, self.SLUG, "WORK"]
            + ([str(workdir)] if workdir is not None else [])
            + ([model] if model is not None else []),
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


class TestWorkdir(SpawnHarness):
    """The optional 6th argument: the task's `Repo:` directory."""

    def window_command(self) -> str:
        return (self.stub / "new-window.cmd").read_text()

    def cd_target(self) -> str:
        # Evaluate the cd the window would run, without running claude.
        cmd = self.window_command().split(" && exec ", 1)[0]
        return subprocess.run(["bash", "-c", f"{cmd} && pwd -P"],
                              capture_output=True, text=True).stdout.strip()

    def test_defaults_to_the_agentmesh_repo(self):
        r = self.run_spawn()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.cd_target(), str(Path(self._tmp.name).resolve()))

    def test_starts_in_the_given_directory(self):
        repo = Path(self._tmp.name) / "my app's repo"
        repo.mkdir()
        r = self.run_spawn(repo)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.cd_target(), str(repo.resolve()),
                         "spaces and quotes in the path must survive quoting")
        self.assertIn("exec claude", self.window_command())

    def config_path_in_window(self) -> str:
        # What NOTECOVE_CONFIG_PATH the window's claude would see.
        cmd = self.window_command().replace("exec claude", "printenv NOTECOVE_CONFIG_PATH; :", 1)
        env = dict(os.environ)
        env.pop("NOTECOVE_CONFIG_PATH", None)
        return subprocess.run(["bash", "-c", cmd], capture_output=True,
                              text=True, env=env).stdout.strip()

    def test_repo_worker_reads_the_agentmesh_notecove_config(self):
        """
        WORK-2cg: started in its Repo: directory, which holds no .notecove, the
        CLI fell back to ~/.notecove — another profile — and every call failed.
        """
        cfg = Path(self._tmp.name) / ".notecove"
        cfg.write_text("{}")
        repo = Path(self._tmp.name) / "other repo"
        repo.mkdir()
        r = self.run_spawn(repo)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.cd_target(), str(repo.resolve()))
        self.assertEqual(self.config_path_in_window(), str(cfg))

    def test_no_config_written_yet_sets_nothing(self):
        self.assertEqual(self.run_spawn().returncode, 0)
        self.assertNotIn("NOTECOVE_CONFIG_PATH", self.window_command())

    def test_missing_directory_fails_before_any_window(self):
        r = self.run_spawn(Path(self._tmp.name) / "nope")
        self.assertEqual(r.returncode, 1)
        self.assertIn("does not exist", r.stderr)
        self.assertEqual(self.windows(), ["zsh"], "no window may be created")
        self.assertEqual(self.sent(), [])


class TestTrustDialog(SpawnHarness):
    """First start in a new Repo: directory shows the workspace-trust dialog,
    whose default is "No, exit"."""

    def test_trust_dialog_is_accepted_then_the_command_is_typed(self):
        (self.stub / "trust-dialog").touch()
        r = self.run_spawn()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse((self.stub / "trust-exited").exists(),
                         "Enter must never land on 'No, exit'")
        self.assertIn("spawn-trust-accepted", self.events())
        sent = self.sent()
        target = f"workers:{self.SLUG}"
        self.assertEqual(sent[:2], [f"{target}|Down", f"{target}|Enter"])
        self.assertIn(f"{target}|-l {self.SKILL} --task {self.SLUG} --project WORK", sent)

    def test_no_dialog_sends_no_navigation_keys(self):
        self.run_spawn()
        self.assertFalse(any(l.endswith("|Down") for l in self.sent()))
        self.assertNotIn("spawn-trust-accepted", self.events())


class TestModel(SpawnHarness):
    """The optional 7th argument: the resolved model (A1)."""

    def window_command(self) -> str:
        return (self.stub / "new-window.cmd").read_text()

    def test_model_becomes_a_model_flag(self):
        (self.stub / "reply").write_text("⏺ Starting on the task.")
        r = self.run_spawn(model="sonnet")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(self.window_command().endswith(
            "exec claude --dangerously-skip-permissions --model sonnet"))

    def test_no_model_means_no_flag(self):
        self.assertEqual(self.run_spawn().returncode, 0)
        self.assertNotIn("--model", self.window_command())

    def test_empty_model_means_no_flag(self):
        self.assertEqual(self.run_spawn(model="").returncode, 0)
        self.assertNotIn("--model", self.window_command())

    def test_model_value_is_quoted(self):
        (self.stub / "reply").write_text("⏺ ok")
        self.run_spawn(model="odd model; rm -rf x")
        cmd = self.window_command().split(" && ", 1)[1]
        argv = subprocess.run(
            ["bash", "-c", 'f() { printf "%s\\n" "$@"; }; ' + cmd.replace("exec claude", "f"),],
            capture_output=True, text=True).stdout.splitlines()
        self.assertEqual(argv[-2:], ["--model", "odd model; rm -rf x"])

    def test_rejected_model_exits_3_logs_and_frees_the_window(self):
        (self.stub / "reply").write_text(
            "⏺ There's an issue with the selected model (bogus). It may not exist "
            "or you may not have access to it. Run /model to pick a different model.")
        r = self.run_spawn(model="bogus")
        self.assertEqual(r.returncode, 3, r.stderr)
        self.assertIn("spawn-model-rejected:bogus", self.events())
        self.assertNotIn(self.SLUG, self.windows(),
                         "an idle REPL on a bad model must not hold the task")

    def test_no_reply_within_the_window_counts_as_accepted(self):
        r = self.run_spawn(model="opus")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn(self.SLUG, self.windows())
        self.assertNotIn("spawn-model-rejected", self.events())

    def test_rejection_text_is_not_checked_without_a_model(self):
        (self.stub / "reply").write_text("⏺ There's an issue with the selected model (x).")
        self.assertEqual(self.run_spawn().returncode, 0)


if __name__ == "__main__":
    unittest.main()
