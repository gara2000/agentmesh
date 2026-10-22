"""
Unit tests for ensure_task_folder in agent-notecove.sh.

Linking a task to its folder used to be a ~20-line recipe pasted into every
implementer-family skill, which each agent retyped by hand. Its failure branch
was:

    EXISTING_DESC=$(notecove task show <slug> --format markdown | …split…)
    if [ -n "$EXISTING_DESC" ]; then  …prepend…
    else  notecove task change <slug> --content "[[F:…]]"   # replaces EVERYTHING
    fi

EXISTING_DESC goes empty for two unrelated reasons — the description really is
empty, and the read failed — and both took the destructive branch. A survey of
the 96 live tasks that had a task folder found 2 with no link at all and 2
reduced to nothing but the link.

The regression that matters most is test_failed_read_writes_nothing: on any
doubt the helper must write nothing rather than guess that the description was
empty. The rest pin the behaviour around it — idempotence for restarted
workers, body preservation, and the post-write verification.

Everything is driven through a stub CLI on PATH, so the assertions are about
what actually reaches NoteCove.
"""
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).parent

# Stub NoteCove CLI. Records every call, serves the task/folder fixtures, and
# applies a `task change` to show.json so the helper's verification step has
# something real to read back.
NOTECOVE_STUB = r"""#!/usr/bin/env bash
set -uo pipefail
STUB="$STUB_DIR"
printf '%s\n' "$*" >> "$STUB/calls.log"

case "$1 ${2:-}" in
  "task show")
    if printf '%s ' "$@" | grep -q -- '--format markdown'; then
      [ -f "$STUB/fail-show-md" ] && exit 1
      cat "$STUB/show.md" 2>/dev/null
    else
      [ -f "$STUB/fail-show" ] && exit 1
      cat "$STUB/show.json" 2>/dev/null
    fi
    ;;
  "folder list")
    [ -f "$STUB/fail-folder-list" ] && exit 1
    cat "$STUB/folders.json" 2>/dev/null
    ;;
  "folder create")
    [ -f "$STUB/fail-folder-create" ] && exit 1
    printf '%s\n' "$3" >> "$STUB/created-folders.log"
    printf '{"id":"new-folder-id","name":"%s"}\n' "$3"
    ;;
  "task change")
    [ -f "$STUB/fail-change" ] && exit 1
    content=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --content-file) content=$(cat "$2"); shift 2 ;;
        --content) content="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    printf '%s' "$content" > "$STUB/written.txt"
    # Apply the write so the verify step reads back something real. The stored
    # form wraps each block in <paragraph>, which is enough for the helper's
    # "link present and nothing shrank" check.
    STUB="$STUB" python3 -c '
import json, os, sys
stub = os.environ["STUB"]
text = open(os.path.join(stub, "written.txt")).read()
body = "".join("<paragraph>%s</paragraph>" % b for b in text.split("\n\n") if b.strip())
p = os.path.join(stub, "show.json")
d = json.load(open(p))
d.setdefault("contentJson", {})["content"] = body
json.dump(d, open(p, "w"))
'
    ;;
esac
exit 0
"""


class FolderLinkHarness(unittest.TestCase):
    SLUG = "WORK-abc"
    FULL = "WORK-abc:longid"
    PARENT = "parent-fid"

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)

        # agent-notecove.sh hardcodes ~/agentmesh/..., so HOME is the fake repo's
        # parent and the scripts are copied in beside it.
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

        self.set_task(content="<paragraph>repo: ~/agentmesh</paragraph>",
                      markdown="repo: ~/agentmesh")
        self.set_folders([
            {"id": self.PARENT, "name": "AI & Agents", "parentId": None,
             "path": "AI & Agents"},
        ])

    # --- fixtures -------------------------------------------------------
    def set_task(self, content, markdown, folder_id=None):
        (self.stub_dir / "show.json").write_text(json.dumps({
            "folderId": self.PARENT if folder_id is None else folder_id,
            "contentJson": {"content": content},
        }))
        header = (
            "\nSome Task Title\n\nSlug: %s\n\nState:    Doing\n" % self.FULL
        )
        if markdown is None:
            (self.stub_dir / "show.md").write_text(header)
        else:
            (self.stub_dir / "show.md").write_text(header + "\nDescription:\n" + markdown + "\n")

    def set_folders(self, folders):
        (self.stub_dir / "folders.json").write_text(json.dumps(folders))

    def fail_call(self, what):
        (self.stub_dir / what).touch()

    # --- driver ---------------------------------------------------------
    def run_snippet(self, snippet="ensure_task_folder"):
        lines = [
            'export SIGNALS="%s"' % self.signals,
            'export NOTECOVE_BIN="%s"' % self.cli,
            'source "%s"' % (self.scripts / "agent-notecove.sh"),
            'agent_init "%s" "Implementer"' % self.SLUG,
            snippet,
        ]
        env = dict(os.environ, STUB_DIR=str(self.stub_dir), HOME=str(self.home))
        return subprocess.run(["bash", "-c", "\n".join(lines)],
                              capture_output=True, text=True, env=env)

    # --- assertions -----------------------------------------------------
    def written(self):
        f = self.stub_dir / "written.txt"
        return f.read_text() if f.exists() else None

    def events(self):
        return (self.signals / "events.log").read_text()

    def created_folders(self):
        f = self.stub_dir / "created-folders.log"
        return f.read_text().split() if f.exists() else []


class TestPreservesDescription(FolderLinkHarness):
    def test_existing_description_is_preserved_under_the_link(self):
        r = self.run_snippet()
        self.assertEqual(r.returncode, 0, r.stderr)
        written = self.written()
        self.assertIsNotNone(written, "nothing was written")
        self.assertTrue(written.startswith("[[F:new-folder-id|AI & Agents/WORK-abc]]"),
                        written)
        self.assertIn("repo: ~/agentmesh", written)

    def test_rich_description_body_survives(self):
        md = "Intro line.\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\nOutro."
        self.set_task(
            content="<paragraph>Intro line.</paragraph><table><tablerow>"
                    "<tablecell><paragraph>1</paragraph></tablecell></tablerow></table>"
                    "<paragraph>Outro.</paragraph>",
            markdown=md,
        )
        r = self.run_snippet()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("| A | B |", self.written())
        self.assertIn("Outro.", self.written())

    def test_the_previous_description_is_backed_up(self):
        self.run_snippet()
        backup = self.signals / ("%s.description-backup" % self.SLUG)
        self.assertTrue(backup.exists())
        self.assertEqual(backup.read_text(), "repo: ~/agentmesh")

    def test_empty_description_gets_the_link_alone(self):
        # An empty NoteCove description is stored as an empty paragraph, not "".
        self.set_task(content="<paragraph></paragraph>", markdown=None)
        r = self.run_snippet()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.written(), "[[F:new-folder-id|AI & Agents/WORK-abc]]")


class TestNeverWritesOnDoubt(FolderLinkHarness):
    def test_failed_read_writes_nothing(self):
        # The regression. A failed read used to be indistinguishable from an
        # empty description, and the empty-description branch replaced the whole
        # description with just the link.
        self.fail_call("fail-show")
        r = self.run_snippet()
        self.assertNotEqual(r.returncode, 0)
        self.assertIsNone(self.written(), "wrote to the task after a failed read")
        self.assertIn("task-folder-aborted-read", self.events())

    def test_failed_markdown_read_writes_nothing(self):
        self.fail_call("fail-show-md")
        r = self.run_snippet()
        self.assertNotEqual(r.returncode, 0)
        self.assertIsNone(self.written())
        self.assertIn("task-folder-aborted-parse", self.events())

    def test_unparseable_description_writes_nothing(self):
        # Stored content says there is a description, but the markdown has no
        # "Description:" section — the parse is what is wrong, not the task.
        self.set_task(content="<paragraph>real content</paragraph>", markdown=None)
        r = self.run_snippet()
        self.assertNotEqual(r.returncode, 0)
        self.assertIsNone(self.written())
        self.assertIn("task-folder-aborted-parse", self.events())

    def test_failed_folder_list_writes_nothing(self):
        self.fail_call("fail-folder-list")
        r = self.run_snippet()
        self.assertNotEqual(r.returncode, 0)
        self.assertIsNone(self.written())

    def test_failed_folder_create_writes_nothing(self):
        self.fail_call("fail-folder-create")
        r = self.run_snippet()
        self.assertNotEqual(r.returncode, 0)
        self.assertIsNone(self.written())
        self.assertIn("task-folder-create-failed", self.events())

    def test_task_with_no_parent_folder_is_refused(self):
        self.set_task(content="<paragraph>x</paragraph>", markdown="x", folder_id="")
        r = self.run_snippet()
        self.assertNotEqual(r.returncode, 0)
        self.assertIsNone(self.written())


class TestIdempotence(FolderLinkHarness):
    def test_an_already_linked_task_is_untouched(self):
        # The restarted-worker case: adopt the existing folder, write nothing.
        self.set_task(
            content='<paragraph>[[F:existing-fid|AI & Agents/WORK-abc]]</paragraph>'
                    '<paragraph>repo: ~/agentmesh</paragraph>',
            markdown="[[F:existing-fid|AI & Agents/WORK-abc]]\n\nrepo: ~/agentmesh",
        )
        r = self.run_snippet('ensure_task_folder && printf "[%s]" "$TASK_FOLDER_ID"')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("[existing-fid]", r.stdout)
        self.assertIsNone(self.written(), "rewrote an already-linked description")
        self.assertEqual(self.created_folders(), [])

    def test_running_twice_writes_once(self):
        r = self.run_snippet("ensure_task_folder && ensure_task_folder")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.created_folders(), ["WORK-abc"])


class TestFolderResolution(FolderLinkHarness):
    def test_an_existing_folder_is_reused_not_recreated(self):
        self.set_folders([
            {"id": self.PARENT, "name": "AI & Agents", "parentId": None,
             "path": "AI & Agents"},
            {"id": "found-fid", "name": self.SLUG, "parentId": self.PARENT,
             "path": "AI & Agents/WORK-abc"},
        ])
        r = self.run_snippet('ensure_task_folder && printf "[%s]" "$TASK_FOLDER_ID"')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("[found-fid]", r.stdout)
        self.assertEqual(self.created_folders(), [])
        self.assertIn("[[F:found-fid|AI & Agents/WORK-abc]]", self.written())

    def test_a_same_named_folder_under_another_parent_is_ignored(self):
        self.set_folders([
            {"id": self.PARENT, "name": "AI & Agents", "parentId": None,
             "path": "AI & Agents"},
            {"id": "elsewhere", "name": self.SLUG, "parentId": "other-parent",
             "path": "Other/WORK-abc"},
        ])
        r = self.run_snippet()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.created_folders(), ["WORK-abc"])
        self.assertIn("[[F:new-folder-id|", self.written())


class TestVerification(FolderLinkHarness):
    def test_a_failed_write_is_reported(self):
        self.fail_call("fail-change")
        r = self.run_snippet()
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("task-folder-link-failed", self.events())

    def test_a_write_that_does_not_land_is_caught(self):
        # The CLI returns success but the link is not actually there. Without a
        # verify step the agent carries on believing the folder is linked, which
        # is the "folder link missing" half of the original report.
        stub = self.cli.read_text().replace(
            'printf \'%s\' "$content" > "$STUB/written.txt"',
            'printf \'%s\' "$content" > "$STUB/written.txt"\n    exit 0',
        )
        self.cli.write_text(stub)
        r = self.run_snippet()
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("task-folder-verify-failed", self.events())
        self.assertIn("description-backup", r.stderr)

    def test_the_success_path_is_logged(self):
        r = self.run_snippet()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("task-folder-linked", self.events())


if __name__ == "__main__":
    unittest.main()
