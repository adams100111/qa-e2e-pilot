"""Tests for qa-kit/scripts/trackers/cards.py (tracker-cards.json loader and checker)."""
from __future__ import annotations

import copy
import io
import json
import shutil
import sys
import tempfile
import unittest
from argparse import Namespace
from contextlib import redirect_stdout
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "qa-kit" / "scripts"))

from trackers import cards, core  # noqa: E402
from trackers.ctx import Ctx  # noqa: E402

FIXTURE = Path(__file__).resolve().parent / "fixtures" / "spec" / "cards" / "project"
TARGET = "judge-scoring"
CFG = {"wording": {"forbidden": ["AI", "agent", "bot"], "allow": [], "patterns": []}, "language": "en"}


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.project = self.tmp / "project"
        shutil.copytree(FIXTURE, self.project)
        self.dir = self.project / ".qa" / "specs" / TARGET

    def raw(self):
        return json.loads((self.dir / cards.CARDS_NAME).read_text(encoding="utf-8"))

    def write(self, data):
        (self.dir / cards.CARDS_NAME).write_text(json.dumps(data), encoding="utf-8")

    def rows(self):
        return json.loads((self.dir / "checklist.json").read_text(encoding="utf-8"))

    def problems(self, data=None, rows=None):
        if data is not None:
            self.write(data)
        c = cards.load(self.project, TARGET)
        return cards.problems(c, self.rows() if rows is None else rows, CFG)


class CardsTest(Base):
    def test_valid_fixture_clean(self):
        c = cards.load(self.project, TARGET)
        self.assertEqual(self.problems(), [])
        self.assertEqual(c.spec["title"], "Judges score hackathon submissions")
        self.assertEqual([x.id for x in c.cards], ["judge-scores-a-submission", "admin-watches-the-ranking"])
        self.assertEqual(c.cards[1].as_, "checklist")
        self.assertEqual(c.cards[0].checks[0].criterion, "C-SCORE-01")

    def test_row_without_card(self):
        d = self.raw()
        d["cards"][0]["checks"].pop(1)
        out = self.problems(d)
        self.assertIn({"card": "", "criterion": "C-SCORE-02", "reason": "no card for this check"}, out)

    def test_pair_in_two_cards(self):
        d = self.raw()
        d["cards"][1]["role"] = "judge"
        out = self.problems(d)
        self.assertTrue(any(p["reason"] == "check is in two cards" and p["criterion"] == "C-RANK-01" for p in out))

    def test_card_names_unknown_row(self):
        d = self.raw()
        d["cards"][0]["checks"].append({"criterion": "C-GHOST-01", "title": "Ghost check", "do": "Do it.", "expect": "It works."})
        out = self.problems(d)
        self.assertIn({"card": "judge-scores-a-submission", "criterion": "C-GHOST-01",
                       "reason": "check is not in the plan"}, out)

    def test_two_role_row_needs_two_checks(self):
        d = self.raw()
        d["cards"][1]["checks"].pop(0)  # admin's check of C-RANK-01
        out = self.problems(d)
        self.assertEqual([p["criterion"] for p in out], ["C-RANK-01"])
        self.assertEqual(out[0]["reason"], "no card for this check")

    def test_duplicate_card_id(self):
        d = self.raw()
        d["cards"][1]["id"] = d["cards"][0]["id"]
        out = self.problems(d)
        self.assertTrue(any(p["reason"] == "duplicate card id" for p in out))

    def test_title_with_emoji_reported_with_card_id(self):
        d = self.raw()
        d["cards"][1]["title"] = "An admin watches the ranking ✅"
        out = self.problems(d)
        self.assertEqual(out, [{"card": "admin-watches-the-ranking", "criterion": "", "reason": "emoji"}])

    def test_check_text_linted_with_criterion(self):
        d = self.raw()
        d["cards"][0]["checks"][0]["expect"] = "The bot saves it."
        out = self.problems(d)
        self.assertEqual(out, [{"card": "judge-scores-a-submission", "criterion": "C-SCORE-01",
                                "reason": "forbidden word: bot"}])

    def test_missing_file_message(self):
        (self.dir / cards.CARDS_NAME).unlink()
        with self.assertRaises(cards.CardsError) as cm:
            cards.load(self.project, TARGET)
        self.assertEqual(str(cm.exception), f"{self.dir / cards.CARDS_NAME}: not found; run /qa-scenarios")

    def test_bad_shape_raises(self):
        d = self.raw()
        d["cards"][0]["priority"] = "P9"
        self.write(d)
        with self.assertRaises(cards.CardsError):
            cards.load(self.project, TARGET)

    def test_spec_dir(self):
        self.assertEqual(cards.spec_dir(self.project, TARGET), self.dir)

    def test_card_for(self):
        c = cards.load(self.project, TARGET)
        self.assertEqual(cards.card_for(c, "C-RANK-01", "admin").id, "admin-watches-the-ranking")
        self.assertEqual(cards.card_for(c, "C-RANK-01", "judge").id, "judge-scores-a-submission")
        self.assertIsNone(cards.card_for(c, "C-RANK-01", ""))  # two cards hold it
        self.assertEqual(cards.card_for(c, "C-SCORE-01", "").id, "judge-scores-a-submission")
        self.assertIsNone(cards.card_for(c, "C-SCORE-01", "admin"))
        self.assertIsNone(cards.card_for(c, "nope", ""))


class CardsFixRound1Test(Base):
    def test_role_name_with_emoji_reported_with_card_id(self):
        d = self.raw()
        d["cards"][1]["roleName"] = "Admin \u2705"
        out = self.problems(d)
        self.assertEqual(out, [{"card": "admin-watches-the-ranking", "criterion": "", "reason": "emoji"}])

    def test_plan_rows_public_and_alias(self):
        rows = cards.plan_rows(self.project, TARGET)
        self.assertEqual(rows, self.rows())
        self.assertEqual(cards._plan_rows(self.project, TARGET), rows)

    def test_plan_rows_unknown_dict_raises_naming_file(self):
        (self.dir / "checklist.json").write_text('{"other": []}', encoding="utf-8")
        with self.assertRaises(cards.CardsError) as cm:
            cards.plan_rows(self.project, TARGET)
        self.assertEqual(str(cm.exception), f"{self.dir / 'checklist.json'}: not a plan the tracker can read")

    def test_plan_rows_invalid_json_raises_naming_file(self):
        (self.dir / "checklist.json").write_text("{not json", encoding="utf-8")
        with self.assertRaises(cards.CardsError) as cm:
            cards.plan_rows(self.project, TARGET)
        self.assertIn(str(self.dir / "checklist.json"), str(cm.exception))

    def test_duplicate_row_in_plan_reported_once(self):
        rows = self.rows()
        rows.append(copy.deepcopy(rows[0]))
        out = self.problems(rows=rows)
        self.assertEqual(out, [{"card": "", "criterion": rows[0]["id"], "reason": "duplicate row in the plan"}])

    def test_check_repeated_in_same_card(self):
        d = self.raw()
        d["cards"][0]["checks"].append(copy.deepcopy(d["cards"][0]["checks"][0]))
        out = self.problems(d)
        self.assertEqual(out, [{"card": "judge-scores-a-submission", "criterion": "C-SCORE-01",
                                "reason": "check is repeated in this card"}])


class LintVerbTest(Base):
    def ctx(self):
        log = core.ActionLog(False, out=io.StringIO())
        return Ctx(project=self.project, cfg=CFG, catalog=None, log=log, cache=None,
                   args=Namespace(spec=TARGET)), log

    def run_verb(self):
        ctx, log = self.ctx()
        buf = io.StringIO()
        with redirect_stdout(buf):
            cards.lint_verb(ctx)
        return json.loads(buf.getvalue().strip().splitlines()[-1]), ctx

    def test_lint_verb_ok(self):
        out, ctx = self.run_verb()
        self.assertEqual(out, {"ok": True, "problems": []})
        self.assertEqual(ctx.log.counts.get("skip", 0), 0)

    def test_lint_verb_rc1_on_problem(self):
        d = self.raw()
        d["cards"][0]["checks"].pop(1)
        self.write(d)
        out, ctx = self.run_verb()
        self.assertFalse(out["ok"])
        self.assertEqual(out["problems"][0]["reason"], "no card for this check")
        self.assertGreaterEqual(ctx.log.counts["skip"], 1)


if __name__ == "__main__":
    unittest.main()
