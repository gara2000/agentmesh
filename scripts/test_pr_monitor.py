"""
Unit tests for pr-monitor.sh — merge detection and inline review comments.

New inline review comments are not delivered by the monitor itself. It posts a
NoteCove comment on the task, as "PR Monitor", and the sidecar reports that like
any other comment the agent did not write. So what matters here is: exactly one
NoteCove comment per batch of new review comments, carrying everything the worker
needs; nothing for comments the worker has already answered or that it wrote
itself; and nothing lost when gh or NoteCove fails.

Driven with --once against stub gh / notecove / tmux on PATH.
"""
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).parent

GH_STUB = r"""#!/usr/bin/env bash
STUB="$STUB_DIR"
echo "$*" >> "$STUB/gh.log"
case "$1 $2" in
  "pr view") cat "$STUB/state" 2>/dev/null ;;
  "api "*)
    [ -f "$STUB/gh-api-fail" ] && exit 1
    cat "$STUB/comments.jsonl" 2>/dev/null ;;
esac
exit 0
"""

NOTECOVE_STUB = r"""#!/usr/bin/env bash
STUB="$STUB_DIR"
if [ "$1 $2 $3" = "task comments add" ]; then
  [ -f "$STUB/nc-fail" ] && exit 1
  python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "$@" >> "$STUB/posted.jsonl"
fi
exit 0
"""

# tmux that cannot be queried: delivery is deferred, never typed.
TMUX_STUB = "#!/usr/bin/env bash\nexit 1\n"

PR_URL = "https://github.com/acme/widgets/pull/7"
API = "repos/acme/widgets/pulls/7"


def _comment(cid, body="please rename this", login="alice", path="src/x.py",
             line=12, reply_to=None):
    c = {"id": cid, "body": body, "user": {"login": login}, "path": path,
         "line": line}
    if reply_to is not None:
        c["in_reply_to_id"] = reply_to
    return c


class PrMonitorHarness(unittest.TestCase):
    SLUG = "WORK-abc"
    FULL = "WORK-abc:longid"

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        root = Path(self._tmp.name)
        self.scripts = root / "scripts"
        self.signals = root / "signals"
        self.stub = root / "stub"
        self.bin = root / "bin"
        for d in (self.scripts, self.signals, self.stub, self.bin):
            d.mkdir()
        for name in ("pr-monitor.sh", "notecove-ref.sh", "notify-worker.sh"):
            shutil.copy(SCRIPTS / name, self.scripts / name)
        for name, body in (("gh", GH_STUB), ("notecove", NOTECOVE_STUB),
                           ("tmux", TMUX_STUB)):
            (self.bin / name).write_text(body)
            (self.bin / name).chmod(0o755)
        (self.signals / "events.log").touch()
        (self.signals / f"{self.SLUG}.full-slug").write_text(self.FULL + "\n")
        self.set_state("OPEN")
        self.set_comments([])

    # -- stub control -------------------------------------------------------
    def set_state(self, state):
        (self.stub / "state").write_text(state + "\n")

    def set_comments(self, comments):
        (self.stub / "comments.jsonl").write_text(
            "".join(json.dumps(c) + "\n" for c in comments))

    def run_once(self):
        env = dict(os.environ,
                   PATH=f"{self.bin}:{os.environ['PATH']}",
                   STUB_DIR=str(self.stub),
                   NOTECOVE_BIN=str(self.bin / "notecove"),
                   MERGE_RETRY_SLEEP="0", NUDGE_SETTLE="0")
        return subprocess.run(
            ["bash", str(self.scripts / "pr-monitor.sh"), self.SLUG, PR_URL,
             "1", "--once"],
            env=env, capture_output=True, text=True, timeout=30)

    def posted(self):
        p = self.stub / "posted.jsonl"
        if not p.exists():
            return []
        return [json.loads(l) for l in p.read_text().splitlines() if l]

    def events(self):
        return (self.signals / "events.log").read_text()

    def seed_seen(self, *ids):
        (self.signals / f"{self.SLUG}.pr-seen-comments").write_text(
            "".join(i + "\n" for i in ids))

    def seen(self):
        p = self.signals / f"{self.SLUG}.pr-seen-comments"
        return p.read_text().split() if p.exists() else None


MARKED = "Done.\n\n<!-- agentmesh -->"


class TestBaseline(PrMonitorHarness):
    """A fresh monitor (no .pr-seen-comments) must not hide unanswered comments.

    The seen file is lost whenever a worker is adopted or crash-cleaned, so the
    first listing is not "history" — only threads the worker has answered are.
    """

    def test_first_run_reports_unanswered_comments(self):
        self.set_comments([_comment(1), _comment(2, login="autotest[bot]")])
        self.run_once()
        posts = self.posted()
        self.assertEqual(len(posts), 1)
        self.assertIn("2 new inline review comments", posts[0][-1])
        self.assertIn("@autotest[bot]", posts[0][-1])
        self.assertEqual(self.seen(), ["1", "2"])

    def test_first_run_baselines_answered_threads(self):
        self.set_comments([_comment(1), _comment(2, body=MARKED, reply_to=1)])
        self.run_once()
        self.assertEqual(self.posted(), [])
        self.assertEqual(self.seen(), ["1", "2"])

    def test_first_run_reports_follow_up_after_an_answer(self):
        self.set_comments([_comment(1), _comment(2, body=MARKED, reply_to=1),
                           _comment(3, body="still wrong", reply_to=1)])
        self.run_once()
        text = self.posted()[0][-1]
        self.assertIn("1 new inline review comment on", text)
        self.assertIn("#3 (thread #1)", text)
        self.assertEqual(self.seen(), ["1", "2", "3"])

    def test_answer_in_one_thread_does_not_cover_another(self):
        self.set_comments([_comment(1), _comment(2, body=MARKED, reply_to=1),
                           _comment(3)])
        self.run_once()
        text = self.posted()[0][-1]
        self.assertIn("#3", text)
        self.assertNotIn("#1 ", text)

    def test_first_run_with_no_comments_posts_nothing(self):
        self.run_once()
        self.assertEqual(self.posted(), [])
        self.assertEqual(self.seen(), [])

    def test_restart_does_not_replay(self):
        self.set_comments([_comment(1)])
        self.run_once()
        self.run_once()
        self.assertEqual(len(self.posted()), 1)

    def test_failed_first_post_is_retried(self):
        self.set_comments([_comment(1)])
        (self.stub / "nc-fail").touch()
        self.run_once()
        self.assertEqual(self.seen(), [])
        (self.stub / "nc-fail").unlink()
        self.run_once()
        self.assertEqual(len(self.posted()), 1)
        self.assertEqual(self.seen(), ["1"])


class TestNewComments(PrMonitorHarness):
    def setUp(self):
        super().setUp()
        self.set_comments([_comment(1)])
        self.seed_seen("1")  # comment 1 already reported

    def test_new_comment_posts_one_notecove_comment_as_pr_monitor(self):
        self.set_comments([_comment(1), _comment(2, body="handle None here")])
        self.run_once()
        posts = self.posted()
        self.assertEqual(len(posts), 1)
        args = posts[0]
        self.assertEqual(args[3], self.FULL, "must address the task by full slug")
        self.assertIn("--user", args)
        self.assertEqual(args[args.index("--user") + 1], "PR Monitor")
        text = args[-1]
        self.assertIn("1 new inline review comment on " + PR_URL, text)
        self.assertIn("#2", text)
        self.assertIn("@alice src/x.py:12", text)
        self.assertIn("handle None here", text)
        self.assertIn(f"gh api {API}/comments/<thread-id>/replies", text)
        self.assertIn("<!-- agentmesh -->", text)
        self.assertIn("request_attention", text)
        self.assertNotIn("#1 ", text)
        self.assertEqual(self.seen(), ["1", "2"])
        self.assertIn("pr-comments-detected", self.events())

    def test_reported_once(self):
        self.set_comments([_comment(1), _comment(2)])
        self.run_once()
        self.run_once()
        self.assertEqual(len(self.posted()), 1)

    def test_thread_reply_names_its_thread_root(self):
        self.set_comments([_comment(1), _comment(5, reply_to=1)])
        self.run_once()
        self.assertIn("#5 (thread #1)", self.posted()[0][-1])

    def test_worker_replies_carrying_the_marker_are_ignored(self):
        self.set_comments([_comment(1),
                           _comment(3, body="Renamed.\n\n<!-- agentmesh -->",
                                    reply_to=1)])
        self.run_once()
        self.assertEqual(self.posted(), [])
        self.assertIn("3", self.seen())

    def test_bot_comments_are_reported(self):
        self.set_comments([_comment(1), _comment(4, login="copilot[bot]")])
        self.run_once()
        self.assertIn("@copilot[bot]", self.posted()[0][-1])

    def test_many_comments_stay_under_the_notecove_limit(self):
        many = [_comment(i, body="x" * 200, path="a/very/long/path/file.py")
                for i in range(2, 40)]
        self.set_comments([_comment(1)] + many)
        self.run_once()
        text = self.posted()[0][-1]
        self.assertLessEqual(len(text), 996)
        self.assertIn("38 new inline review comments", text)
        self.assertIn("more:", text)
        self.assertIn("request_attention", text, "instructions must survive truncation")


class TestFailures(PrMonitorHarness):
    def setUp(self):
        super().setUp()
        self.set_comments([_comment(1)])
        self.seed_seen("1")  # comment 1 already reported

    def test_gh_failure_leaves_baseline_untouched(self):
        self.set_comments([_comment(1), _comment(2)])
        (self.stub / "gh-api-fail").touch()
        self.run_once()
        self.assertEqual(self.seen(), ["1"])
        self.assertIn("pr-comments-fetch-failed", self.events())
        (self.stub / "gh-api-fail").unlink()
        self.run_once()
        self.assertEqual(len(self.posted()), 1)

    def test_failed_post_is_retried_next_poll(self):
        self.set_comments([_comment(1), _comment(2)])
        (self.stub / "nc-fail").touch()
        self.run_once()
        self.assertEqual(self.seen(), ["1"])
        self.assertIn("pr-comments-post-failed", self.events())
        (self.stub / "nc-fail").unlink()
        self.run_once()
        self.assertEqual(len(self.posted()), 1)
        self.assertEqual(self.seen(), ["1", "2"])

    def test_gh_failure_on_first_run_does_not_baseline(self):
        (self.signals / f"{self.SLUG}.pr-seen-comments").unlink()
        (self.stub / "gh-api-fail").touch()
        self.run_once()
        self.assertIsNone(self.seen())


class TestMerge(PrMonitorHarness):
    def test_merge_writes_inbox_and_skips_comment_check(self):
        self.set_state("MERGED")
        self.set_comments([_comment(1)])
        r = self.run_once()
        self.assertEqual(r.returncode, 0)
        inbox = (self.signals / f"{self.SLUG}.inbox").read_text()
        self.assertEqual(json.loads(inbox)["kind"], "pr-merged")
        self.assertTrue((self.signals / f"{self.SLUG}.merged").exists())
        self.assertIsNone(self.seen())
        self.assertEqual(self.posted(), [])


class TestUnparsableUrl(PrMonitorHarness):
    def test_non_github_url_skips_comment_watch(self):
        env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                   STUB_DIR=str(self.stub), NOTECOVE_BIN=str(self.bin / "notecove"))
        subprocess.run(["bash", str(self.scripts / "pr-monitor.sh"), self.SLUG,
                        "not-a-url", "1", "--once"],
                       env=env, capture_output=True, text=True, timeout=30)
        self.assertIn("pr-url-unparsed", self.events())
        self.assertIsNone(self.seen())


if __name__ == "__main__":
    unittest.main()
