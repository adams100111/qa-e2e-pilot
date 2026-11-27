"""Tests for qa-kit/scripts/trackers/spec_docs.py (the Doc pages, pure markdown)."""
from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "qa-kit" / "scripts"))

from trackers import cards, spec_docs, spec_runs, wording  # noqa: E402

PROJECT = Path(__file__).resolve().parent / "fixtures" / "spec" / "cards" / "project"
TARGET = "judge-scoring"
TEMPLATE = json.loads((ROOT / "qa-kit" / "templates" / "qa-tracker-config.json").read_text(encoding="utf-8"))
CFG = dict(TEMPLATE)
JUDGE, ADMIN = "judge-scores-a-submission", "admin-watches-the-ranking"
CRITERIA = {JUDGE: ["C-SCORE-01", "C-SCORE-02", "C-RANK-01"], ADMIN: ["C-RANK-01", "load-clean:GET /admin/hackathons:admin"]}
URL_JUDGE = "https://app.clickup.com/t/86b2k4m9z"
URL_ADMIN = "https://app.clickup.com/t/86b2k4pqw"
LINKS = {JUDGE: URL_JUDGE, ADMIN: URL_ADMIN}
BUGS = [
    {"title": "Score above ten is saved", "severity": "high", "url": "https://app.clickup.com/t/86b3xk9m1"},
    {"title": "Leaderboard shows the same team twice", "severity": "medium", "url": "https://app.clickup.com/t/86b3wq7p2"},
]
REPORT_URL = "https://reports.example.sa/judge-scoring/run-3"


def states(roles):
    out = []
    for card in CARDS.cards:
        for i, check in enumerate(card.checks):
            role = roles.get((card.id, i))
            out.append(spec_runs.CheckState(
                card.id, check.criterion, card.role, role,
                needs_review=(role == "testing"),
                note=("A message was missing." if role == "failed" else None)))
    return out


CARDS = cards.load(PROJECT, TARGET)
STATES = states({(JUDGE, 0): "passed", (JUDGE, 1): "failed", (JUDGE, 2): "testing",
                 (ADMIN, 0): "passed", (ADMIN, 1): "passed"})
READY = (False, ["A top priority check failed.", "Some screens have not been checked yet."])
HISTORY = [{"run": "Run 1, 12 Nov 2026", "result": "failed"}, {"run": "Run 2, 19 Nov 2026", "result": "passed"}]


def results():
    return spec_docs.results_page("Run 3, 26 Nov 2026", STATES, CARDS, LINKS, BUGS, READY, REPORT_URL, CFG)


class SpecDocsTests(unittest.TestCase):
    def test_constants(self):
        self.assertEqual(
            (spec_docs.PAGE_OVERVIEW, spec_docs.PAGE_SCENARIOS, spec_docs.PAGE_RESULTS, spec_docs.PROJECT_DOC),
            ("Overview", "Scenarios", "Results", "QA overview"))

    def test_results_page_counts_and_links(self):
        page = results()
        self.assertIn("5 checks", page)
        self.assertIn("3 passed", page)
        self.assertIn("1 failed", page)
        self.assertIn("1 testing", page)
        self.assertIn("A person needs to confirm 1 result.", page)
        self.assertIn(URL_JUDGE, page)
        self.assertIn(URL_ADMIN, page)
        self.assertIn(REPORT_URL, page)
        self.assertIn("Not ready to ship.", page)
        self.assertIn("A top priority check failed.", page)
        self.assertIn("A judge scores a team submission", page)
        self.assertIn("Score above ten is saved", page)
        self.assertIn("A message was missing.", page)
        self.assertNotIn("C-SCORE", page)
        self.assertNotIn(str(PROJECT), page)

    def test_results_page_uses_project_status_names(self):
        cfg = json.loads(json.dumps(CFG))
        cfg["statuses"]["case"] = ["to do", "in test", "not ok", "stuck", "ok", "left out"]
        page = spec_docs.results_page("Run 3", STATES, CARDS, LINKS, [], (True, []), None, cfg)
        self.assertIn("not ok", page)
        self.assertNotIn("failed", page)
        self.assertIn("Ready to ship.", page)
        self.assertIn("No open bugs.", page)

    def test_scenario_history_table(self):
        page = spec_docs.scenario_page(CARDS.cards[0], HISTORY, CFG)
        self.assertIn("# A judge scores a team submission", page)
        self.assertIn("Noura opens a submission", page)
        self.assertIn("Save a valid score", page)
        self.assertIn("| Run 1, 12 Nov 2026 | failed |", page)
        self.assertIn("| Run 2, 19 Nov 2026 | passed |", page)

    def test_scenario_single_run_is_not_a_table(self):
        page = spec_docs.scenario_page(CARDS.cards[0], HISTORY[:1], CFG)
        self.assertNotIn("| Run 1", page)
        self.assertIn("Run 1, 12 Nov 2026: failed", page)

    def test_retired_scenario_keeps_history(self):
        page = spec_docs.scenario_page(CARDS.cards[1], HISTORY, CFG, retired=True)
        self.assertTrue(page.startswith("No longer part of the plan."))
        self.assertIn("Run 2, 19 Nov 2026", page)
        self.assertIn("An admin watches the ranking", page)

    def test_project_page_lists_specs_latest_run(self):
        specs = [
            {"title": "Judges score hackathon submissions", "url": "https://app.clickup.com/9012/v/dc/8cr-41",
             "latestRun": "Run 3, 26 Nov 2026", "counts": spec_runs.counts(STATES), "ready": False},
            {"title": "Teams register for the hackathon", "url": "https://app.clickup.com/9012/v/dc/8cr-52",
             "latestRun": None, "counts": None, "ready": None},
        ]
        page = spec_docs.project_page(specs, BUGS, CFG)
        self.assertIn("# QA overview", page)
        self.assertIn("Run 3, 26 Nov 2026", page)
        self.assertIn("[Judges score hackathon submissions](https://app.clickup.com/9012/v/dc/8cr-41)", page)
        self.assertIn("No run yet.", page)
        self.assertIn("Score above ten is saved", page)
        self.assertLess(page.index("Score above ten"), page.index("Leaderboard shows"))

    def test_no_run_yet(self):
        page = spec_docs.project_page(
            [{"title": "Teams register for the hackathon", "url": "https://app.clickup.com/9012/v/dc/8cr-52",
              "latestRun": None, "counts": None, "ready": None}], [], CFG)
        self.assertIn("No run yet.", page)
        self.assertIn("No open bugs.", page)
        self.assertNotIn("| Spec", page)

    def test_pages_pass_lint(self):
        specs = [{"title": "Judges score hackathon submissions", "url": "https://app.clickup.com/9012/v/dc/8cr-41",
                  "latestRun": "Run 3, 26 Nov 2026", "counts": spec_runs.counts(STATES), "ready": True},
                 {"title": "Teams register", "url": "https://app.clickup.com/9012/v/dc/8cr-52",
                  "latestRun": None, "counts": None, "ready": None}]
        pages = {
            "overview": spec_docs.overview_page(CARDS),
            "scenario": spec_docs.scenario_page(CARDS.cards[0], HISTORY, CFG),
            "scenario2": spec_docs.scenario_page(CARDS.cards[1], [], CFG),
            "retired": spec_docs.scenario_page(CARDS.cards[1], HISTORY, CFG, retired=True),
            "results": results(),
            "results-ready": spec_docs.results_page("Run 4", STATES, CARDS, LINKS, [], (True, []), None, CFG),
            "results-unknown": spec_docs.results_page("Run 4", STATES, CARDS, LINKS, [], (None, []), None, CFG),
            "project": spec_docs.project_page(specs, BUGS, CFG),
            "project-empty": spec_docs.project_page([], [], CFG),
        }
        for name, page in pages.items():
            self.assertEqual(wording.lint_text(page, "body", CFG), [], name)

    def test_overview_content(self):
        page = spec_docs.overview_page(CARDS)
        self.assertIn("Judges score hackathon submissions", page)
        self.assertIn("Sending certificates to the winners", page)
        self.assertIn("Judge", page)

    def test_deterministic_output(self):
        self.assertEqual(results(), results())
        self.assertEqual(spec_docs.overview_page(CARDS), spec_docs.overview_page(CARDS))
        a = spec_docs.project_page([], list(BUGS), CFG)
        b = spec_docs.project_page([], list(reversed(BUGS)), CFG)
        self.assertEqual(a, b)


if __name__ == "__main__":
    unittest.main()
