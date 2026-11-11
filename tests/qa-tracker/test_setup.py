"""Setup command and rule seeds: template vs load_config defaults, question order, adapter sync."""
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
QA_KIT = ROOT / "qa-kit"
sys.path.insert(0, str(QA_KIT / "scripts"))

from trackers import core  # noqa: E402

VERBS = ("init", "push-plan", "pull-plan", "push-run", "push-results", "push-bug",
         "update-retest", "status", "validate", "results")


class SetupTests(unittest.TestCase):
    def test_config_template_matches_load_config_defaults(self):
        template = json.loads((QA_KIT / "templates" / "qa-tracker-config.json").read_text())
        with tempfile.TemporaryDirectory() as tmp:
            cfg = core.load_config(Path(tmp))
        self.assertEqual(dict(cfg), template)

    def test_command_mentions_three_questions_in_order(self):
        text = (QA_KIT / "core" / "commands" / "qa-tracker.md").read_text()
        questions = ["Where do test cases, runs and bugs live?", "Where do bugs go?",
                     "Keep the default statuses?"]
        pos = -1
        for q in questions:
            idx = text.find(q, pos + 1)
            self.assertGreater(idx, pos, f"{q!r} missing or out of order")
            pos = idx

    def test_clickup_branch_asks_space_folder_and_guide_form(self):
        text = (QA_KIT / "core" / "commands" / "qa-tracker.md").read_text()
        q1, q2 = text.index("Where do test cases, runs and bugs live?"), text.index("Where do bugs go?")
        branch = text[q1:q2]
        for needle in ("space", "folder", "POST /v2/space/{space_id}/folder", "ids.workspace", "ids.space",
                       "ids.folder", 'Keep the guides as tasks, or move them into one "QA Guide" doc?',
                       "guideAs"):
            self.assertIn(needle, branch)
        self.assertLess(branch.index("space"), branch.index('Keep the guides as tasks'))

    def test_seeds_explain_config_keys_and_flags(self):
        for backend in ("clickup", "local"):
            text = (QA_KIT / "templates" / "trackers" / f"{backend}.md").read_text()
            self.assertIn("## Config keys and flags", text, backend)
            section = text.split("## Config keys and flags", 1)[1].split("\n## ", 1)[0]
            for word in ("--run", "--label", "--only", "--overwrite", "statusCeiling", "lists.guide",
                         "lists.runs", "lists.bugs", "wording.allow", "bugsTo"):
                self.assertIn(f"`{word}", section, f"{backend}.md lacks {word}")
            self.assertIn('"AI', section)

    def test_rule_seeds_describe_every_verb(self):
        for backend in ("local", "clickup", "github", "other"):
            text = (QA_KIT / "templates" / "trackers" / f"{backend}.md").read_text()
            for verb in VERBS:
                self.assertIn(f"`{verb}`", text, f"{backend}.md lacks {verb}")

    def test_generated_command_in_sync(self):
        proc = subprocess.run(["bash", str(QA_KIT / "scripts" / "validate-qakit-adapters.sh")],
                              capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)


if __name__ == "__main__":
    unittest.main()
