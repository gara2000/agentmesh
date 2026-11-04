"""
Unit tests for agent-notecove.sh — the agent's summary and state-change helpers.

The rule "always post a summary before handing the task back" lived only in the
skills, and nothing enforced it. Two ways it broke in practice:

  - the agent simply did not call post_summary, and request_attention set
    Attention anyway — the user gets a task demanding their input with nothing
    said about what is wanted, which is indistinguishable from a wedged agent;
  - the agent *did* call it, but NoteCove rejects a body over ~996 characters
    with rc=1 and no output at all, and post_summary never checked the result.
    Same outcome, with the agent believing it had communicated.

So the guarantee is now in the helper: post_summary verifies, truncates rather
than drops, and request_attention/finish_task post a fallback if this turn
produced nothing. `resume_work` clears the marker, which is what scopes the
guarantee to "once per working turn" rather than "once ever".

Everything is driven through a stub CLI on PATH, so the assertions are about
what actually reaches NoteCove.
"""
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).parent

# Stub NoteCove CLI. Logs every comment body to comments.log, every state change
# to states.log, and fails any comment longer than LIMIT to model the real CLI.
NOTECOVE_STUB = r"""#!/usr/bin/env bash
set -uo pipefail
STUB="$STUB_DIR"
LIMIT="${COMMENT_LIMIT:-996}"

if [ -f "$STUB/fail-comments" ] && [ "$2" = "comments" ]; then
  exit 1
fi

case "$1 ${2:-}" in
  "task comments")
    # task comments add <ref> --user <who> <body>
    ref="$4"; body="${!#}"
    if [ "${#body}" -gt "$LIMIT" ]; then
      exit 1          # the real CLI: rc=1, no output whatsoever
    fi
    printf '%s\n' "$ref|$body" >> "$STUB/comments.log"
    ;;
  "task change")
    ref="$3"
    state=""
    while [ $# -gt 0 ]; do
      case "$1" in --state) state="$2"; shift 2 ;; *) shift ;; esac
    done
    printf '%s\n' "$ref|$state" >> "$STUB/states.log"
    ;;
  "task list")
    cat "$STUB/task-list.json" 2>/dev/null
    ;;
  "task show")
    cat "$STUB/show.json" 2>/dev/null
    ;;
esac
exit 0
"""

TASK_DONE_STUB = "#!/usr/bin/env bash\necho \"$*\" >> \"$STUB_DIR/task-done.log\"\n"


class AgentHarness(unittest.TestCase):
    SLUG = "WORK-abc"
    FULL = "WORK-abc:longid"

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)

        # agent-notecove.sh hardcodes ~/agentmesh/..., so HOME is the fake repo's
        # parent and the scripts are copied in beside it.
        self.home = self.root / "home"
        self.mesh = self.home / "agentmesh"
        self.signals = self.mesh / "signals"
        self.scripts = self.mesh / "scripts"
        self.stub_dir = self.root / "stub"
        for d in (self.signals, self.scripts, self.stub_dir):
            d.mkdir(parents=True, exist_ok=True)

        for name in ("agent-notecove.sh", "notecove-ref.sh"):
            (self.scripts / name).write_text((SCRIPTS / name).read_text())

        # task-done.sh is stubbed: finish_task calls it, and the real one talks
        # to NoteCove and kills tmux windows.
        td = self.scripts / "task-done.sh"
        td.write_text(TASK_DONE_STUB)
        td.chmod(0o755)

        self.cli = self.root / "nc-stub"
        self.cli.write_text(NOTECOVE_STUB)
        self.cli.chmod(0o755)

        (self.signals / "events.log").touch()
        (self.signals / f"{self.SLUG}.full-slug").write_text(self.FULL)
        # resume_work reads the task before it writes, so every harness starts
        # from an ordinary non-terminal state. Tests that care overwrite it.
        self.set_task_state("attention", "Attention", terminal=False)

    def set_task_state(self, state_id: str, name: str, terminal: bool):
        (self.stub_dir / "show.json").write_text(json.dumps({
            "id": "longid", "stateId": state_id, "stateName": name,
            "isTerminal": terminal,
            "state": {"id": state_id, "name": name, "isTerminal": terminal},
        }))

    def run_snippet(self, snippet: str, comment_limit: int = 996,
                    init: bool = True, shell: str = "bash",
                    notecove_bin: str = None) -> subprocess.CompletedProcess:
        lines = [
            f'export SIGNALS="{self.signals}"',
            f'export NOTECOVE_BIN="{notecove_bin or self.cli}"',
            f'source "{self.scripts / "agent-notecove.sh"}"',
        ]
        if init:
            lines.append(f'agent_init "{self.SLUG}" "Implementer"')
        lines.append(snippet)
        env = dict(
            os.environ,
            STUB_DIR=str(self.stub_dir),
            HOME=str(self.home),
            COMMENT_LIMIT=str(comment_limit),
        )
        return subprocess.run(
            [shell, "-c", "\n".join(lines)], capture_output=True, text=True, env=env
        )

    def comments(self) -> list:
        f = self.stub_dir / "comments.log"
        return f.read_text().splitlines() if f.exists() else []

    def bodies(self) -> list:
        return [line.split("|", 1)[1] for line in self.comments()]

    def states(self) -> list:
        f = self.stub_dir / "states.log"
        return f.read_text().splitlines() if f.exists() else []


class TestTaskRef(AgentHarness):
    def test_agent_init_exports_the_full_slug(self):
        r = self.run_snippet('printf "[%s]" "$TASK_REF"')
        self.assertEqual(r.stdout, f"[{self.FULL}]")

    def test_comments_are_addressed_by_the_full_slug(self):
        self.run_snippet('post_summary "hello"')
        self.assertEqual(self.comments(), [f"{self.FULL}|hello"])

    def test_state_changes_are_addressed_by_the_full_slug(self):
        self.run_snippet('resume_work')
        self.assertEqual(self.states(), [f"{self.FULL}|Doing"])

    def test_helpers_resolve_the_ref_when_agent_init_was_skipped(self):
        """
        A helper can be called from a fresh Bash invocation that sourced the file
        but never ran agent_init. Falling back to the bare short slug there would
        re-introduce exactly the ambiguity this change removes.
        """
        r = self.run_snippet(
            f'SLUG="{self.SLUG}"; AGENT_HANDLE="Implementer"; post_summary "x"',
            init=False,
        )
        self.assertEqual(r.returncode, 0)
        self.assertEqual(self.comments(), [f"{self.FULL}|x"])


class TestResumeWorkGuard(AgentHarness):
    """
    The nudge and every skill run resume_work before read_inbox. When the change
    being delivered is the user closing the task, an unguarded resume_work set
    Doing over the user's Done before the agent ever saw the state change — the
    agent then had to notice and put it back itself (WORK-s5p).
    """

    def assert_untouched(self, r):
        self.assertEqual(self.states(), [])
        self.assertFalse((self.signals / f"{self.SLUG}.self-state").exists())

    def test_done_is_not_overwritten(self):
        self.set_task_state("done", "Done", terminal=True)
        r = self.run_snippet('resume_work; echo "rc=$?"')
        self.assertIn("rc=3", r.stdout)
        self.assert_untouched(r)
        self.assertIn("resume-refused-terminal", (self.signals / "events.log").read_text())

    def test_wont_do_is_not_overwritten(self):
        self.set_task_state("wontdo", "Won't Do", terminal=True)
        r = self.run_snippet('resume_work; echo "rc=$?"')
        self.assertIn("rc=3", r.stdout)
        self.assert_untouched(r)

    def test_custom_terminal_state_is_detected_by_flag_not_name(self):
        self.set_task_state("xyz123", "Shipped", terminal=True)
        r = self.run_snippet('resume_work; echo "rc=$?"')
        self.assertIn("rc=3", r.stdout)
        self.assert_untouched(r)

    def test_failed_read_writes_nothing(self):
        # Fails closed: overwriting the user's state is the harm being prevented.
        (self.stub_dir / "show.json").unlink()
        r = self.run_snippet('resume_work; echo "rc=$?"')
        self.assertIn("rc=1", r.stdout)
        self.assert_untouched(r)
        self.assertIn("resume-aborted-read", (self.signals / "events.log").read_text())

    def test_attention_resumes_to_doing(self):
        r = self.run_snippet('resume_work; echo "rc=$?"')
        self.assertIn("rc=0", r.stdout)
        self.assertEqual(self.states(), [f"{self.FULL}|Doing"])

    def test_fresh_pickup_from_ready_resumes_to_doing(self):
        # The launcher leaves the task in Ready while Claude boots; the worker
        # claims it with this very call.
        self.set_task_state("ready", "Ready", terminal=False)
        r = self.run_snippet('resume_work; echo "rc=$?"')
        self.assertIn("rc=0", r.stdout)
        self.assertEqual(self.states(), [f"{self.FULL}|Doing"])

    def test_doing_resumes_to_doing(self):
        self.set_task_state("doing", "Doing", terminal=False)
        r = self.run_snippet('resume_work; echo "rc=$?"')
        self.assertIn("rc=0", r.stdout)
        self.assertEqual(self.states(), [f"{self.FULL}|Doing"])


class TestResumeWorkUserState(AgentHarness):
    """
    The terminal guard alone let resume_work overwrite any *open* state the user
    chose. A user moving the task to In Review was put straight back in Doing
    before read_inbox had reported the move (WORK-jtc, WORK-pjx). Only the states
    the agent lifecycle itself produces — Ready, Doing, Attention — may be
    overwritten; anything else is the user parking the task.
    """

    def assert_refused_as_parked(self, r):
        self.assertIn("rc=4", r.stdout)
        self.assertEqual(self.states(), [])
        self.assertFalse((self.signals / f"{self.SLUG}.self-state").exists())
        self.assertIn("resume-refused-user-state", (self.signals / "events.log").read_text())

    def test_in_review_is_not_overwritten(self):
        self.set_task_state("dnzszhtx927tvgd7ybpynkd72y", "In Review", terminal=False)
        r = self.run_snippet('resume_work; echo "rc=$?"')
        self.assert_refused_as_parked(r)
        self.assertIn("In Review", r.stderr)

    def test_to_do_is_not_overwritten(self):
        self.set_task_state("todo", "To Do", terminal=False)
        self.assert_refused_as_parked(self.run_snippet('resume_work; echo "rc=$?"'))

    def test_custom_open_state_is_not_overwritten(self):
        self.set_task_state("q7w8e9", "Waiting on vendor", terminal=False)
        self.assert_refused_as_parked(self.run_snippet('resume_work; echo "rc=$?"'))

    def test_owned_states_match_by_name_not_id(self):
        # Real projects give Attention and Ready random ids.
        self.set_task_state("e4e1r03fdqm4krnf1rwb0tjdg7", "attention", terminal=False)
        r = self.run_snippet('resume_work; echo "rc=$?"')
        self.assertIn("rc=0", r.stdout)
        self.assertEqual(self.states(), [f"{self.FULL}|Doing"])

    def test_parked_is_not_reported_as_closed(self):
        # 3 tells the agent to run finish_cleanup, which would release
        # dependents and kill the sidecar of a task the user merely parked.
        self.set_task_state("dnzszhtx927tvgd7ybpynkd72y", "In Review", terminal=False)
        r = self.run_snippet('resume_work; echo "rc=$?"')
        self.assertNotIn("rc=3", r.stdout)
        self.assertNotIn("resume-refused-terminal", (self.signals / "events.log").read_text())

    def test_blocked_is_parked_not_closed(self):
        # Blocked is a pause the user can lift. Reporting it as closed made the
        # agent run finish_cleanup, which deleted .ready and left a live worker
        # that no nudge could ever reach again once the task was unblocked
        # (WORK-8tq, WORK-bx4).
        self.set_task_state("blocked", "Blocked", terminal=False)
        r = self.run_snippet('resume_work; echo "rc=$?"')
        self.assert_refused_as_parked(r)
        self.assertNotIn("resume-refused-terminal", (self.signals / "events.log").read_text())

    def test_unblocked_back_to_ready_resumes_to_doing(self):
        self.set_task_state("blocked", "Blocked", terminal=False)
        self.run_snippet('resume_work')
        self.set_task_state("ready", "Ready", terminal=False)
        r = self.run_snippet('resume_work; echo "rc=$?"')
        self.assertIn("rc=0", r.stdout)
        self.assertEqual(self.states(), [f"{self.FULL}|Doing"])

    def test_parked_resume_keeps_the_summary_marker(self):
        (self.signals / f"{self.SLUG}.summary-posted").touch()
        self.set_task_state("dnzszhtx927tvgd7ybpynkd72y", "In Review", terminal=False)
        self.run_snippet('resume_work')
        self.assertTrue((self.signals / f"{self.SLUG}.summary-posted").exists())

    def test_zsh_refuses_parked_state_too(self):
        self.set_task_state("dnzszhtx927tvgd7ybpynkd72y", "In Review", terminal=False)
        r = self.run_snippet('resume_work; echo "rc=$?"', shell="zsh",
                             notecove_bin=f"bash {self.cli}")
        self.assert_refused_as_parked(r)


class TestResumeWorkSummaryMarker(AgentHarness):
    def test_refused_resume_keeps_the_summary_marker(self):
        """
        A refused resume is not a new working turn, so it must not reopen the
        summary obligation and make finish_cleanup post a stale fallback.
        """
        (self.signals / f"{self.SLUG}.summary-posted").touch()
        self.set_task_state("done", "Done", terminal=True)
        self.run_snippet('resume_work')
        self.assertTrue((self.signals / f"{self.SLUG}.summary-posted").exists())


class TestPostSummary(AgentHarness):
    def test_successful_post_marks_the_turn_as_summarised(self):
        self.run_snippet('post_summary "did a thing"')
        self.assertTrue((self.signals / f"{self.SLUG}.summary-posted").exists())

    def test_over_length_summary_is_truncated_not_dropped(self):
        """
        The silent-failure case. NoteCove rejects a long body with rc=1 and no
        output, so without truncation the user is told nothing at all — worse
        than being told a shortened version.
        """
        r = self.run_snippet(f'post_summary "$(printf "x%.0s" {{1..2000}})"')
        self.assertEqual(r.returncode, 0)
        self.assertEqual(len(self.bodies()), 1)
        body = self.bodies()[0]
        self.assertIn("truncated", body)
        self.assertLess(len(body), 996)

    def test_failed_post_returns_nonzero_and_leaves_no_marker(self):
        (self.stub_dir / "fail-comments").touch()
        r = self.run_snippet('post_summary "nope"')
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse((self.signals / f"{self.SLUG}.summary-posted").exists())
        self.assertIn("WARNING", r.stderr)

    def test_failed_post_is_retried_once(self):
        """A transient CLI failure must not cost the user their only summary."""
        (self.stub_dir / "fail-comments").touch()
        self.run_snippet('post_summary "nope"')
        log = (self.signals / "events.log").read_text()
        self.assertIn("summary-post-failed", log)

    def test_empty_summary_is_refused(self):
        r = self.run_snippet('post_summary ""')
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.comments(), [])


class TestSummaryGuarantee(AgentHarness):
    def test_request_attention_without_a_summary_posts_a_fallback(self):
        """
        The bug this closes: the task reaches Attention and the user has no idea
        why. A generic comment is poor, but it is the difference between "the
        agent wants something" and silence.
        """
        self.run_snippet('resume_work; request_attention')
        self.assertEqual(len(self.comments()), 1)
        self.assertIn("Handing this task back", self.bodies()[0])
        self.assertEqual(self.states()[-1], f"{self.FULL}|Attention")

    def test_request_attention_does_not_duplicate_an_existing_summary(self):
        self.run_snippet('resume_work; post_summary "real summary"; request_attention')
        self.assertEqual(self.bodies(), ["real summary"])

    def test_request_attention_accepts_the_summary_inline(self):
        self.run_snippet('resume_work; request_attention "Attention" "inline summary"')
        self.assertEqual(self.bodies(), ["inline summary"])

    def test_resume_work_reopens_the_obligation(self):
        """
        The guarantee is per working turn, not per task. A second round of work
        that says nothing is the same failure as the first.
        """
        self.run_snippet(
            'resume_work; post_summary "round one"; request_attention;'
            ' resume_work; request_attention'
        )
        bodies = self.bodies()
        self.assertEqual(len(bodies), 2)
        self.assertEqual(bodies[0], "round one")
        self.assertIn("Handing this task back", bodies[1])

    def test_a_rejected_summary_still_triggers_the_fallback(self):
        """
        Belt and braces: post_summary truncates, but if the post fails outright
        the marker is never written, so the fallback still fires.
        """
        (self.stub_dir / "fail-comments").touch()
        self.run_snippet('resume_work; post_summary "real"; request_attention')
        # Both the real summary and the fallback were rejected by the stub, but
        # the state change must still happen — a stuck Doing is worse.
        self.assertEqual(self.states()[-1], f"{self.FULL}|Attention")

    def test_finish_task_posts_a_closing_summary(self):
        self.run_snippet('resume_work; finish_task "Done" "WORK"')
        self.assertIn("Closing this task as Done", self.bodies()[-1])
        self.assertEqual(self.states()[-1], f"{self.FULL}|Done")

    def test_finish_task_accepts_the_summary_inline(self):
        self.run_snippet('resume_work; finish_task "Done" "WORK" "merged and shipped"')
        self.assertEqual(self.bodies(), ["merged and shipped"])

    def test_finish_cleanup_comments_without_changing_state(self):
        """The user set the terminal state; overwriting it would be wrong."""
        self.run_snippet('resume_work; finish_cleanup "WORK"')
        self.assertEqual(self.states(), [f"{self.FULL}|Doing"])
        self.assertIn("terminal state", self.bodies()[-1])

    def test_finish_task_still_runs_the_cleanup(self):
        self.run_snippet('resume_work; finish_task "Done" "WORK"')
        log = (self.stub_dir / "task-done.log").read_text()
        self.assertIn(f"{self.SLUG} WORK", log)


@unittest.skipUnless(shutil.which("zsh"), "zsh not installed")
class TestSourcedFromZsh(AgentHarness):
    """
    The skills tell agents to source this helper straight into their shell, and
    the Claude Code Bash tool's shell is zsh on macOS. With the real two-word
    NOTECOVE_BIN every call failed there, so resume_work never set Doing and
    post_summary never posted. The stub is invoked as `bash <stub>` to keep that
    two-word shape — a one-word path would pass regardless.
    """

    def run_zsh(self, snippet: str, **kw) -> subprocess.CompletedProcess:
        return self.run_snippet(snippet, shell="zsh",
                                notecove_bin=f"bash {self.cli}", **kw)

    def test_resume_work_sets_doing(self):
        r = self.run_zsh('resume_work; echo "rc=$?"')
        self.assertIn("rc=0", r.stdout, r.stderr)
        self.assertEqual(self.states(), [f"{self.FULL}|Doing"])

    def test_summary_then_attention(self):
        r = self.run_zsh('resume_work && post_summary "did the thing" && request_attention Attention')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.bodies(), ["did the thing"])
        self.assertEqual(self.states(), [f"{self.FULL}|Doing", f"{self.FULL}|Attention"])

    def test_over_long_summary_is_truncated_not_dropped(self):
        self.run_zsh(f'post_summary "{"x" * 2000}"')
        self.assertEqual(len(self.bodies()), 1)
        self.assertTrue(self.bodies()[0].startswith("x" * 900))
        self.assertNotIn("x" * 901, self.bodies()[0])


if __name__ == "__main__":
    unittest.main(verbosity=2)
