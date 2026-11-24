"""
Unit tests for pr-monitor.sh — merge detection and inline review comments.

New inline review comments are not delivered by the monitor itself. It posts a
NoteCove comment on the task, as "PR Monitor", and the sidecar reports that like
any other comment the agent did not write. So what matters here is: exactly one
NoteCove comment per batch of new review comments, carrying everything the worker
needs; nothing for comments the worker has already answered or that it wrote
itself; and nothing lost when gh or NoteCove fails.

One monitor watches every PR of its task (signals/<slug>.prs). The worker is told
to set Done only once all of them have merged; a PR closed unmerged drops out.

PR number <n> can be given its own state / comments / checks via stub files
state-<n> / comments-<n>.jsonl / checks-<n>.json; without them every PR shares
state / comments.jsonl / checks.json. A state file holds "<STATE> [<head-sha>]".

A failed CI check is reported the same way as a review comment: one NoteCove
comment as "PR Monitor", once per (PR, head commit, check).

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
# The PR number: the last /<n> component of the URL or API path in $3.
n=$(printf '%s' "$3" | sed -nE 's#.*/(pull|pulls)/([0-9]+).*#\2#p')
case "$1 $2" in
  "pr view")
    if [ -f "$STUB/state-$n" ]; then cat "$STUB/state-$n"; else cat "$STUB/state" 2>/dev/null; fi ;;
  "pr checks")
    [ -f "$STUB/gh-checks-fail" ] && { echo "boom" >&2; exit 1; }
    if [ -f "$STUB/checks-$n.json" ]; then cat "$STUB/checks-$n.json"
    else cat "$STUB/checks.json" 2>/dev/null; fi
    # gh exits 1 when a check failed and 8 while any is pending, --json or not.
    grep -q '"fail"' "$STUB/checks-$n.json" "$STUB/checks.json" 2>/dev/null && exit 1
    exit 0 ;;
  "api "*)
    [ -f "$STUB/gh-api-fail" ] && exit 1
    if [ -f "$STUB/comments-$n.jsonl" ]; then cat "$STUB/comments-$n.jsonl"
    else cat "$STUB/comments.jsonl" 2>/dev/null; fi ;;
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
PR_URL_2 = "https://github.com/acme/gadgets/pull/9"


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

    def set_comments(self, comments, pr=None):
        name = f"comments-{pr}.jsonl" if pr else "comments.jsonl"
        (self.stub / name).write_text(
            "".join(json.dumps(c) + "\n" for c in comments))

    def set_pr_state(self, pr, state):
        (self.stub / f"state-{pr}").write_text(state + "\n")

    def set_checks(self, checks, pr=None):
        name = f"checks-{pr}.json" if pr else "checks.json"
        (self.stub / name).write_text(json.dumps(checks))

    def ci_reported(self):
        p = self.signals / f"{self.SLUG}.pr-ci-reported"
        return p.read_text().splitlines() if p.exists() else None

    def watch(self, *urls):
        with open(self.signals / f"{self.SLUG}.prs", "a") as f:
            f.writelines(u + "\n" for u in urls)

    def inbox(self):
        p = self.signals / f"{self.SLUG}.inbox"
        return [json.loads(l) for l in p.read_text().splitlines()] if p.exists() else []

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
        """The comment ids recorded as seen, without the per-PR baseline lines."""
        p = self.signals / f"{self.SLUG}.pr-seen-comments"
        if not p.exists():
            return None
        return [l for l in p.read_text().split("\n")
                if l and not l.startswith("baseline ")]


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
        self.assertIn(f"reply_pr_comment {PR_URL} <thread-id>", text)
        self.assertIn("AI-response footer", text)
        self.assertNotIn("/replies", text, "workers must reply via the helper, not raw gh api")
        self.assertLessEqual(len(text), 996, "NoteCove rejects longer comments")
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


class TestMultiplePrs(PrMonitorHarness):
    """Every PR in signals/<slug>.prs is watched; Done waits for all of them."""

    def setUp(self):
        super().setUp()
        self.watch(PR_URL_2)  # PR_URL arrives on the command line, as before

    def test_command_line_url_joins_the_watch_list(self):
        self.run_once()
        prs = (self.signals / f"{self.SLUG}.prs").read_text().split()
        self.assertEqual(sorted(prs), sorted([PR_URL, PR_URL_2]))
        self.run_once()
        prs = (self.signals / f"{self.SLUG}.prs").read_text().split()
        self.assertEqual(len(prs), 2, "the argument must not be appended twice")

    def test_one_merge_of_two_does_not_tell_the_worker(self):
        self.set_pr_state(7, "MERGED")
        r = self.run_once()
        self.assertEqual(r.returncode, 0)
        self.assertEqual(self.inbox(), [])
        self.assertIn("pr-merged-seen", self.events())
        self.assertNotIn("pr-merged-detected", self.events())
        self.assertEqual((self.signals / f"{self.SLUG}.merged").read_text().split(),
                         [PR_URL])

    def test_merged_pr_is_not_polled_again(self):
        self.set_pr_state(7, "MERGED")
        self.run_once()
        (self.stub / "gh.log").unlink()
        self.run_once()
        self.assertNotIn("/pull/7", (self.stub / "gh.log").read_text())

    def test_all_merged_tells_the_worker_once_with_every_url(self):
        self.set_pr_state(7, "MERGED")
        self.run_once()
        self.set_pr_state(9, "MERGED")
        self.run_once()
        entries = self.inbox()
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]["kind"], "pr-merged")
        self.assertEqual(sorted(entries[0]["urls"]), sorted([PR_URL, PR_URL_2]))
        self.assertIn("All 2 PRs were merged", entries[0]["note"])
        self.assertIn("pr-merged-detected", self.events())

    def test_closed_pr_drops_out_of_the_set(self):
        self.set_pr_state(9, "CLOSED")
        self.run_once()
        self.assertEqual(self.inbox(), [])
        self.assertIn("pr-closed-unmerged", self.events())
        self.set_pr_state(7, "MERGED")
        self.run_once()
        entries = self.inbox()
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]["urls"], [PR_URL])
        self.assertEqual(entries[0]["note"], "PR was merged. Set the task to Done.")

    def test_all_closed_tells_the_worker_nothing(self):
        self.set_pr_state(7, "CLOSED")
        self.set_pr_state(9, "CLOSED")
        self.run_once()
        self.run_once()
        self.assertEqual(self.inbox(), [])

    def test_comments_on_each_pr_are_reported_separately(self):
        self.set_comments([_comment(1)], pr=7)
        self.set_comments([_comment(50, body="typo in gadgets")], pr=9)
        self.run_once()
        posts = [p[-1] for p in self.posted()]
        self.assertEqual(len(posts), 2)
        self.assertTrue(any(PR_URL in t and "#1 " in t for t in posts))
        self.assertTrue(any(PR_URL_2 in t and "typo in gadgets" in t
                            and f"reply_pr_comment {PR_URL_2} " in t for t in posts))
        self.run_once()
        self.assertEqual(len(self.posted()), 2, "each reported once")

    def test_pr_added_later_gets_its_own_first_listing(self):
        self.run_once()  # both PRs baselined with no comments
        url3 = "https://github.com/acme/widgets/pull/11"
        self.set_comments([_comment(70), _comment(71, body=MARKED, reply_to=70)],
                          pr=11)
        self.watch(url3)
        self.run_once()
        # 70 is answered by the worker's marked reply: first-listing history.
        self.assertEqual(self.posted(), [])
        self.assertIn("baseline repos/acme/widgets/pulls/11",
                      (self.signals / f"{self.SLUG}.pr-seen-comments").read_text())
        self.set_comments([_comment(70), _comment(71, body=MARKED, reply_to=70),
                           _comment(72, body="one more")], pr=11)
        self.run_once()
        self.assertEqual(len(self.posted()), 1)
        self.assertIn("one more", self.posted()[0][-1])

    def test_unmerged_pr_added_after_a_merge_keeps_the_task_open(self):
        self.set_pr_state(7, "MERGED")
        self.set_pr_state(9, "MERGED")
        url3 = "https://github.com/acme/widgets/pull/11"
        self.watch(url3)
        self.set_pr_state(11, "OPEN")
        self.run_once()
        self.assertEqual(self.inbox(), [])


def _check(name, bucket="fail", workflow="CI", link=None):
    return {"name": name, "bucket": bucket, "workflow": workflow,
            "link": link or f"https://github.com/acme/widgets/actions/runs/1/job/{name}"}


SHA = "abc1234def5678"
SHA_2 = "fed9876cba5432"


class TestCiFailures(PrMonitorHarness):
    """A failed check on an open PR is posted to the task once per commit."""

    def setUp(self):
        super().setUp()
        self.set_state(f"OPEN {SHA}")

    def test_failed_check_posts_one_comment_as_pr_monitor(self):
        self.set_checks([_check("lint"), _check("unit", bucket="pass")])
        self.run_once()
        posts = self.posted()
        self.assertEqual(len(posts), 1)
        args = posts[0]
        self.assertEqual(args[3], self.FULL, "must address the task by full slug")
        self.assertEqual(args[args.index("--user") + 1], "PR Monitor")
        text = args[-1]
        self.assertIn(f"CI failing on {PR_URL}", text)
        self.assertIn(SHA[:7], text)
        self.assertIn("CI / lint", text)
        self.assertIn("actions/runs/1/job/lint", text)
        self.assertNotIn("unit", text, "passing checks are not listed")
        self.assertIn("--log-failed", text)
        self.assertIn("push", text)
        self.assertIn("request_attention", text)
        self.assertLessEqual(len(text), 996)
        self.assertEqual(self.ci_reported(), [f"{PR_URL} {SHA} CI / lint"])
        self.assertIn("pr-ci-failed-detected", self.events())

    def test_reported_once_per_commit(self):
        self.set_checks([_check("lint")])
        self.run_once()
        self.run_once()
        self.assertEqual(len(self.posted()), 1)

    def test_another_check_failing_later_on_the_same_commit_is_reported(self):
        self.set_checks([_check("lint"), _check("unit", bucket="pending")])
        self.run_once()
        self.set_checks([_check("lint"), _check("unit")])
        self.run_once()
        posts = [p[-1] for p in self.posted()]
        self.assertEqual(len(posts), 2)
        self.assertIn("CI / unit", posts[1])
        self.assertNotIn("CI / lint", posts[1], "lint was already reported")

    def test_new_commit_failing_again_is_reported_again(self):
        self.set_checks([_check("lint")])
        self.run_once()
        self.set_state(f"OPEN {SHA_2}")
        self.run_once()
        posts = [p[-1] for p in self.posted()]
        self.assertEqual(len(posts), 2)
        self.assertIn(SHA_2[:7], posts[1])

    def test_passing_pending_cancelled_and_skipped_post_nothing(self):
        self.set_checks([_check("a", bucket="pass"), _check("b", bucket="pending"),
                         _check("c", bucket="cancel"), _check("d", bucket="skipping")])
        self.run_once()
        self.assertEqual(self.posted(), [])
        self.assertNotIn("pr-ci", self.events())

    def test_no_checks_posts_nothing(self):
        # gh prints "no checks reported" to stderr and nothing on stdout.
        self.run_once()
        self.assertEqual(self.posted(), [])

    def test_gh_failure_posts_nothing_and_is_retried(self):
        self.set_checks([_check("lint")])
        (self.stub / "gh-checks-fail").touch()
        self.run_once()
        self.assertEqual(self.posted(), [])
        (self.stub / "gh-checks-fail").unlink()
        self.run_once()
        self.assertEqual(len(self.posted()), 1)

    def test_failed_post_is_retried_next_poll(self):
        self.set_checks([_check("lint")])
        (self.stub / "nc-fail").touch()
        self.run_once()
        self.assertIsNone(self.ci_reported())
        self.assertIn("pr-ci-post-failed", self.events())
        (self.stub / "nc-fail").unlink()
        self.run_once()
        self.assertEqual(len(self.posted()), 1)
        self.assertEqual(len(self.ci_reported()), 1)

    def test_unknown_head_commit_skips_the_check(self):
        self.set_state("OPEN")
        self.set_checks([_check("lint")])
        self.run_once()
        self.assertEqual(self.posted(), [])
        self.assertNotIn("pr checks", (self.stub / "gh.log").read_text())

    def test_merged_pr_is_not_checked(self):
        self.set_state(f"MERGED {SHA}")
        self.set_checks([_check("lint")])
        self.run_once()
        self.assertEqual(self.posted(), [])
        self.assertNotIn("pr checks", (self.stub / "gh.log").read_text())

    def test_check_without_workflow_is_named_alone(self):
        self.set_checks([_check("ci/circleci: build", workflow="")])
        self.run_once()
        text = self.posted()[0][-1]
        self.assertIn("- ci/circleci: build:", text)

    def test_many_failures_stay_under_the_notecove_limit(self):
        self.set_checks([_check(f"job-{i}-" + "x" * 40) for i in range(40)])
        self.run_once()
        text = self.posted()[0][-1]
        self.assertLessEqual(len(text), 996)
        self.assertIn("40 failed checks", text)
        self.assertIn("more:", text)
        self.assertIn("request_attention", text, "instructions must survive truncation")
        self.assertEqual(len(self.ci_reported()), 40, "every failure counts as reported")

    def test_each_pr_is_reported_separately(self):
        self.watch(PR_URL_2)
        self.set_pr_state(9, f"OPEN {SHA_2}")
        self.set_checks([_check("lint")], pr=7)
        self.set_checks([_check("build")], pr=9)
        self.run_once()
        posts = [p[-1] for p in self.posted()]
        self.assertEqual(len(posts), 2)
        self.assertTrue(any(PR_URL in t and "CI / lint" in t for t in posts))
        self.assertTrue(any(PR_URL_2 in t and "CI / build" in t for t in posts))


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
