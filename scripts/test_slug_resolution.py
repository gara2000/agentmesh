"""
Unit tests for notecove-ref.sh — the slug-ambiguity fix.

A short slug is a *uniquePrefix*: unique only at the moment it was read. New
tasks can lengthen it, and every copy stored before that silently becomes
ambiguous. The NoteCove CLI does not fail on an ambiguous slug — with stdin on a
TTY it prompts, and since every agentmesh daemon runs in a tmux window, every
daemon has a TTY. WORK-7w2's sidecar logged 43 consecutive 30-second timeouts
that way and never saw a comment in between.

These tests drive the helper through a stub CLI on PATH, so they assert on the
two things that actually keep that from recurring:

  - **stdin is closed** on every call, so an ambiguous slug fails in
    milliseconds instead of hanging until the timeout
  - **the full slug is what reaches the CLI**, so the ambiguity is not hit at all

Plus the resolution rules themselves: cache first, refuse to guess between two
matches, and never return empty (callers use nc_ref inline).
"""
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).parent

# Stub NoteCove CLI. Records its argv and whether stdin was readable, and serves
# canned JSON from files the test writes.
NOTECOVE_STUB = r"""#!/usr/bin/env bash
set -uo pipefail
STUB="$STUB_DIR"

echo "$*" >> "$STUB/calls.log"

# Record whether stdin was a TTY / readable at all. nc_run must always close it.
if [ -t 0 ]; then
  echo "tty" >> "$STUB/stdin.log"
else
  echo "closed-or-pipe" >> "$STUB/stdin.log"
fi

case "$1 ${2:-}" in
  "task list")  cat "$STUB/task-list.json" 2>/dev/null; exit 0 ;;
  "task show")
    ref="$3"
    if [ -f "$STUB/show.$ref.json" ]; then
      cat "$STUB/show.$ref.json"; exit 0
    fi
    echo "Ambiguous slug. Please use a more specific slug." >&2
    exit 1
    ;;
esac
exit 0
"""


class RefHarness(unittest.TestCase):
    """A throwaway signals dir with notecove-ref.sh sourced against a stub CLI."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)
        self.stub_dir = self.root / "stub"
        self.signals = self.root / "signals"
        self.bin = self.root / "bin"
        for d in (self.stub_dir, self.signals, self.bin):
            d.mkdir(parents=True, exist_ok=True)

        stub = self.bin / "nc-stub"
        stub.write_text(NOTECOVE_STUB)
        stub.chmod(0o755)
        self.stub = stub

    def run_snippet(self, snippet: str) -> subprocess.CompletedProcess:
        """Source notecove-ref.sh in a fresh bash and run snippet against it."""
        script = (
            f'export SIGNALS="{self.signals}"\n'
            f'export NOTECOVE_BIN="{self.stub}"\n'
            f'source "{SCRIPTS / "notecove-ref.sh"}"\n'
            f"{snippet}\n"
        )
        env = dict(os.environ, STUB_DIR=str(self.stub_dir), HOME=str(self.root))
        return subprocess.run(
            ["bash", "-c", script], capture_output=True, text=True, env=env
        )

    def write_task_list(self, tasks: list) -> None:
        import json
        (self.stub_dir / "task-list.json").write_text(json.dumps(tasks))

    def calls(self) -> list:
        f = self.stub_dir / "calls.log"
        return f.read_text().splitlines() if f.exists() else []


def _task(short: str, full: str, task_id: str = "id-x") -> dict:
    return {"id": task_id, "slug": {"short": short, "full": full}}


class TestNcRun(RefHarness):
    """nc_run is the backstop: it must hold even when resolution has nothing."""

    def test_stdin_is_closed(self):
        """
        The whole reported bug. With stdin open the CLI prompts on an ambiguous
        slug and the caller blocks until the timeout, every poll, forever.
        """
        self.run_snippet('nc_run task show WORK-abc --json >/dev/null 2>&1')
        stdin_log = (self.stub_dir / "stdin.log").read_text().splitlines()
        self.assertEqual(stdin_log, ["closed-or-pipe"])

    def test_returns_cli_exit_code(self):
        """A failing call must fail, not be swallowed — callers branch on it."""
        r = self.run_snippet('nc_run task show WORK-nope --json; echo "rc=$?"')
        self.assertIn("rc=1", r.stdout)

    def test_passes_arguments_through_verbatim(self):
        self.run_snippet('nc_run task list --state Ready --json >/dev/null')
        self.assertEqual(self.calls(), ["task list --state Ready --json"])


class TestNcRef(RefHarness):
    def test_cached_full_slug_is_used_without_any_cli_call(self):
        """
        The launcher writes this file at spawn time, when the full slug is known
        for certain. Hitting the CLI anyway would put a network call in the hot
        path of every poll of every daemon.
        """
        (self.signals / "WORK-abc.full-slug").write_text("WORK-abc:longid\n")
        r = self.run_snippet('nc_ref WORK-abc')
        self.assertEqual(r.stdout, "WORK-abc:longid")
        self.assertEqual(self.calls(), [], "cache hit must not call the CLI")

    def test_resolves_and_caches_when_no_cache_exists(self):
        self.write_task_list([_task("WORK-abc", "WORK-abc:longid")])
        r = self.run_snippet('nc_ref WORK-abc')
        self.assertEqual(r.stdout, "WORK-abc:longid")
        self.assertEqual(
            (self.signals / "WORK-abc.full-slug").read_text(), "WORK-abc:longid",
            "a resolved slug must be cached or every poll re-lists every task",
        )

    def test_resolves_a_stale_short_slug_that_has_since_lengthened(self):
        """
        Exactly the WORK-7w2 case: the stored slug is a strict prefix of the
        task's current slug.short, so an equality test on short alone misses it.
        """
        self.write_task_list([_task("WORK-7w2p", "WORK-7w2p:longid")])
        r = self.run_snippet('nc_ref WORK-7w2p')
        self.assertEqual(r.stdout, "WORK-7w2p:longid")

    def test_prefix_match_on_full_slug(self):
        self.write_task_list([_task("WORK-7w2p", "WORK-7w2:longid")])
        r = self.run_snippet('nc_ref WORK-7w2')
        self.assertEqual(r.stdout, "WORK-7w2:longid")

    def test_two_matches_resolve_to_nothing_rather_than_a_guess(self):
        """
        The distinguishing part of the slug was never recorded, so there is no
        information here to pick with. Guessing would act on the wrong task —
        set its state, comment on it, unblock its dependents. Falling back to the
        short slug produces a fast, loud failure instead.
        """
        self.write_task_list([
            _task("WORK-7w25", "WORK-7w25:aaa"),
            _task("WORK-7w2p", "WORK-7w2p:bbb"),
        ])
        r = self.run_snippet('nc_ref WORK-7w2')
        self.assertEqual(r.stdout, "WORK-7w2")
        self.assertFalse(
            (self.signals / "WORK-7w2.full-slug").exists(),
            "an unresolved slug must not be cached as resolved",
        )

    def test_always_prints_something(self):
        """Callers use nc_ref inline (`task show "$(nc_ref "$slug")"`)."""
        r = self.run_snippet('printf "[%s]" "$(nc_ref WORK-missing)"')
        self.assertEqual(r.stdout, "[WORK-missing]")

    def test_unparseable_listing_falls_back_to_the_short_slug(self):
        (self.stub_dir / "task-list.json").write_text("not json at all")
        r = self.run_snippet('nc_ref WORK-abc')
        self.assertEqual(r.stdout, "WORK-abc")


class TestNcTaskId(RefHarness):
    """SSE frames name their subject by internal id and nothing else."""

    def test_resolves_and_caches_the_id(self):
        self.write_task_list([_task("WORK-abc", "WORK-abc:longid", "7jpabc123")])
        (self.stub_dir / "show.WORK-abc:longid.json").write_text(
            '{"id":"7jpabc123","slug":{"short":"WORK-abc","full":"WORK-abc:longid"}}'
        )
        r = self.run_snippet('nc_task_id WORK-abc')
        self.assertEqual(r.stdout, "7jpabc123")
        self.assertEqual((self.signals / "WORK-abc.task-id").read_text(), "7jpabc123")

    def test_cached_id_skips_the_cli(self):
        (self.signals / "WORK-abc.task-id").write_text("7jpabc123\n")
        r = self.run_snippet('nc_task_id WORK-abc')
        self.assertEqual(r.stdout, "7jpabc123")
        self.assertEqual(self.calls(), [])

    def test_unresolvable_id_returns_nonzero_and_prints_nothing(self):
        """
        The sidecar branches on this to stay poll-only rather than subscribing to
        a stream whose frames it could never match.
        """
        self.write_task_list([])
        r = self.run_snippet('nc_task_id WORK-abc; echo "rc=$?"')
        self.assertIn("rc=1", r.stdout)
        self.assertNotIn("7jp", r.stdout)

    def test_addresses_task_show_by_the_full_slug(self):
        """The point of the whole exercise: ambiguity is never hit."""
        self.write_task_list([_task("WORK-abc", "WORK-abc:longid", "7jpabc123")])
        (self.stub_dir / "show.WORK-abc:longid.json").write_text('{"id":"7jpabc123"}')
        self.run_snippet('nc_task_id WORK-abc >/dev/null')
        self.assertIn(
            "task show WORK-abc:longid --json", self.calls(),
            "task show must be addressed by the full slug, never the short one",
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
