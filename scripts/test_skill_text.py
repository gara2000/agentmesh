"""Guards on the text of the agent skills.

Skills are instructions an agent copies into its shell, so a bad pattern in
them is a bug in every worker that runs them. Two have bitten:

- A raw `notecove … <slug>` call. The short slug is a uniquePrefix that can
  go ambiguous while the agent works; the CLI then prompts on the worker's
  TTY and hangs until timeout. Raw calls must use "$TASK_REF".
- `notecove task comments add` right before `post_summary`: two comments per
  hand-back, the first by the hang-prone path. Comments go through
  `post_summary`, which addresses the task by $TASK_REF and counts toward the
  per-turn summary guarantee.
"""

import re
import unittest
from pathlib import Path

PLUGIN = Path(__file__).resolve().parent.parent / "plugins" / "agentic-workflows"

SHORT_SLUG_CALL = re.compile(r"\bnotecove\s+[a-z][a-z -]*?\s\"?<slug>")
RAW_COMMENT = re.compile(r"\bnotecove\s+task\s+comments\s+add\b")


def skill_files():
    # Worker skills only: those built on a shared base. The `notecove` CLI
    # reference and the interactive `task-interaction` skill document the CLI
    # for a human-driven session and legitimately show `<slug>`.
    family = [p for p in sorted(PLUGIN.glob("skills/*/SKILL.md"))
              if re.search(r"^extends:", p.read_text(), re.M)]
    files = family + sorted(PLUGIN.glob("shared/*.md"))
    assert files, f"no skill files found under {PLUGIN}"
    return files


def offending_lines(pattern):
    hits = []
    for path in skill_files():
        for n, line in enumerate(path.read_text().splitlines(), 1):
            if pattern.search(line):
                hits.append(f"{path.relative_to(PLUGIN)}:{n}: {line.strip()}")
    return hits


class SkillTextTest(unittest.TestCase):
    def test_no_raw_notecove_call_with_short_slug(self):
        hits = offending_lines(SHORT_SLUG_CALL)
        self.assertEqual(hits, [], "use \"$TASK_REF\", not <slug>, in raw notecove calls:\n" + "\n".join(hits))

    def test_no_raw_task_comment(self):
        hits = offending_lines(RAW_COMMENT)
        self.assertEqual(hits, [], "post comments with post_summary, not notecove task comments add:\n" + "\n".join(hits))

    def test_patterns_catch_the_old_forms(self):
        self.assertTrue(SHORT_SLUG_CALL.search("notecove task show <slug> --format json"))
        self.assertTrue(SHORT_SLUG_CALL.search("- Task tree: `notecove task tree <slug> --depth 3`"))
        self.assertTrue(SHORT_SLUG_CALL.search('notecove task show "<slug>" --json'))
        self.assertFalse(SHORT_SLUG_CALL.search('notecove task show "$TASK_REF" --format json'))
        self.assertFalse(SHORT_SLUG_CALL.search('create_note "<slug>/PLAN" << EOF'))
        self.assertTrue(RAW_COMMENT.search('notecove task comments add <slug> --user "X" "hi"'))


if __name__ == "__main__":
    unittest.main()
