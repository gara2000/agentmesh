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

    def test_a_comment_frame_for_this_task_matches(self):
        """Adding a comment emits comment.thread_added, not a task.* frame. Its
        item is the task the comment is on, so the id match covers it as is."""
        frame = self._frame(self.TASK_ID, ftype="comment.thread_added")
        frame["payload"] = {"itemId": self.TASK_ID, "threadId": "Y-OZamcSS4OYs0wYtzsggw"}
        self.assertTrue(self.matches(frame))

    def test_a_comment_frame_for_another_task_does_not_match(self):
        frame = self._frame("someotherid999", ftype="comment.thread_added")
        frame["payload"] = {"itemId": "someotherid999", "threadId": "t-1"}
        self.assertFalse(self.matches(frame))


class TestSubscriptionFilter(unittest.TestCase):
    """
    Which event types the sidecar subscribes to.

    The stream used to be filtered to task.* only. NoteCove reports a new
    comment as comment.thread_added, so the server dropped every comment frame
    before the sidecar saw it, and comments, most of the conversation, were
    only ever caught by the 60-second poll. Matching was never the problem: the
    frames simply never arrived.
    """

    def subscribed_types(self) -> list:
        m = re.search(r'^SSE_TYPES="([^"]+)"', SIDECAR.read_text(), re.M)
        self.assertIsNotNone(m, "sidecar.sh must define SSE_TYPES")
        return m.group(1).split(",")

    def test_comment_events_are_subscribed(self):
        self.assertIn("comment.*", self.subscribed_types())

    def test_task_events_are_subscribed(self):
        self.assertIn("task.*", self.subscribed_types())

    def test_the_stream_uses_the_filter(self):
        """Guards against the filter being hard-coded again at the call site."""
        text = SIDECAR.read_text()
        self.assertIn('events --types "$SSE_TYPES"', text)
        self.assertNotIn('events --types "task.*" --json', text)


def extract_bash_function(name: str) -> str:
    """Pull one top-level bash function definition out of sidecar.sh."""
    m = re.search(r"^%s\(\) \{\n.*?^\}\n" % re.escape(name), SIDECAR.read_text(),
                  re.S | re.M)
    if not m:
        raise AssertionError(f"could not find {name}() in sidecar.sh")
    return m.group(0)


class TestHotPoll(unittest.TestCase):
    """
    The hot poll: a short poll interval while the task is being worked on.

    Comments posted from the NoteCove UI emit no event at all — only CLI
    comments emit comment.thread_added, and those are the agent's own. So for
    every reply that matters push never fires, and the poll is the detector.
    On a plain 60-second poll that meant up to a minute of latency on the
    whole conversation (WORK-x52). The UI does emit task.opened when the user
    opens the task, and every state change emits task.*, so any frame for the
    task arms a window in which the poll runs at HOT_INTERVAL instead.
    """

    FUNCS = ("hot_until", "arm_hot_window", "poll_interval_now")

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.hot_until = self.tmp / "WORK-x.hot-until"
        self.log = self.tmp / "events.log"
        self.lib = "\n".join(extract_bash_function(f) for f in self.FUNCS)

    def bash(self, body: str, poll=60, hot_interval=10, hot_window=900) -> str:
        script = (
            f'HOT_UNTIL="{self.hot_until}"; POLL_INTERVAL={poll}; '
            f'HOT_INTERVAL={hot_interval}; HOT_WINDOW={hot_window}\n'
            f'log_event() {{ echo "$1" >> "{self.log}"; }}\n'
            f"{self.lib}\n{body}\n")
        r = subprocess.run(["bash", "-c", script], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout.strip()

    def logged(self) -> list:
        return self.log.read_text().split() if self.log.exists() else []

    def test_cold_by_default(self):
        self.assertEqual(self.bash("poll_interval_now"), "60")

    def test_arming_switches_to_the_hot_interval(self):
        self.assertEqual(self.bash("arm_hot_window; poll_interval_now"), "10")
        self.assertEqual(self.logged(), ["hot-poll-armed"])

    def test_window_lasts_hot_window_seconds(self):
        out = self.bash('before=$(date +%s); arm_hot_window; echo $(( $(hot_until) - before ))')
        self.assertIn(int(out), (900, 901))

    def test_rearming_extends_silently(self):
        """Every frame re-arms; logging each one would flood events.log."""
        self.hot_until.write_text("1\n")   # long expired
        self.bash("arm_hot_window; arm_hot_window; arm_hot_window")
        self.assertEqual(self.logged(), ["hot-poll-armed"])

    def test_rearming_resets_the_window(self):
        """Activity on the task keeps it hot for another full window."""
        out = self.bash('arm_hot_window; d1=$(hot_until); sleep 1.1; '
                        'arm_hot_window; echo $(( $(hot_until) - d1 ))')
        self.assertGreaterEqual(int(out), 1)

    def test_expired_window_falls_back_to_the_normal_poll(self):
        self.hot_until.write_text("1\n")
        self.assertEqual(self.bash("poll_interval_now"), "60")

    def test_rearming_after_expiry_logs_again(self):
        self.hot_until.write_text("1\n")
        self.bash("arm_hot_window")
        self.assertEqual(self.logged(), ["hot-poll-armed"])

    def test_garbage_file_is_read_as_cold(self):
        self.hot_until.write_text("not a number\n")
        self.assertEqual(self.bash("poll_interval_now"), "60")

    def test_never_slower_than_the_normal_poll(self):
        """A --poll-interval below HOT_INTERVAL must not be lengthened."""
        self.assertEqual(self.bash("arm_hot_window; poll_interval_now", poll=5), "5")

    def test_defaults(self):
        text = SIDECAR.read_text()
        self.assertRegex(text, r'(?m)^HOT_INTERVAL="10"$')
        self.assertRegex(text, r'(?m)^HOT_WINDOW="900"$')

    def test_matched_frames_arm_before_diffing(self):
        """A UI comment has no frame of its own; the task.opened before it must arm."""
        body = extract_bash_function("sse_loop")
        self.assertRegex(body, r'sse-frame-matched"\s*\n(\s*#.*\n)*\s*arm_hot_window\s*\n\s*check_for_changes')

    def test_detected_changes_arm(self):
        """A change found by the poll is usually a UI comment: keep listening fast."""
        body = extract_bash_function("check_for_changes")
        self.assertIn("arm_hot_window", body.split("change-detected")[1])

    def test_sidecar_start_arms(self):
        main = SIDECAR.read_text().split("# Main\n", 1)[1]
        self.assertLess(main.index("arm_hot_window"), main.index("sse_loop &"))

    def test_main_loop_ticks_and_uses_the_current_interval(self):
        main = SIDECAR.read_text().split("# Main\n", 1)[1]
        self.assertIn('sleep "$TICK"', main)
        self.assertIn("$(poll_interval_now)", main)
        self.assertNotIn('sleep "$POLL_INTERVAL"', main)


if __name__ == "__main__":
    unittest.main(verbosity=2)
