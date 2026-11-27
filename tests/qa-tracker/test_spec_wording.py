"""Tests for qa-kit/scripts/trackers/wording.py (lint of one outbound string)."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "qa-kit" / "scripts"))

from trackers import core, wording  # noqa: E402

CFG = {
    "wording": {"forbidden": ["AI", "agent", "bot"], "allow": [], "patterns": [r"\bPR ?#\d+\b"]},
    "language": "en",
}


def lint(text, kind="body", cfg=None):
    return wording.lint_text(text, kind, cfg or CFG)


class WordingLintTest(unittest.TestCase):
    def test_empty(self):
        self.assertEqual(lint("   "), ["empty"])

    def test_emoji(self):
        self.assertIn("emoji", lint("Saved ✅"))
        self.assertIn("emoji", lint("Careful ⚠"))
        self.assertIn("emoji", lint("Nice \U0001F389"))

    def test_forbidden_word(self):
        self.assertIn("forbidden word: bot", lint("A bot filled the form"))
        self.assertEqual(lint("The robot arm moves"), [])

    def test_ids(self):
        for text, tok in [("See C-012 for details", "C-012"), ("Row J1 fails", "J1"),
                          ("Check AC12", "AC12"), ("Fixed in 3fa9c1d", "3fa9c1d"),
                          ("See #123", "#123"), ("Upgrade to v1.2.3", "v1.2.3"),
                          ("The save_score field", "save_score"), ("The saveScore call", "saveScore"),
                          ("Opened PR #45", "PR #45")]:
            self.assertIn(f"looks like an id: {tok}", lint(text), text)

    def test_title_too_long(self):
        self.assertIn("title too long (max 90)", lint("a" * 91 + " b", "title"))
        self.assertNotIn("title too long (max 90)", lint("a" * 91 + " b", "body"))

    def test_headline_case(self):
        self.assertIn("title in headline case", lint("Judge Can Save Score For Submission", "title"))
        self.assertNotIn("title in headline case", lint("Judge Can Save Score For Submission", "body"))
        self.assertEqual(lint("Judge can save a score", "title"), [])
        arabic_cfg = dict(CFG, language="ar")
        self.assertEqual(lint("Judge Can Save Score For Submission", "title", arabic_cfg), [])

    def test_mentions_person(self):
        self.assertIn("mentions a person", lint("Ask @faisal about it"))

    def test_plain_sentence_passes(self):
        self.assertEqual(lint("Judge can save a score for a submission", "title"), [])

    def test_allow_phrase_exempts(self):
        cfg = {"wording": {"forbidden": ["AI"], "allow": ["AI Lab"], "patterns": []}}
        self.assertEqual(lint("Visit the AI Lab on Monday", "body", cfg), [])
        self.assertIn("forbidden word: AI", lint("Visit the AI team", "body", cfg))

    def test_arabic_title_passes(self):
        self.assertEqual(lint("يمكن للمحكم حفظ الدرجة لكل مشروع مقدم", "title"), [])

    def test_number_alone_is_not_an_id(self):
        self.assertEqual(lint("Shows 3 teams per page"), [])

    def test_product_and_role_names_pass(self):
        self.assertEqual(lint("Product Owner opens the Dashboard", "title"), [])

    def test_clean_returns_outbound_text(self):
        self.assertEqual(wording.clean("Judge can save a score", "title", CFG), "Judge can save a score")

    def test_clean_raises_first_reason(self):
        with self.assertRaises(core.WordingError) as cm:
            wording.clean("Saved ✅ by a bot", "body", CFG)
        self.assertEqual(str(cm.exception.args[0]), "emoji")

    def test_bad_kind(self):
        with self.assertRaises(ValueError):
            lint("x", "heading")


if __name__ == "__main__":
    unittest.main()
