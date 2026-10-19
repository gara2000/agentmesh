"""
Unit tests for the sidecar's diff step — what reaches the agent's inbox.

The diff is the only place that decides whether an agent gets interrupted, and
the cost of getting it wrong changed when delivery became `tmux send-keys` into
a live REPL. Under the old signal protocol a spurious nudge was absorbed by an
agent that was already blocked waiting for one; now it lands mid-work, so the
filters have to be exact in both directions:

  - report too much and an agent interrupts itself on its own writes
  - report too little and the user's reply is lost, because the baseline has
    already absorbed it and it is never reported again

The diff is a self-contained python program embedded in sidecar.sh, driven
entirely by env-var paths and task JSON on stdin. The tests extract it from the
script and run it directly, so they exercise the shipped source rather than a
copy of it — and they avoid stubbing NoteCove, which the sidecar invokes by
absolute path.
"""
import json
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

SIDECAR = Path(__file__).parent / "sidecar.sh"
HANDLE = "Implementer"


def extract_diff_program() -> str:
    """Pull the embedded python program out of sidecar.sh.

    It sits between `python3 -c '` and the closing `' 2>/dev/null)`. The program
    deliberately contains no single quote anywhere — one apostrophe in a comment
    would terminate the shell string and break the script — so this split is
    unambiguous.
    """
    text = SIDECAR.read_text()
    m = re.search(r"python3 -c '\n(.*?)\n' 2>/dev/null\)", text, re.S)
    if not m:
        raise AssertionError(
            "could not find the embedded diff program in sidecar.sh — if its "
            "invocation was reshaped, update this extractor")
    return m.group(1)


class DiffHarness(unittest.TestCase):
    """Runs the extracted diff program against task JSON and baseline files."""

    @classmethod
    def setUpClass(cls):
        cls.program = extract_diff_program()

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        d = Path(self._tmp.name)
        self.inbox = d / "t.inbox"
        self.seen_comments = d / "t.seen-comments"
        self.seen_state = d / "t.seen-state"
        self.self_state = d / "t.self-state"

    # -- fixture helpers ---------------------------------------------------

    def baseline(self, state_id="doing", comment_ids=()):
        """Pretend the sidecar has already run once. Without this every diff is
        a first run, which establishes the baseline and reports nothing."""
        self.seen_state.write_text(state_id)
        self.seen_comments.write_text("".join(f"{c}\n" for c in comment_ids))

    def task(self, state_id="doing", state_name="Doing", comments=()):
        return {"stateId": state_id, "stateName": state_name,
                "comments": list(comments)}

    def comment(self, cid, author, content="hi", replies=()):
        return {"id": cid, "authorName": author, "content": content,
                "created": 1, "replies": list(replies)}

    def run_diff(self, task: dict) -> str:
        env = dict(os.environ)
        env.update({
            "AGENT_HANDLE": HANDLE,
            "SEEN_COMMENTS": str(self.seen_comments),
            "SEEN_STATE": str(self.seen_state),
            "SELF_STATE": str(self.self_state),
            "INBOX": str(self.inbox),
        })
        r = subprocess.run(
            ["python3", "-c", self.program],
            input=json.dumps(task), capture_output=True, text=True,
            env=env, timeout=60,
        )
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout.strip()

    def entries(self) -> list:
        if not self.inbox.exists():
            return []
        return [json.loads(l) for l in self.inbox.read_text().splitlines() if l.strip()]

    def kinds(self) -> list:
        return [e["kind"] for e in self.entries()]


class TestSelfStateSuppression(DiffHarness):
    """The agent writes the state name it is about to set to .self-state before
    calling the CLI. Comments have always been filtered by author; state changes
    had no equivalent filter, so the agent's own Doing/Attention writes came
    straight back at it."""

    def test_self_induced_change_is_suppressed(self):
        self.baseline(state_id="doing")
        self.self_state.write_text("Attention")
        self.run_diff(self.task(state_id="attention", state_name="Attention"))
        self.assertEqual(self.kinds(), [],
                         "the agent must not be told about its own state change")

    def test_user_change_is_reported(self):
        self.baseline(state_id="doing")
        self.run_diff(self.task(state_id="wontdo", state_name="Won't Do"))
        self.assertEqual(self.kinds(), ["state-change"])
        e = self.entries()[0]
        self.assertEqual((e["from"], e["to"], e["to_name"]),
                         ("doing", "wontdo", "Won't Do"))

    def test_a_different_state_than_the_marker_is_reported(self):
        # The agent set Attention; the user then moved it somewhere else. The
        # marker must not swallow a move it does not name.
        self.baseline(state_id="doing")
        self.self_state.write_text("Attention")
        self.run_diff(self.task(state_id="blocked", state_name="Blocked"))
        self.assertEqual(self.kinds(), ["state-change"])

    def test_match_is_case_insensitive(self):
        # The marker is whatever the skill passed to resume_work/request_attention;
        # NoteCove returns its own canonical casing for stateName.
        self.baseline(state_id="attention")
        self.self_state.write_text("doing")
        self.run_diff(self.task(state_id="doing", state_name="Doing"))
        self.assertEqual(self.kinds(), [])

    def test_marker_is_consumed_once_absorbed(self):
        self.baseline(state_id="doing")
        self.self_state.write_text("Attention")
        self.run_diff(self.task(state_id="attention", state_name="Attention"))
        self.assertFalse(self.self_state.exists(),
                         "a marker left behind would swallow a later user move")

    def test_marker_is_consumed_even_without_an_observed_transition(self):
        # A fresh sidecar can baseline straight onto the agent's new state, or
        # the agent can move twice between two polls, so the transition itself is
        # not a reliable trigger for clearing the marker. Matching against the
        # *current* state is.
        self.baseline(state_id="attention")  # already there; nothing to diff
        self.self_state.write_text("Attention")
        self.run_diff(self.task(state_id="attention", state_name="Attention"))
        self.assertFalse(self.self_state.exists())

    def test_a_stale_marker_does_not_hide_a_later_user_move_to_that_state(self):
        # The regression the "consume on match" rule exists to prevent: the agent
        # sets Attention, that is absorbed, and much later the user moves the task
        # back to Attention themselves. That second move must be reported.
        self.baseline(state_id="doing")
        self.self_state.write_text("Attention")
        self.run_diff(self.task(state_id="attention", state_name="Attention"))
        self.assertEqual(self.kinds(), [])

        self.run_diff(self.task(state_id="doing", state_name="Doing"))
        self.inbox.write_text("")  # the agent drained its inbox
        self.run_diff(self.task(state_id="attention", state_name="Attention"))
        self.assertEqual(self.kinds(), ["state-change"],
                         "the user's own move to the same state must still arrive")

    def test_suppression_does_not_swallow_comments_in_the_same_pass(self):
        # The agent typically posts its summary and sets Attention together. The
        # summary is its own and filtered by author, but a user comment arriving
        # in the same window must survive the state suppression.
        self.baseline(state_id="doing")
        self.self_state.write_text("Attention")
        self.run_diff(self.task(
            state_id="attention", state_name="Attention",
            comments=[self.comment("c1", HANDLE, "my summary"),
                      self.comment("c2", "gara", "one more thing")]))
        self.assertEqual(self.kinds(), ["comment"])
        self.assertEqual(self.entries()[0]["author"], "gara")

    def test_failed_state_change_leaves_no_marker(self):
        # set_state removes the marker when the CLI call fails, so a change that
        # never happened cannot suppress the user's genuine move to that state.
        # Asserted here as the contract the diff relies on.
        self.baseline(state_id="doing")
        self.run_diff(self.task(state_id="attention", state_name="Attention"))
        self.assertEqual(self.kinds(), ["state-change"])


class TestCommentFiltering(DiffHarness):
    """Pre-existing behaviour, re-asserted because the suppression logic now
    shares the same pass."""

    def test_own_comments_are_ignored(self):
        self.baseline()
        self.run_diff(self.task(comments=[self.comment("c1", HANDLE)]))
        self.assertEqual(self.kinds(), [])

    def test_replies_are_reported(self):
        self.baseline()
        self.run_diff(self.task(comments=[
            self.comment("c1", HANDLE, replies=[self.comment("r1", "gara", "answer")])]))
        self.assertEqual(self.kinds(), ["comment"])
        self.assertEqual(self.entries()[0]["content"], "answer")

    def test_a_comment_is_reported_once(self):
        self.baseline()
        task = self.task(comments=[self.comment("c1", "gara")])
        self.run_diff(task)
        self.inbox.write_text("")
        self.run_diff(task)
        self.assertEqual(self.kinds(), [])

    def test_first_run_establishes_history_without_reporting(self):
        # No baseline files at all: everything that exists predates the sidecar.
        self.run_diff(self.task(comments=[self.comment("c1", "gara")]))
        self.assertEqual(self.kinds(), [])
        self.assertIn("c1", self.seen_comments.read_text())


def extract_frame_program() -> str:
    """Pull the frame_is_ours python program out of sidecar.sh."""
    text = SIDECAR.read_text()
    m = re.search(r"TASK_REF=\"\$TASK_REF\" python3 -c '\n(.*?)\n' 2>/dev/null",
                  text, re.S)
    if not m:
        raise AssertionError(
            "could not find frame_is_ours's embedded program in sidecar.sh")
    return m.group(1)


class TestFrameMatching(unittest.TestCase):
    """
    Which SSE frames count as "this task changed".

    This replaces `grep -qF "$SLUG"` on the raw frame, which never matched once.
    A frame identifies its subject by internal id and carries no slug at all:

      {"type":"task.modified","item":{"type":"task","id":"7jphatbqq77qtm4g4x76zz6de5"}}

    The short slug has a project prefix and a hyphen that the id does not
    (WORK-7jp vs 7jphatbqq...), so the substring test could never succeed — SSE
    triggered no diff from the day the sidecar was written, and the 60-second
    poll was silently the only detection path. Combined with the ambiguous-slug
    hang that wedged that poll, the task went completely deaf.
    """

    @classmethod
    def setUpClass(cls):
        cls.program = extract_frame_program()

    TASK_ID = "7jphatbqq77qtm4g4x76zz6de5"
    TASK_REF = "WORK-7jp:hatbqq77qtm4g4x76zz6de5"

    def matches(self, frame, task_id: str = None, task_ref: str = None) -> bool:
        payload = frame if isinstance(frame, str) else json.dumps(frame)
        r = subprocess.run(
            ["python3", "-c", self.program],
            input=payload, capture_output=True, text=True,
            env=dict(os.environ,
                     TASK_ID=task_id if task_id is not None else self.TASK_ID,
                     TASK_REF=task_ref if task_ref is not None else self.TASK_REF),
        )
        return r.returncode == 0

    def _frame(self, item_id: str, ftype: str = "task.modified") -> dict:
        return {
            "id": "evt-1", "type": ftype, "seq": 7,
            "item": {"type": "task", "id": item_id},
            "payload": {"projectId": "proj-1"},
        }

    def test_frame_for_this_task_matches(self):
        self.assertTrue(self.matches(self._frame(self.TASK_ID)))

    def test_frame_for_another_task_does_not_match(self):
        """Every worker's sidecar sees every frame; matching all of them would
        have each one wake its agent on any task in the project changing."""
        self.assertFalse(self.matches(self._frame("someotherid999")))

    def test_the_old_substring_test_would_have_failed_here(self):
        """Regression guard for the actual defect, stated as the thing it fixes."""
        frame = json.dumps(self._frame(self.TASK_ID))
        self.assertNotIn("WORK-7jp", frame, "frames carry no slug — hence the id match")
        self.assertTrue(self.matches(frame))

    def test_id_is_matched_as_a_field_not_a_substring(self):
        """A longer id containing ours, or ours appearing in projectId, must not
        count — the old grep would have matched both."""
        self.assertFalse(self.matches(self._frame(self.TASK_ID + "extra")))
        frame = self._frame("other")
        frame["payload"]["projectId"] = self.TASK_ID
        self.assertFalse(self.matches(frame))

    def test_a_frame_carrying_a_slug_still_matches(self):
        """No frame does today; this keeps it correct if one ever starts to."""
        frame = self._frame("unknown-id")
        frame["item"]["slug"] = {"full": self.TASK_REF, "short": "WORK-7jp"}
        self.assertTrue(self.matches(frame))

        frame2 = self._frame("unknown-id")
        frame2["item"]["slug"] = self.TASK_REF
        self.assertTrue(self.matches(frame2))

    def test_malformed_frames_are_not_matched(self):
        """The stream is line-delimited and can carry keepalives and partials.
        Treating a parse failure as a match would nudge on every one of them."""
        for junk in ("", "not json", "[]", '{"item": "not-a-dict"}', "{}"):
            with self.subTest(junk=junk):
                self.assertFalse(self.matches(junk))


if __name__ == "__main__":
    unittest.main(verbosity=2)
