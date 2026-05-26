"""
Unit tests for orchestrator.py type→agent triage logic.

Tests the TYPE_MAP matching in pick_up_ready_tasks():
- typeId match (e.g. "bug" → implementer)
- typeName-only match (e.g. typeId="chore"/typeName="Investigation" → investigator)
- no match (forwarded to spokesman)
"""
import sys
import types
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch, call

# ---------------------------------------------------------------------------
# Minimal import shim so orchestrator.py can be imported without
# the full runtime environment (yaml, anomaly_checks, real filesystem).
# ---------------------------------------------------------------------------

# Stub out anomaly_checks before importing orchestrator
anomaly_stub = types.ModuleType("anomaly_checks")
anomaly_stub.AnomalyChecker = MagicMock()
sys.modules["anomaly_checks"] = anomaly_stub

# Stub out yaml (used by _load_valid_events)
yaml_stub = types.ModuleType("yaml")
yaml_stub.safe_load = lambda f: {"events": {}}
sys.modules["yaml"] = yaml_stub

SCRIPTS = Path(__file__).parent
sys.path.insert(0, str(SCRIPTS))
import orchestrator as orch  # noqa: E402


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_task(type_ids: list, type_names: list, slug_short: str = "WORK-abc") -> dict:
    return {
        "typeIds": type_ids,
        "typeNames": type_names,
        "title": f"Test task {slug_short}",
        "priority": 3,
        "slug": {
            "short": slug_short,
            "full": f"{slug_short}:uniqueid123",
        },
    }


class TestTypeMapLookup(unittest.TestCase):
    """Verify TYPE_MAP entries cover all expected type names / IDs."""

    def test_typeids_that_match_directly(self):
        """typeIds that exactly match TYPE_MAP keys are resolved without typeName fallback."""
        for type_id, expected_agent in [
            ("bug", "implementer"),
            ("feature", "implementer"),
            ("plan", "planner"),
            ("brainstorming", "brainstormer"),
            ("documentation", "documenter"),
            ("design", "designer"),
            ("investigation", "investigator"),
        ]:
            with self.subTest(type_id=type_id):
                result = next(
                    (orch.TYPE_MAP[t.lower()] for t in [type_id] if t.lower() in orch.TYPE_MAP),
                    None,
                )
                self.assertEqual(result, expected_agent)

    def test_typenames_that_match_map_keys(self):
        """typeNames from the actual NoteCove project resolve via TYPE_MAP keys."""
        for type_name, expected_agent in [
            ("Bug", "implementer"),
            ("Feature", "implementer"),
            ("Investigation", "investigator"),  # typeId is "chore" — won't match by ID
            ("Plan", "planner"),               # typeId is a UUID — won't match by ID
            ("Brainstorming", "brainstormer"), # typeId is a UUID — won't match by ID
        ]:
            with self.subTest(type_name=type_name):
                result = next(
                    (orch.TYPE_MAP[n.lower()] for n in [type_name] if n.lower() in orch.TYPE_MAP),
                    None,
                )
                self.assertEqual(result, expected_agent)


class TestPickUpReadyTasksTriage(unittest.TestCase):
    """
    Integration-level tests for the triage branch inside pick_up_ready_tasks().
    We patch away I/O (notecove, spawn, tmux signals) and inspect which path
    (direct-spawn vs spokesman-forward) is taken for different typeId/typeName combos.
    """

    def _make_orchestrator(self):
        o = orch.Orchestrator(
            project="WORK", mode="standard", max_workers=5,
            profile="test-profile", review_limit=3,
        )
        return o

    def _run_triage(self, tasks: list):
        """
        Run pick_up_ready_tasks() with a mocked task list and capture:
        - spawned: list of (slug, agent_type)
        - forwarded: list of slugs forwarded to spokesman
        - spokesman_signalled: bool
        """
        spawned = []
        forwarded = []
        spokesman_signalled = []

        o = self._make_orchestrator()

        with (
            patch.object(orch, "run_bash") as mock_rb,
            patch.object(orch, "notecove") as mock_nc,
            patch.object(orch, "append_spokesman_queue") as mock_sq,
            patch.object(orch, "tmux_signal") as mock_ts,
            patch.object(o, "_spawn_worker") as mock_sw,
            patch.object(o, "_maybe_shutdown"),
            patch.object(orch, "log"),
        ):
            # task list returns our tasks
            mock_rb.return_value = MagicMock(returncode=0, stdout=__import__("json").dumps(tasks))

            # workers file: empty (no active workers)
            o._in_flight.clear()

            mock_sw.side_effect = lambda slug, agent_type: spawned.append((slug, agent_type))
            mock_sq.side_effect = lambda slug, event: forwarded.append(slug)
            mock_ts.side_effect = lambda sig: spokesman_signalled.append(sig)

            o.pick_up_ready_tasks()

        return spawned, forwarded, any(s == "spokesman-event" for s in spokesman_signalled)

    def test_bug_typeid_spawns_implementer_directly(self):
        tasks = [_make_task(["bug"], ["Bug"])]
        spawned, forwarded, sig = self._run_triage(tasks)
        self.assertEqual(spawned, [("WORK-abc", "implementer")])
        self.assertNotIn("WORK-abc", forwarded)
        self.assertFalse(sig, "spokesman-event should NOT fire when typeId matched directly")

    def test_feature_typeid_spawns_implementer_directly(self):
        tasks = [_make_task(["feature"], ["Feature"])]
        spawned, forwarded, sig = self._run_triage(tasks)
        self.assertEqual(spawned, [("WORK-abc", "implementer")])
        self.assertFalse(sig)

    def test_chore_typeid_with_investigation_typename_spawns_investigator(self):
        """Real-world case: typeId='chore', typeName='Investigation'."""
        tasks = [_make_task(["chore"], ["Investigation"])]
        spawned, forwarded, sig = self._run_triage(tasks)
        self.assertEqual(spawned, [("WORK-abc", "investigator")])
        self.assertNotIn("WORK-abc", forwarded)
        self.assertFalse(sig)

    def test_uuid_typeid_with_plan_typename_spawns_planner(self):
        """Real-world case: typeId=UUID, typeName='Plan'."""
        tasks = [_make_task(["s016tmt5yt57enbm2pp71ah734"], ["Plan"])]
        spawned, forwarded, sig = self._run_triage(tasks)
        self.assertEqual(spawned, [("WORK-abc", "planner")])
        self.assertNotIn("WORK-abc", forwarded)
        self.assertFalse(sig)

    def test_uuid_typeid_with_brainstorming_typename_spawns_brainstormer(self):
        """Real-world case: typeId=UUID, typeName='Brainstorming'."""
        tasks = [_make_task(["t1wxdcdv6af13mezkwzgyss5k6"], ["Brainstorming"])]
        spawned, forwarded, sig = self._run_triage(tasks)
        self.assertEqual(spawned, [("WORK-abc", "brainstormer")])
        self.assertFalse(sig)

    def test_unknown_type_forwarded_to_spokesman(self):
        """Tasks with no matching typeId or typeName go to spokesman for LLM triage."""
        tasks = [_make_task([], [], slug_short="WORK-xyz")]
        spawned, forwarded, sig = self._run_triage(tasks)
        self.assertEqual(spawned, [])
        self.assertIn("WORK-xyz", forwarded)
        self.assertTrue(sig, "spokesman-event must fire when a task is forwarded")

    def test_typeid_takes_priority_over_typename(self):
        """If typeId matches, typeName fallback is not used (no double-match side effects)."""
        tasks = [_make_task(["bug"], ["Investigation"])]  # conflicting names
        spawned, forwarded, sig = self._run_triage(tasks)
        # typeId "bug" wins → implementer, not investigator
        self.assertEqual(spawned, [("WORK-abc", "implementer")])

    def test_mixed_batch_some_matched_some_forwarded(self):
        """Mix of known-type and unknown-type tasks in one pick_up cycle."""
        tasks = [
            _make_task(["bug"], ["Bug"], slug_short="WORK-a"),
            _make_task(["chore"], ["Investigation"], slug_short="WORK-b"),
            _make_task([], [], slug_short="WORK-c"),  # no type → spokesman
        ]
        spawned, forwarded, sig = self._run_triage(tasks)
        self.assertIn(("WORK-a", "implementer"), spawned)
        self.assertIn(("WORK-b", "investigator"), spawned)
        self.assertIn("WORK-c", forwarded)
        self.assertTrue(sig)


if __name__ == "__main__":
    unittest.main()
