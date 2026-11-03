"""
Unit tests for create_note in agent-notecove.sh.

`notecove note create` has no title argument — the title is the first line of
the content. Every skill template nonetheless passed one:

    notecove note create "<slug>/PLAN" --folder … --content-file - …

and the CLI dropped it silently, so notes were titled after their first heading
("Implementation Plan") instead of `<slug>/PLAN`, which is the name a restarted
worker looks for. create_note writes the title line itself and checks the title
NoteCove actually gave the note.

The stub CLI below behaves like the real one in the way that matters: it ignores
positionals and derives the title from the first content line.
"""
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).parent

NOTECOVE_STUB = r"""#!/usr/bin/env bash
set -uo pipefail
STUB="$STUB_DIR"
printf '%s\n' "$*" >> "$STUB/calls.log"

case "$1 ${2:-}" in
  "note create")
    [ -f "$STUB/fail-create" ] && exit 1
    folder="" file=""
    shift 2
    while [ $# -gt 0 ]; do
      case "$1" in
        --folder) folder="$2"; shift 2 ;;
        --content-file) file="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    # `-` would be stdin, which nc_run closes — record what actually arrived.
    if [ "$file" = "-" ]; then cat > "$STUB/content.md"; else cp "$file" "$STUB/content.md"; fi
    printf '%s' "$folder" > "$STUB/folder.txt"
    STUB="$STUB" python3 -c '
import json, os
stub = os.environ["STUB"]
text = open(os.path.join(stub, "content.md")).read()
first = text.split("\n", 1)[0]
title = first.lstrip("#").strip()
override = os.path.join(stub, "title-override")
if os.path.exists(override):
    title = open(override).read()
print(json.dumps({"id": "note-123", "title": title}))
'
    ;;
  "task show")
    cat "$STUB/show.json"
    ;;
esac
exit 0
"""


class CreateNoteHarness(unittest.TestCase):
    SLUG = "WORK-abc"
    FULL = "WORK-abc:longid"

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)

        self.home = self.root / "home"
        self.mesh = self.home / "agentmesh"
        self.signals = self.mesh / "signals"
        self.scripts = self.mesh / "scripts"
        self.stub_dir = self.root / "stub"
        for d in (self.signals, self.scripts, self.stub_dir):
            d.mkdir(parents=True, exist_ok=True)

        for name in ("agent-notecove.sh", "notecove-ref.sh"):
            (self.scripts / name).write_text((SCRIPTS / name).read_text())

        self.cli = self.root / "nc-stub"
        self.cli.write_text(NOTECOVE_STUB)
        self.cli.chmod(0o755)

        (self.signals / "events.log").touch()
        (self.signals / f"{self.SLUG}.full-slug").write_text(self.FULL)
        # For the TASK_FOLDER_ID fallback: an already-linked task, so
        # ensure_task_folder only reads.
        (self.stub_dir / "show.json").write_text(json.dumps({
            "folderId": "parent",
            "contentJson": {"content": "<paragraph>[[F:linked-fid|P/WORK-abc]]</paragraph>"},
        }))

    def run_snippet(self, snippet, shell="bash", folder_id="task-fid"):
        lines = [
            'export SIGNALS="%s"' % self.signals,
            'export NOTECOVE_BIN="%s"' % self.cli,
            'source "%s"' % (self.scripts / "agent-notecove.sh"),
            'agent_init "%s" "Implementer"' % self.SLUG,
        ]
        if folder_id:
            lines.append('TASK_FOLDER_ID="%s"' % folder_id)
        lines.append(snippet)
        env = dict(os.environ, STUB_DIR=str(self.stub_dir), HOME=str(self.home))
        return subprocess.run([shell, "-c", "\n".join(lines)],
                              capture_output=True, text=True, env=env,
                              stdin=subprocess.DEVNULL)

    def content(self):
        f = self.stub_dir / "content.md"
        return f.read_text() if f.exists() else None

    def folder(self):
        return (self.stub_dir / "folder.txt").read_text()

    def events(self):
        return (self.signals / "events.log").read_text()


PLAN = "create_note \"WORK-abc/PLAN\" << 'EOF'\n**Task:** WORK-abc\n\n## Phase 1\n- step\nEOF\n"


class TestTitle(CreateNoteHarness):
    def test_note_is_titled_with_the_given_title(self):
        r = self.run_snippet(PLAN + 'echo "rc=$? id=$NOTE_ID"')
        self.assertIn("rc=0 id=note-123", r.stdout, r.stderr)
        self.assertTrue(self.content().startswith("# WORK-abc/PLAN\n\n**Task:** WORK-abc"),
                        self.content())
        self.assertIn("- step", self.content())

    def test_prints_the_note_id(self):
        r = self.run_snippet('ID=$(create_note "WORK-abc/PLAN" <<< "body"); echo "id=$ID"')
        self.assertIn("id=note-123", r.stdout, r.stderr)

    def test_a_body_already_carrying_the_title_is_not_doubled(self):
        self.run_snippet("create_note \"WORK-abc/PLAN\" << 'EOF'\n# WORK-abc/PLAN\n\nbody\nEOF\n")
        self.assertEqual(self.content().count("# WORK-abc/PLAN"), 1, self.content())

    def test_a_title_that_did_not_take_is_a_failure(self):
        (self.stub_dir / "title-override").write_text("Implementation Plan")
        r = self.run_snippet(PLAN + 'echo "rc=$?"')
        self.assertIn("rc=1", r.stdout)
        self.assertIn("note-title-mismatch", self.events())
        self.assertIn("note-123", r.stderr + r.stdout)

    def test_empty_body_still_gets_the_title(self):
        r = self.run_snippet('create_note "WORK-abc/COMPLETION" </dev/null; echo "rc=$?"')
        self.assertIn("rc=0", r.stdout, r.stderr)
        self.assertEqual(self.content().strip(), "# WORK-abc/COMPLETION")


class TestTransport(CreateNoteHarness):
    def test_content_goes_through_a_real_file_not_stdin(self):
        # nc_run closes stdin, so `--content-file -` would create an empty note.
        self.run_snippet(PLAN)
        calls = (self.stub_dir / "calls.log").read_text()
        self.assertNotIn("--content-file -", calls)
        self.assertNotIn("WORK-abc/PLAN --folder", calls, "a positional title was passed")

    def test_folder_defaults_to_the_task_folder(self):
        self.run_snippet(PLAN)
        self.assertEqual(self.folder(), "task-fid")

    def test_explicit_folder_wins(self):
        self.run_snippet('create_note "WORK-abc/Context/x" ctx-fid <<< "body"')
        self.assertEqual(self.folder(), "ctx-fid")

    def test_lost_shell_state_recovers_the_task_folder(self):
        self.run_snippet(PLAN, folder_id=None)
        self.assertEqual(self.folder(), "linked-fid")

    def test_cli_failure_is_reported(self):
        (self.stub_dir / "fail-create").touch()
        r = self.run_snippet(PLAN + 'echo "rc=$?"')
        self.assertIn("rc=1", r.stdout)
        self.assertIn("note-create-failed", self.events())


@unittest.skipUnless(shutil.which("zsh"), "zsh not installed")
class TestZsh(CreateNoteHarness):
    # Agents source the helper into the Claude Code Bash tool's shell — zsh on macOS.
    def test_zsh_creates_a_correctly_titled_note(self):
        r = self.run_snippet(PLAN + 'echo "rc=$?"', shell="zsh")
        self.assertIn("rc=0", r.stdout, r.stderr)
        self.assertTrue(self.content().startswith("# WORK-abc/PLAN\n"), self.content())


if __name__ == "__main__":
    unittest.main()
