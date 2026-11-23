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


def _fake_run_bash(list_payload=None, descriptions=None, show_fails=()):
    """A run_bash stand-in: `task show` returns a task with contentText taken
    from descriptions[<short slug>] (default empty); anything else returns
    list_payload as JSON."""
    descriptions = descriptions or {}

    def fake(cmd):
        if " task show " in cmd:
            full = cmd.split(" task show ", 1)[1].split()[0].strip("'")
            short = full.split(":", 1)[0]
            if short in show_fails:
                return MagicMock(returncode=1, stdout="")
            return MagicMock(returncode=0, stdout=json.dumps(
                {"slug": {"short": short, "full": full},
                 "contentText": descriptions.get(short, "")}))
        return MagicMock(returncode=0, stdout=json.dumps(list_payload or []))
    return fake


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

    def _run(self, tasks: list, live_windows=(), descriptions=None, show_fails=(),
             model=None, type_models=None):
        """Returns (spawned, refused) where refused is the list of commented slugs."""
        spawned, refused = [], []
        self.repos = {}
        self.models = {}
        l = lnch.Launcher(project="WORK", max_workers=5,
                          profile="test-profile", poll_interval=30, model=model,
                          type_models=type_models)

        with (
            patch.object(lnch, "run_bash") as mock_rb,
            patch.object(lnch, "notecove") as mock_nc,
            patch.object(l, "_spawn_worker") as mock_sw,
            patch.object(l, "_live_worker_windows", return_value=set(live_windows)),
            patch.object(l, "_write_heartbeat"),
            patch.object(lnch, "log"),
            patch.object(lnch, "_print"),
        ):
            mock_rb.side_effect = _fake_run_bash(tasks, descriptions, show_fails)

            def fake_spawn(slug, agent_type, full_slug="", repo=None, model=None,
                           model_level=""):
                spawned.append((slug, agent_type))
                self.repos[slug] = repo
                self.models[slug] = (model_level, model)
            mock_sw.side_effect = fake_spawn
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

    def _run(self, by_state: dict, live_windows=(), descriptions=None, model=None,
             type_models=None):
        """by_state maps state name -> task list. Returns slugs adopted."""
        adopted = []
        self.repos = {}
        self.models = {}
        l = lnch.Launcher(project="WORK", max_workers=5,
                          profile="test-profile", poll_interval=30, model=model,
                          type_models=type_models)

        with (
            patch.object(lnch, "run_bash", side_effect=_fake_run_bash(descriptions=descriptions)),
            patch.object(lnch, "notecove", return_value=""),
            patch.object(l, "_list_tasks", side_effect=lambda s: by_state.get(s, [])),
            patch.object(l, "_live_worker_windows", return_value=set(live_windows)),
            patch.object(l, "_spawn_worker") as mock_sw,
            patch.object(lnch, "log"),
            patch.object(lnch, "_print"),
        ):
            def fake_spawn(slug, agent_type, full_slug="", repo=None, model=None,
                           model_level=""):
                adopted.append((slug, agent_type))
                self.repos[slug] = repo
                self.models[slug] = (model_level, model)
            mock_sw.side_effect = fake_spawn
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
            patch.object(lnch, "run_bash", side_effect=_fake_run_bash()),
            patch.object(l, "_list_tasks", side_effect=lambda s: tasks if s == "Doing" else []),
            patch.object(l, "_live_worker_windows", return_value=set()),
            patch.object(l, "_spawn_worker") as mock_sw,
            patch.object(lnch, "log"),
            patch.object(lnch, "_print"),
        ):
            # Registering consumes the single slot, as the real _spawn_worker does.
            def fake_spawn(slug, agent_type, full_slug="", repo=None, *_):
                adopted.append(slug)
                l._register_worker(slug, agent_type, full_slug)
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
            patch.object(l, "_spawn_worker",
                         side_effect=lambda s_, t, f_="", r_=None: adopted.append(s_)),
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
            patch.object(l, "_spawn_worker",
                         side_effect=lambda s_, t, f_="", r_=None: adopted.append(s_)),
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


class TestRepoLineParsing(unittest.TestCase):
    """parse_repo_line / resolve_repo — the `Repo: <path>` description line."""

    def test_line_anywhere_in_the_description(self):
        text = "[[F:abc|Server/WORK-x]]\nKind: implement\nRepo: ~/src/app\nMore text"
        self.assertEqual(lnch.parse_repo_line(text), "~/src/app")

    def test_first_line_wins(self):
        self.assertEqual(lnch.parse_repo_line("Repo: /a\nRepo: /b"), "/a")

    def test_no_line(self):
        self.assertIsNone(lnch.parse_repo_line("Kind: implement\nsome Repo: /x mid-line"))
        self.assertIsNone(lnch.parse_repo_line(""))

    def test_trailing_whitespace_is_trimmed(self):
        self.assertEqual(lnch.parse_repo_line("  Repo:   /a b/c  \n"), "/a b/c")

    def test_tilde_is_expanded(self):
        self.assertEqual(lnch.resolve_repo("~/x"), (Path.home() / "x").resolve())

    def test_relative_resolves_against_home(self):
        self.assertEqual(lnch.resolve_repo("work/app"), (Path.home() / "work/app").resolve())

    def test_absolute_is_kept(self):
        self.assertEqual(lnch.resolve_repo("/tmp"), Path("/tmp").resolve())


class TestRepoLinePickup(unittest.TestCase):
    """pick_up_ready_tasks / adopt_orphaned_tasks honour the Repo: line."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)
        self.signals = self.root / "signals"
        self.signals.mkdir()
        self.repo = self.root / "app"
        self.repo.mkdir()
        p = patch.object(lnch, "SIGNALS", self.signals)
        p.start()
        self.addCleanup(p.stop)

    def _pickup(self, descriptions, show_fails=()):
        h = TestPickUpReadyTasks()
        h._tmp = self._tmp
        out = h._run([_make_task(["bug"], ["Bug"])], descriptions=descriptions,
                     show_fails=show_fails)
        return out, h.repos

    def test_repo_line_becomes_the_workdir(self):
        (spawned, _), repos = self._pickup({"WORK-abc": f"[[F:x|y]]\nRepo: {self.repo}"})
        self.assertEqual(spawned, [("WORK-abc", "implementer")])
        self.assertEqual(repos["WORK-abc"], self.repo.resolve())

    def test_no_repo_line_defaults_to_agentmesh(self):
        (spawned, _), repos = self._pickup({"WORK-abc": "Kind: implement"})
        self.assertEqual(spawned, [("WORK-abc", "implementer")])
        self.assertEqual(repos["WORK-abc"], lnch.AGENTMESH.resolve())

    def test_missing_directory_is_refused_once(self):
        desc = {"WORK-abc": f"Repo: {self.root / 'nope'}"}
        (spawned, refused), _ = self._pickup(desc)
        self.assertEqual(spawned, [], "a missing repo must not spawn a worker")
        self.assertEqual(len(refused), 1)
        self.assertIn("comments add", refused[0])
        self.assertNotIn("--state", refused[0], "refusal must not change state")
        (spawned, refused), _ = self._pickup(desc)
        self.assertEqual((spawned, refused), ([], []), "the comment is deduped")

    def test_fixing_the_line_makes_it_eligible_and_clears_the_flag(self):
        self._pickup({"WORK-abc": f"Repo: {self.root / 'nope'}"})
        self.assertTrue((self.signals / "WORK-abc.repo-missing").exists())
        (spawned, _), _ = self._pickup({"WORK-abc": f"Repo: {self.repo}"})
        self.assertEqual(spawned, [("WORK-abc", "implementer")])
        self.assertFalse((self.signals / "WORK-abc.repo-missing").exists())

    def test_unreadable_description_skips_rather_than_defaulting(self):
        """Falling back to AGENTMESH on doubt would start it in the wrong repo."""
        (spawned, refused), _ = self._pickup({}, show_fails=("WORK-abc",))
        self.assertEqual((spawned, refused), ([], []))

    def test_adoption_honours_the_repo_line(self):
        h = TestAdoptOrphanedTasks()
        h._tmp = self._tmp
        adopted = h._run({"Doing": [_make_task(["bug"], ["Bug"])]},
                         descriptions={"WORK-abc": f"Repo: {self.repo}"})
        self.assertEqual(adopted, [("WORK-abc", "implementer")])
        self.assertEqual(h.repos["WORK-abc"], self.repo.resolve())

    def test_adoption_skips_a_missing_repo(self):
        h = TestAdoptOrphanedTasks()
        h._tmp = self._tmp
        adopted = h._run({"Doing": [_make_task(["bug"], ["Bug"])]},
                         descriptions={"WORK-abc": f"Repo: {self.root / 'nope'}"})
        self.assertEqual(adopted, [])

    def test_spawn_passes_the_repo_and_records_it(self):
        l = lnch.Launcher(project="WORK", max_workers=5,
                          profile="test-profile", poll_interval=30)
        with (
            patch.object(lnch.subprocess, "run",
                         return_value=MagicMock(returncode=0, stderr="")) as mock_run,
            patch.object(l, "_spawn_sidecar"),
            patch.object(lnch, "log"), patch.object(lnch, "_print"),
        ):
            l._spawn_worker("WORK-abc", "implementer", "WORK-abc:longid", self.repo)
        argv = mock_run.call_args[0][0]
        self.assertEqual(argv[-1], str(self.repo), "spawn-agent.sh gets the repo as its 6th arg")
        self.assertEqual((self.signals / "WORK-abc.repo").read_text().strip(), str(self.repo))

    def test_spawn_without_repo_uses_agentmesh(self):
        l = lnch.Launcher(project="WORK", max_workers=5,
                          profile="test-profile", poll_interval=30)
        with (
            patch.object(lnch.subprocess, "run",
                         return_value=MagicMock(returncode=0, stderr="")) as mock_run,
            patch.object(l, "_spawn_sidecar"),
            patch.object(lnch, "log"), patch.object(lnch, "_print"),
        ):
            l._spawn_worker("WORK-abc", "implementer")
        self.assertEqual(mock_run.call_args[0][0][-1], str(lnch.AGENTMESH.resolve()))


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


class TestReconcilePrMonitors(unittest.TestCase):
    """A live worker with an open PR must have a pr-monitor, or a merge is never seen."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.signals = Path(self._tmp.name)
        self._signals_patch = patch.object(lnch, "SIGNALS", self.signals)
        self._signals_patch.start()
        self.addCleanup(self._signals_patch.stop)
        self.addCleanup(self._tmp.cleanup)

    def _run(self, worker_windows, orchestrator_windows):
        l = lnch.Launcher(project="WORK", max_workers=5,
                          profile="test-profile", poll_interval=30)
        fake = MagicMock(returncode=0, stdout="\n".join(orchestrator_windows))
        with (
            patch.object(l, "_live_worker_windows", return_value=set(worker_windows)),
            patch.object(lnch, "run_bash", return_value=fake),
            patch.object(lnch, "tmux", return_value=MagicMock(returncode=0)) as mock_tmux,
            patch.object(lnch, "log"), patch.object(lnch, "_print"),
        ):
            l.reconcile_pr_monitors()
        return [c.args[0] for c in mock_tmux.call_args_list]

    def test_respawns_a_missing_monitor_for_an_open_pr(self):
        (self.signals / "WORK-abc.prs").write_text("https://github.com/o/r/pull/1\n")
        calls = self._run(["WORK-abc"], ["side-WORK-abc"])
        self.assertEqual(len(calls), 1)
        self.assertIn("-n pr-mon-WORK-abc", calls[0])
        self.assertIn("pr-monitor.sh WORK-abc", calls[0])

    def test_leaves_a_running_monitor_alone(self):
        (self.signals / "WORK-abc.prs").write_text("https://github.com/o/r/pull/1\n")
        self.assertEqual(self._run(["WORK-abc"], ["pr-mon-WORK-abc"]), [])

    def test_no_monitor_without_prs(self):
        self.assertEqual(self._run(["WORK-abc"], []), [])

    def test_no_monitor_once_every_pr_is_resolved(self):
        """The monitor exits on purpose after the merge; respawning it would re-report."""
        (self.signals / "WORK-abc.prs").write_text(
            "https://github.com/o/r/pull/1\nhttps://github.com/o/r/pull/2\n")
        (self.signals / "WORK-abc.merged").write_text("https://github.com/o/r/pull/1\n")
        (self.signals / "WORK-abc.pr-closed").write_text("https://github.com/o/r/pull/2\n")
        self.assertEqual(self._run(["WORK-abc"], []), [])

    def test_partially_merged_still_needs_a_monitor(self):
        (self.signals / "WORK-abc.prs").write_text(
            "https://github.com/o/r/pull/1\nhttps://github.com/o/r/pull/2\n")
        (self.signals / "WORK-abc.merged").write_text("https://github.com/o/r/pull/1\n")
        self.assertEqual(len(self._run(["WORK-abc"], [])), 1)

    def test_no_monitor_for_a_dead_worker(self):
        """Adoption brings the worker back first; the next scan pairs it."""
        (self.signals / "WORK-abc.prs").write_text("https://github.com/o/r/pull/1\n")
        self.assertEqual(self._run([], []), [])


class TestSidecarHandleReconciliation(unittest.TestCase):
    """A reused sidecar must be filtering on the current agent's author name.

    Adoption can respawn a worker of a different type than the one that stranded.
    A stale handle makes the new agent's own comments look foreign, so it wakes
    itself on every comment it writes — a runaway.
    """

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self._signals_patch = patch.object(lnch, "SIGNALS", Path(self._tmp.name))
        self._signals_patch.start()
        self.addCleanup(self._signals_patch.stop)
        self.addCleanup(self._tmp.cleanup)
        self.l = lnch.Launcher(project="WORK", max_workers=5,
                               profile="test-profile", poll_interval=30)

    def _spawn(self, agent_handle, sidecar_running, recorded_handle=None):
        """Returns (killed, created) tmux calls."""
        calls = []
        if recorded_handle is not None:
            (Path(self._tmp.name) / "WORK-abc.sidecar-handle").write_text(recorded_handle)

        def fake_run_bash(cmd):
            return MagicMock(returncode=0 if sidecar_running else 1, stdout="")

        with (
            patch.object(lnch, "run_bash", side_effect=fake_run_bash),
            patch.object(lnch, "tmux", side_effect=lambda a: calls.append(a) or MagicMock(returncode=0)),
            patch.object(lnch.time, "sleep"),
            patch.object(lnch, "log"), patch.object(lnch, "_print"),
        ):
            self.l._spawn_sidecar("WORK-abc", agent_handle)
        return [c for c in calls if "kill-window" in c], [c for c in calls if "new-window" in c]

    def test_reuses_sidecar_when_handle_matches(self):
        killed, created = self._spawn("implementer", True, recorded_handle="Implementer")
        self.assertEqual(killed, [], "a correctly-configured sidecar must be left alone")
        self.assertEqual(created, [], "and must not be duplicated")

    def test_respawns_sidecar_when_handle_changed(self):
        killed, created = self._spawn("investigator", True, recorded_handle="Implementer")
        self.assertEqual(len(killed), 1, "a stale-handle sidecar must be killed")
        self.assertEqual(len(created), 1, "and replaced")

    def test_respawns_sidecar_when_handle_unknown(self):
        """No record means we cannot prove it is correct — replace it."""
        killed, created = self._spawn("implementer", True, recorded_handle=None)
        self.assertEqual(len(killed), 1)
        self.assertEqual(len(created), 1)

    def test_records_handle_on_spawn(self):
        self._spawn("implementer", False)
        self.assertEqual(
            (Path(self._tmp.name) / "WORK-abc.sidecar-handle").read_text(), "Implementer"
        )


class TestHeartbeatSemantics(unittest.TestCase):
    """The heartbeat must mean "a scan completed", not "a process started".

    A separate heartbeat thread (or a stamp at startup) let a launcher
    crash-looping every 5s keep the file perpetually fresh, so `agentmesh status`
    reported it healthy while nothing was ever picked up.
    """

    def test_no_background_heartbeat_thread_exists(self):
        self.assertFalse(
            hasattr(lnch.Launcher, "_heartbeat_loop"),
            "a background heartbeat thread would report a dead launcher as healthy",
        )

    def test_pickup_does_not_stamp_the_heartbeat(self):
        import inspect
        src = inspect.getsource(lnch.Launcher.pick_up_ready_tasks)
        self.assertNotIn(
            "_write_heartbeat", src,
            "only the completed-scan path may stamp the heartbeat",
        )

    def test_run_loop_stamps_after_the_scan(self):
        import inspect
        src = inspect.getsource(lnch.Launcher.run)
        self.assertIn("_write_heartbeat", src)
        self.assertLess(
            src.index("pick_up_ready_tasks"), src.index("self._write_heartbeat()"),
            "the stamp must follow the scan, not precede it",
        )


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


# ---------------------------------------------------------------------------
# Per-task model (A1)
# ---------------------------------------------------------------------------

class TestResolveModel(unittest.TestCase):
    """resolve_model: task line > type (--type-model) > global (--model) > none."""

    TYPES = {"implementer": "opus"}

    def test_task_line_beats_type_and_global(self):
        self.assertEqual(
            lnch.resolve_model("[[F:x|y]]\nModel: sonnet", "implementer", "haiku", self.TYPES),
            ("task", "sonnet"))

    def test_type_beats_global(self):
        self.assertEqual(
            lnch.resolve_model("no line here", "implementer", "haiku", self.TYPES),
            ("type", "opus"))

    def test_type_applies_only_to_its_type(self):
        self.assertEqual(lnch.resolve_model("", "documenter", "haiku", self.TYPES),
                         ("global", "haiku"))

    def test_nothing_set_means_no_model(self):
        self.assertEqual(lnch.resolve_model("Repo: ~/x", "implementer", None, {}),
                         ("default", None))

    def test_launcher_ignores_its_own_environment(self):
        """The tmux server's env can be stale; bootstrap's arguments are the truth."""
        with patch.dict(lnch.os.environ, {"AGENTMESH_MODEL": "haiku",
                                          "AGENTMESH_MODEL_IMPLEMENTER": "opus"}):
            self.assertEqual(lnch.resolve_model("", "implementer"), ("default", None))

    def test_empty_values_are_ignored(self):
        self.assertEqual(lnch.resolve_model("Model:   ", "implementer", " ", {"implementer": ""}),
                         ("default", None))

    def test_hyphenated_handle_maps_to_underscored_env(self):
        self.assertEqual(lnch.model_env_var("skill-creator"), "AGENTMESH_MODEL_SKILL_CREATOR")
        self.assertEqual(lnch.resolve_model("", "skill-creator", None, {"skill-creator": "opus"}),
                         ("type", "opus"))

    def test_type_model_arguments(self):
        self.assertEqual(lnch.parse_type_models(["implementer=opus", "Skill-Creator=claude-x"]),
                         {"implementer": "opus", "skill-creator": "claude-x"})
        with self.assertRaises(ValueError):
            lnch.parse_type_models(["implementer"])

    def test_shares_the_repo_line_reader(self):
        text = "**Kind:** x\nRepo: ~/app\nModel: opus\n"
        self.assertEqual(lnch.parse_description_line(text, "Model"), "opus")
        self.assertEqual(lnch.parse_description_line(text, "Repo"), lnch.parse_repo_line(text))

    def test_value_is_passed_through_unvalidated(self):
        self.assertEqual(lnch.resolve_model("Model: something-new-9", "implementer", None, {}),
                         ("task", "something-new-9"))


class TestModelPickup(unittest.TestCase):
    """pick_up_ready_tasks / adopt_orphaned_tasks hand the resolved model on."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.signals = Path(self._tmp.name)
        p = patch.object(lnch, "SIGNALS", self.signals)
        p.start()
        self.addCleanup(p.stop)

    def _pickup(self, tasks, descriptions=None, model=None, type_models=None):
        h = TestPickUpReadyTasks()
        h._tmp = self._tmp
        spawned, refused = h._run(tasks, descriptions=descriptions, model=model,
                                  type_models=type_models)
        return spawned, refused, h.models

    def test_task_line_reaches_the_spawn(self):
        _, _, models = self._pickup([_make_task(["bug"], [])], {"WORK-abc": "Model: sonnet"},
                                    model="haiku", type_models={"implementer": "opus"})
        self.assertEqual(models["WORK-abc"], ("task", "sonnet"))

    def test_type_model_applies_to_implementers_only(self):
        tasks = [_make_task(["bug"], [], "WORK-a"), _make_task(["documentation"], [], "WORK-b")]
        spawned, _, models = self._pickup(tasks, type_models={"implementer": "opus"})
        self.assertEqual(len(spawned), 2)
        self.assertEqual(models["WORK-a"], ("type", "opus"))
        self.assertEqual(models["WORK-b"], ("default", None))

    def test_global_flag_is_the_fallback(self):
        _, _, models = self._pickup([_make_task(["bug"], [])], model="haiku")
        self.assertEqual(models["WORK-abc"], ("global", "haiku"))

    def test_no_setting_spawns_without_a_model(self):
        _, _, models = self._pickup([_make_task(["bug"], [])])
        self.assertEqual(models["WORK-abc"], ("default", None))

    def test_adoption_resolves_the_model_too(self):
        h = TestAdoptOrphanedTasks()
        h._tmp = self._tmp
        h._run({"Attention": [_make_task(["bug"], [])]},
               descriptions={"WORK-abc": "Model: opus"})
        self.assertEqual(h.models["WORK-abc"], ("task", "opus"))

    def test_resolution_is_logged_per_spawn(self):
        logged = []
        h = TestPickUpReadyTasks()
        h._tmp = self._tmp
        with patch.object(lnch, "log", side_effect=lambda c, e, s="-": logged.append((e, s))):
            # _run patches log itself; patch _print-free path by calling directly.
            l = lnch.Launcher(project="WORK", max_workers=5, profile="p", poll_interval=30)
            with (
                patch.object(lnch, "run_bash",
                             side_effect=_fake_run_bash([_make_task(["bug"], [])],
                                                        {"WORK-abc": "Model: sonnet"})),
                patch.object(l, "_spawn_worker"),
                patch.object(l, "_live_worker_windows", return_value=set()),
                patch.object(lnch, "_print"),
            ):
                l.pick_up_ready_tasks()
        self.assertIn(("model-resolved:task:sonnet", "WORK-abc"), logged)


class TestModelSpawnAndRegistry(unittest.TestCase):

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.signals = Path(self._tmp.name)
        p = patch.object(lnch, "SIGNALS", self.signals)
        p.start()
        self.addCleanup(p.stop)
        self.l = lnch.Launcher(project="WORK", max_workers=5, profile="p", poll_interval=30)

    def _spawn(self, model, rc=0, full_slug="WORK-abc:longid"):
        comments = []
        with (
            patch.object(lnch.subprocess, "run",
                         return_value=MagicMock(returncode=rc, stderr="")) as mock_run,
            patch.object(self.l, "_spawn_sidecar"),
            patch.object(lnch, "notecove", side_effect=lambda a: comments.append(a) or ""),
            patch.object(lnch, "log"), patch.object(lnch, "_print"),
        ):
            self.l._spawn_worker("WORK-abc", "implementer", full_slug, None, model, "task")
        return mock_run.call_args[0][0], comments

    def registry(self):
        p = self.signals / "workers"
        return p.read_text().strip().splitlines() if p.exists() else []

    def test_model_is_the_seventh_argument(self):
        argv, _ = self._spawn("sonnet")
        self.assertEqual(argv[-2:], [str(lnch.AGENTMESH.resolve()), "sonnet"])

    def test_no_model_no_seventh_argument(self):
        argv, _ = self._spawn(None)
        self.assertEqual(argv[-1], str(lnch.AGENTMESH.resolve()))

    def test_registry_records_the_model_as_fifth_field(self):
        self._spawn("opus")
        self.assertEqual(self.registry(), ["WORK-abc WORK-abc implementer WORK-abc:longid opus"])

    def test_registry_keeps_the_model_positional_without_a_full_slug(self):
        self._spawn("opus", full_slug="")
        self.assertEqual(self.registry(), ["WORK-abc WORK-abc implementer - opus"])

    def test_registry_without_model_is_unchanged(self):
        self._spawn(None)
        self.assertEqual(self.registry(), ["WORK-abc WORK-abc implementer WORK-abc:longid"])

    def test_rejected_model_is_recorded_commented_and_not_registered(self):
        _, comments = self._spawn("bogus", rc=3)
        self.assertEqual(self.registry(), [])
        self.assertFalse((self.signals / "WORK-abc.launching").exists())
        self.assertEqual((self.signals / "WORK-abc.model-rejected").read_text().strip(), "bogus")
        self.assertEqual(len(comments), 1)
        self.assertIn("bogus", comments[0])
        self.assertNotIn("--state", comments[0])

    def test_rejected_model_refuses_pickup_until_it_changes(self):
        (self.signals / "WORK-abc.model-rejected").write_text("bogus\n")
        h = TestPickUpReadyTasks()
        h._tmp = self._tmp
        spawned, refused = h._run([_make_task(["bug"], [])], descriptions={"WORK-abc": "Model: bogus"})
        self.assertEqual((spawned, refused), ([], []), "same value: no spawn, no new comment")
        spawned, _ = h._run([_make_task(["bug"], [])], descriptions={"WORK-abc": "Model: sonnet"})
        self.assertEqual(spawned, [("WORK-abc", "implementer")])
        self.assertFalse((self.signals / "WORK-abc.model-rejected").exists())

    def test_removing_the_model_clears_the_rejection(self):
        (self.signals / "WORK-abc.model-rejected").write_text("bogus\n")
        h = TestPickUpReadyTasks()
        h._tmp = self._tmp
        spawned, _ = h._run([_make_task(["bug"], [])], descriptions={"WORK-abc": "no line"})
        self.assertEqual(spawned, [("WORK-abc", "implementer")])

    def test_rejected_model_blocks_adoption_too(self):
        (self.signals / "WORK-abc.model-rejected").write_text("bogus\n")
        h = TestAdoptOrphanedTasks()
        h._tmp = self._tmp
        adopted = h._run({"Doing": [_make_task(["bug"], [])]},
                         descriptions={"WORK-abc": "Model: bogus"})
        self.assertEqual(adopted, [])


if __name__ == "__main__":
    unittest.main()
