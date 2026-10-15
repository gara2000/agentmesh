"""
Unit tests for launcher.py type→agent triage logic.

Tests the TYPE_MAP matching in pick_up_ready_tasks():
- typeId match (e.g. "bug" → implementer)
- typeName-only match (e.g. typeId="chore"/typeName="Investigation" → investigator)
- no usable type → refused, left in Ready, no worker spawned

There is no LLM triage fallback: a task whose type does not resolve through
TYPE_MAP is refused outright rather than being guessed at or defaulted.
"""
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

SCRIPTS = Path(__file__).parent
sys.path.insert(0, str(SCRIPTS))
import launcher as lnch  # noqa: E402


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_task(type_ids: list, type_names: list, slug_short: str = "WORK-abc") -> dict:
    return {
        "slug": {"short": slug_short, "full": f"{slug_short}:longid"},
        "title": f"Test task {slug_short}",
        "typeIds": type_ids,
        "typeNames": type_names,
        "priority": 1,
    }


class TestTriageMapping(unittest.TestCase):
    """_triage() resolves a task's type to an agent type, or None."""

    def setUp(self):
        self.l = lnch.Launcher(project="WORK", max_workers=5,
                               profile="test-profile", poll_interval=30)

    def test_typeids_that_match_directly(self):
        for type_id, expected in lnch.TYPE_MAP.items():
            with self.subTest(type_id=type_id):
                self.assertEqual(self.l._triage(_make_task([type_id], [])), expected)

    def test_typenames_that_match_map_keys(self):
        # typeIds is opaque; the display name is what carries the meaning.
        self.assertEqual(
            self.l._triage(_make_task(["chore"], ["Investigation"])), "investigator"
        )
        self.assertEqual(
            self.l._triage(_make_task(["7f3a-uuid"], ["Plan"])), "planner"
        )

    def test_typeid_takes_priority_over_typename(self):
        self.assertEqual(
            self.l._triage(_make_task(["bug"], ["Documentation"])), "implementer"
        )

    def test_matching_is_case_insensitive(self):
        self.assertEqual(self.l._triage(_make_task(["BUG"], [])), "implementer")
        self.assertEqual(self.l._triage(_make_task([], ["FEATURE"])), "implementer")

    def test_no_type_returns_none(self):
        self.assertIsNone(self.l._triage(_make_task([], [])))

    def test_unmapped_type_returns_none(self):
        """An unmapped type is refused, not defaulted to implementer."""
        self.assertIsNone(self.l._triage(_make_task(["chore"], ["Chore"])))


class TestPickUpReadyTasks(unittest.TestCase):
    """
    Integration-level tests for pick_up_ready_tasks(). I/O (notecove, spawn) is
    patched out so we can inspect which path is taken for each type combination.
    """

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self._signals_patch = patch.object(lnch, "SIGNALS", Path(self._tmp.name))
        self._signals_patch.start()
        self.addCleanup(self._signals_patch.stop)
        self.addCleanup(self._tmp.cleanup)

    def _run(self, tasks: list, live_windows=()):
        """Returns (spawned, refused) where refused is the list of commented slugs."""
        spawned, refused = [], []
        l = lnch.Launcher(project="WORK", max_workers=5,
                          profile="test-profile", poll_interval=30)

        with (
            patch.object(lnch, "run_bash") as mock_rb,
            patch.object(lnch, "notecove") as mock_nc,
            patch.object(l, "_spawn_worker") as mock_sw,
            patch.object(l, "_live_worker_windows", return_value=set(live_windows)),
            patch.object(l, "_write_heartbeat"),
            patch.object(lnch, "log"),
            patch.object(lnch, "_print"),
        ):
            mock_rb.return_value = MagicMock(returncode=0, stdout=json.dumps(tasks))
            mock_sw.side_effect = lambda slug, agent_type: spawned.append((slug, agent_type))
            mock_nc.side_effect = lambda args: refused.append(args) or ""
            l.pick_up_ready_tasks()

        return spawned, refused

    def test_bug_typeid_spawns_implementer(self):
        spawned, refused = self._run([_make_task(["bug"], ["Bug"])])
        self.assertEqual(spawned, [("WORK-abc", "implementer")])
        self.assertEqual(refused, [])

    def test_chore_typeid_with_investigation_typename_spawns_investigator(self):
        spawned, _ = self._run([_make_task(["chore"], ["Investigation"])])
        self.assertEqual(spawned, [("WORK-abc", "investigator")])

    def test_untyped_task_is_refused_and_not_spawned(self):
        spawned, refused = self._run([_make_task([], [])])
        self.assertEqual(spawned, [], "an untyped task must not spawn a worker")
        self.assertEqual(len(refused), 1, "the refusal must be commented exactly once")
        self.assertIn("comments add", refused[0])

    def test_untyped_task_is_left_in_ready(self):
        """The launcher must never move an untriageable task out of Ready."""
        _, refused = self._run([_make_task([], [])])
        self.assertFalse(
            any("--state" in call for call in refused),
            "refusing a task must not change its state",
        )

    def test_unmapped_type_is_refused(self):
        spawned, refused = self._run([_make_task(["chore"], ["Chore"])])
        self.assertEqual(spawned, [])
        self.assertEqual(len(refused), 1)

    def test_refusal_comment_is_deduped(self):
        """The ready-scan repeats every poll; the comment must only be posted once."""
        task = _make_task([], [])
        _, first = self._run([task])
        _, second = self._run([task])
        self.assertEqual(len(first), 1)
        self.assertEqual(second, [], "second scan must not re-comment")

    def test_mixed_batch_spawns_matched_and_refuses_rest(self):
        tasks = [
            _make_task(["bug"], ["Bug"], slug_short="WORK-a"),
            _make_task(["chore"], ["Investigation"], slug_short="WORK-b"),
            _make_task([], [], slug_short="WORK-c"),
        ]
        spawned, refused = self._run(tasks)
        self.assertEqual(
            sorted(spawned), [("WORK-a", "implementer"), ("WORK-b", "investigator")]
        )
        self.assertEqual(len(refused), 1)
        self.assertIn("WORK-c", refused[0])

    def test_launching_flag_blocks_respawn(self):
        """
        The launcher no longer sets Doing, so a task stays Ready while Claude
        boots. The .launching flag is what stops the next scan spawning a second
        worker for it.
        """
        task = _make_task(["bug"], ["Bug"])
        (Path(self._tmp.name) / "WORK-abc.launching").touch()
        spawned, _ = self._run([task])
        self.assertEqual(spawned, [], "a launching task must not be spawned again")

    def test_expired_launching_flag_allows_respawn(self):
        """A worker that died during boot must not wedge the task forever."""
        import os, time
        task = _make_task(["bug"], ["Bug"])
        flag = Path(self._tmp.name) / "WORK-abc.launching"
        flag.touch()
        stale = time.time() - (lnch.LAUNCHING_TIMEOUT_SECS + 60)
        os.utime(flag, (stale, stale))
        spawned, _ = self._run([task])
        self.assertEqual(spawned, [("WORK-abc", "implementer")])


class TestAdoptOrphanedTasks(unittest.TestCase):
    """
    adopt_orphaned_tasks() re-attaches a worker to a Doing/Attention task whose
    worker window is gone.

    Without it, `agentmesh stop && agentmesh start` silently abandons every
    in-flight task: bootstrap truncates signals/workers, the normal scan only
    queries Ready, and the watchdog has no registry entry left to notice.
    """

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self._signals_patch = patch.object(lnch, "SIGNALS", Path(self._tmp.name))
        self._signals_patch.start()
        self.addCleanup(self._signals_patch.stop)
        self.addCleanup(self._tmp.cleanup)

    def _run(self, by_state: dict, live_windows=()):
        """by_state maps state name -> task list. Returns slugs adopted."""
        adopted = []
        l = lnch.Launcher(project="WORK", max_workers=5,
                          profile="test-profile", poll_interval=30)

        with (
            patch.object(l, "_list_tasks", side_effect=lambda s: by_state.get(s, [])),
            patch.object(l, "_live_worker_windows", return_value=set(live_windows)),
            patch.object(l, "_spawn_worker") as mock_sw,
            patch.object(lnch, "log"),
            patch.object(lnch, "_print"),
        ):
            mock_sw.side_effect = lambda slug, agent_type: adopted.append((slug, agent_type))
            l.adopt_orphaned_tasks()

        return adopted

    def test_adopts_doing_task_with_dead_window(self):
        adopted = self._run({"Doing": [_make_task(["bug"], ["Bug"])]})
        self.assertEqual(adopted, [("WORK-abc", "implementer")])

    def test_adopts_attention_task_with_dead_window(self):
        """The pre-refactor Spokesman recovered exactly this case."""
        adopted = self._run({"Attention": [_make_task(["bug"], ["Bug"])]})
        self.assertEqual(adopted, [("WORK-abc", "implementer")])

    def test_skips_task_whose_worker_is_alive(self):
        """Makes the pass safe to run every scan and across launcher restarts."""
        adopted = self._run(
            {"Doing": [_make_task(["bug"], ["Bug"])]}, live_windows=["WORK-abc"]
        )
        self.assertEqual(adopted, [], "a live worker must never be double-spawned")

    def test_skips_task_that_is_still_launching(self):
        """A worker mid-boot has no window yet; the flag is its only evidence."""
        (Path(self._tmp.name) / "WORK-abc.launching").touch()
        adopted = self._run({"Doing": [_make_task(["bug"], ["Bug"])]})
        self.assertEqual(adopted, [], "a booting worker must not be double-spawned")

    def test_skips_task_whose_type_no_longer_maps(self):
        """Without a resolvable type we cannot know which agent owned the work."""
        adopted = self._run({"Doing": [_make_task(["chore"], ["Chore"])]})
        self.assertEqual(adopted, [])

    def test_adopts_across_both_states_in_one_pass(self):
        adopted = self._run({
            "Doing": [_make_task(["bug"], ["Bug"], slug_short="WORK-a")],
            "Attention": [_make_task(["investigation"], ["Investigation"], slug_short="WORK-b")],
        })
        self.assertEqual(
            sorted(adopted), [("WORK-a", "implementer"), ("WORK-b", "investigator")]
        )

    def test_respects_max_workers(self):
        """Adoption draws from the same slot budget as normal pickup."""
        l = lnch.Launcher(project="WORK", max_workers=1,
                          profile="test-profile", poll_interval=30)
        adopted = []
        tasks = [
            _make_task(["bug"], ["Bug"], slug_short="WORK-a"),
            _make_task(["bug"], ["Bug"], slug_short="WORK-b"),
        ]
        with (
            patch.object(l, "_list_tasks", side_effect=lambda s: tasks if s == "Doing" else []),
            patch.object(l, "_live_worker_windows", return_value=set()),
            patch.object(l, "_spawn_worker") as mock_sw,
            patch.object(lnch, "log"),
            patch.object(lnch, "_print"),
        ):
            # Registering consumes the single slot, as the real _spawn_worker does.
            def fake_spawn(slug, agent_type):
                adopted.append(slug)
                l._register_worker(slug, agent_type)
            mock_sw.side_effect = fake_spawn
            l.adopt_orphaned_tasks()

        self.assertEqual(len(adopted), 1, "must not exceed max-workers")


class TestAdoptionGuards(unittest.TestCase):
    """Guards added after the recovery audit found them missing."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self._signals_patch = patch.object(lnch, "SIGNALS", Path(self._tmp.name))
        self._signals_patch.start()
        self.addCleanup(self._signals_patch.stop)
        self.addCleanup(self._tmp.cleanup)

    def _launcher(self):
        return lnch.Launcher(project="WORK", max_workers=5,
                             profile="test-profile", poll_interval=30)

    def test_backoff_sentinel_blocks_adoption(self):
        """
        The watchdog sleeps out a crash backoff with the task still Doing and its
        window gone — adoption's exact trigger. Adopting there makes the watchdog
        tear down the new worker and pickup spawn a second one.
        """
        adopted = []
        l = self._launcher()
        (Path(self._tmp.name) / "WORK-abc.backoff").touch()
        with (
            patch.object(l, "_list_tasks", side_effect=lambda st: [_make_task(["bug"], ["Bug"])] if st == "Doing" else []),
            patch.object(l, "_live_worker_windows", return_value=set()),
            patch.object(l, "_spawn_worker", side_effect=lambda s_, t: adopted.append(s_)),
            patch.object(lnch, "log"), patch.object(lnch, "_print"),
        ):
            l.adopt_orphaned_tasks()
        self.assertEqual(adopted, [], "must not adopt a task the watchdog is backing off")

    def test_tmux_failure_skips_adoption_entirely(self):
        """
        A failed `tmux list-windows` must not read as "no windows" — that would
        respawn a worker for every in-flight task at once.
        """
        adopted = []
        l = self._launcher()
        with (
            patch.object(l, "_list_tasks", side_effect=lambda st: [_make_task(["bug"], ["Bug"])] if st == "Doing" else []),
            patch.object(l, "_live_worker_windows", return_value=None),
            patch.object(l, "_spawn_worker", side_effect=lambda s_, t: adopted.append(s_)),
            patch.object(lnch, "log"), patch.object(lnch, "_print"),
        ):
            l.adopt_orphaned_tasks()
        self.assertEqual(adopted, [], "must skip the cycle rather than mass-adopt")

    def test_failed_spawn_is_not_registered(self):
        """
        spawn-agent.sh refuses duplicate window names and aborts if the window
        dies before the REPL. Registering such a worker burns a slot forever and
        makes the watchdog think an agent is running.
        """
        l = self._launcher()
        with (
            patch.object(lnch.subprocess, "run",
                         return_value=MagicMock(returncode=1, stderr="duplicate window")),
            patch.object(l, "_spawn_sidecar") as mock_side,
            patch.object(lnch, "log"), patch.object(lnch, "_print"),
        ):
            l._spawn_worker("WORK-abc", "implementer")
        self.assertFalse((Path(self._tmp.name) / "workers").exists()
                         and "WORK-abc" in (Path(self._tmp.name) / "workers").read_text(),
                         "a failed spawn must not be registered")
        self.assertFalse((Path(self._tmp.name) / "WORK-abc.launching").exists(),
                         "a failed spawn must release its launching flag")
        mock_side.assert_not_called()


class TestReconcileSidecars(unittest.TestCase):
    """A worker whose sidecar died blocks forever; adoption skips it by design."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self._signals_patch = patch.object(lnch, "SIGNALS", Path(self._tmp.name))
        self._signals_patch.start()
        self.addCleanup(self._signals_patch.stop)
        self.addCleanup(self._tmp.cleanup)

    def _run(self, registry_lines, worker_windows, orchestrator_windows):
        spawned = []
        l = lnch.Launcher(project="WORK", max_workers=5,
                          profile="test-profile", poll_interval=30)
        if registry_lines:
            (Path(self._tmp.name) / "workers").write_text("\n".join(registry_lines) + "\n")

        def fake_run_bash(cmd):
            if "list-windows -t orchestrator" in cmd:
                return MagicMock(returncode=0, stdout="\n".join(orchestrator_windows))
            return MagicMock(returncode=0, stdout="")

        with (
            patch.object(l, "_live_worker_windows", return_value=set(worker_windows)),
            patch.object(lnch, "run_bash", side_effect=fake_run_bash),
            patch.object(l, "_spawn_sidecar", side_effect=lambda s_, h: spawned.append(s_)),
            patch.object(l, "_agent_type_for", return_value="implementer"),
            patch.object(lnch, "log"), patch.object(lnch, "_print"),
        ):
            l.reconcile_sidecars()
        return spawned, l

    def test_respawns_a_missing_sidecar(self):
        spawned, _ = self._run(
            ["WORK-abc WORK-abc implementer"], ["WORK-abc"], ["launcher", "watchdog"]
        )
        self.assertEqual(spawned, ["WORK-abc"])

    def test_leaves_a_healthy_pair_alone(self):
        spawned, _ = self._run(
            ["WORK-abc WORK-abc implementer"], ["WORK-abc"], ["side-WORK-abc"]
        )
        self.assertEqual(spawned, [])

    def test_reregisters_a_live_worker_missing_from_the_registry(self):
        """bootstrap.sh truncates the registry; surviving workers go invisible."""
        spawned, l = self._run([], ["WORK-abc"], ["side-WORK-abc"])
        self.assertIn("WORK-abc", (Path(self._tmp.name) / "workers").read_text())
        self.assertEqual(spawned, [], "its sidecar is alive — only the registry needed fixing")


class TestRegisterWorker(unittest.TestCase):
    """Registry writes must not duplicate a slug.

    Adoption can re-spawn a worker for a slug the registry still lists, since the
    watchdog only reaps stale entries on its next 30s poll. A duplicate line
    would inflate the active count and silently consume a max-workers slot.
    """

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self._signals_patch = patch.object(lnch, "SIGNALS", Path(self._tmp.name))
        self._signals_patch.start()
        self.addCleanup(self._signals_patch.stop)
        self.addCleanup(self._tmp.cleanup)

    def test_reregistering_replaces_rather_than_appends(self):
        l = lnch.Launcher(project="WORK", max_workers=5,
                          profile="test-profile", poll_interval=30)
        l._register_worker("WORK-abc", "implementer")
        l._register_worker("WORK-abc", "implementer")
        lines = (Path(self._tmp.name) / "workers").read_text().strip().splitlines()
        self.assertEqual(lines, ["WORK-abc WORK-abc implementer"])

    def test_distinct_slugs_coexist(self):
        l = lnch.Launcher(project="WORK", max_workers=5,
                          profile="test-profile", poll_interval=30)
        l._register_worker("WORK-a", "implementer")
        l._register_worker("WORK-b", "planner")
        lines = (Path(self._tmp.name) / "workers").read_text().strip().splitlines()
        self.assertEqual(len(lines), 2)
        self.assertEqual(l._free_slots(), 3)


class TestAgentAuthorMap(unittest.TestCase):
    """Every agent TYPE_MAP can spawn must have a comment-author entry.

    The sidecar filters an agent's own comments by author name, so a missing
    entry makes that agent wake itself on every comment it writes.
    """

    def test_every_mapped_agent_has_an_author(self):
        for agent in set(lnch.TYPE_MAP.values()):
            with self.subTest(agent=agent):
                self.assertIn(agent, lnch.AGENT_AUTHOR)


if __name__ == "__main__":
    unittest.main()
