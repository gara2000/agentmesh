"""
Unit tests for nc_resolve_profile in notecove-ref.sh.

The profile id is machine-specific, so the order matters:
  a. explicit --profile   b. $AGENTMESH_PROFILE   c. $AGENTMESH_PROFILE_NAME
  (looked up, no default name)   d. the historical id.
A set-but-unresolvable name must FAIL, never fall through to (d).
"""
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).parent
FALLBACK = "kmq9h71tepf95rac2b59xdbsq2"

LISTING = """Available profiles:

  pk6ackk3nx9sz2q86t4syv5j9f
    Name: Work
    Version: 1.4.1

  aaaaaaaaaaaaaaaaaaaaaaaaaa
    Name: Personal
    Version: 1.4.1
"""

STUB = """#!/usr/bin/env bash
echo x >> "$STUB_DIR/calls"
if [ "$1" = profiles ]; then
  [ -n "${STUB_FAIL:-}" ] && exit 1
  cat "$STUB_DIR/listing"
fi
"""


class ResolveProfile(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        d = Path(self.tmp.name)
        (d / "listing").write_text(LISTING)
        stub = d / "notecove"
        stub.write_text(STUB)
        stub.chmod(0o755)
        self.dir = d

    def tearDown(self):
        self.tmp.cleanup()

    def resolve(self, explicit="", listing=None, **env):
        if listing is not None:
            (self.dir / "listing").write_text(listing)
        e = {k: v for k, v in os.environ.items() if not k.startswith("AGENTMESH_")}
        e.update(AGENTMESH_NOTECOVE=str(self.dir / "notecove"), STUB_DIR=str(self.dir), **env)
        r = subprocess.run(
            ["bash", "-c", f'source "{SCRIPTS}/notecove-ref.sh"; nc_resolve_profile "$1"', "_", explicit],
            env=e, capture_output=True, text=True, stdin=subprocess.DEVNULL,
        )
        return r.returncode, r.stdout, r.stderr

    def calls(self):
        p = self.dir / "calls"
        return p.read_text().count("x") if p.exists() else 0

    def test_explicit_wins_over_everything(self):
        rc, out, _ = self.resolve("explicit1", AGENTMESH_PROFILE="envid", AGENTMESH_PROFILE_NAME="Work")
        self.assertEqual((rc, out), (0, "explicit1"))
        self.assertEqual(self.calls(), 0)

    def test_env_id_wins_over_name(self):
        rc, out, _ = self.resolve(AGENTMESH_PROFILE="envid", AGENTMESH_PROFILE_NAME="Work")
        self.assertEqual((rc, out), (0, "envid"))
        self.assertEqual(self.calls(), 0)

    def test_name_is_looked_up_case_insensitively(self):
        rc, out, _ = self.resolve(AGENTMESH_PROFILE_NAME="work")
        self.assertEqual((rc, out), (0, "pk6ackk3nx9sz2q86t4syv5j9f"))

    def test_no_default_name_falls_back_to_historical_id(self):
        rc, out, _ = self.resolve()
        self.assertEqual((rc, out), (0, FALLBACK))
        self.assertEqual(self.calls(), 0)

    def test_unknown_name_fails_instead_of_falling_back(self):
        rc, out, err = self.resolve(AGENTMESH_PROFILE_NAME="Nope")
        self.assertNotEqual(rc, 0)
        self.assertEqual(out, "")
        self.assertIn("did not match exactly one", err)

    def test_ambiguous_name_fails(self):
        dup = LISTING + "\n  bbbbbbbbbbbbbbbbbbbbbbbbbb\n    Name: Work\n    Version: 1.4.1\n"
        rc, out, _ = self.resolve(listing=dup, AGENTMESH_PROFILE_NAME="Work")
        self.assertNotEqual(rc, 0)
        self.assertEqual(out, "")

    def test_cli_failure_fails(self):
        rc, out, err = self.resolve(AGENTMESH_PROFILE_NAME="Work", STUB_FAIL="1")
        self.assertNotEqual(rc, 0)
        self.assertEqual(out, "")
        self.assertIn("failed", err)


if __name__ == "__main__":
    unittest.main()
