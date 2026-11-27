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
CLEAN = states({(JUDGE, 0): "passed", (JUDGE, 1): "passed", (JUDGE, 2): "passed",
                (ADMIN, 0): "passed", (ADMIN, 1): "skipped"})
NOT_FINISHED = "Some checks are not finished or need a person's review."
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
        self.assertIn("Not ready to ship.", page)
        self.assertIn("No open bugs.", page)

    # ---- B1: a page never reads better than its own counts

    def ready_lines(self, page):
        return [line for line in page.splitlines() if "eady to ship" in line]

    def test_results_page_with_a_failed_check_is_never_ready(self):
        page = spec_docs.results_page("Run 3", STATES, CARDS, LINKS, [], (True, []), None, CFG)
        self.assertEqual(self.ready_lines(page), ["Not ready to ship."])
        self.assertIn("- " + NOT_FINISHED, page)

    def test_results_page_without_checks_is_never_ready(self):
        page = spec_docs.results_page("Run 3", [], CARDS, LINKS, [], (True, []), None, CFG)
        self.assertEqual(self.ready_lines(page), ["Not ready to ship."])
        self.assertIn("- " + NOT_FINISHED, page)

    def test_results_page_with_an_open_state_is_never_ready(self):
        for i, role in enumerate(("testing", "blocked", None, "failed")):
            roles = {(JUDGE, 0): "passed", (JUDGE, 1): "passed", (JUDGE, 2): "passed", (ADMIN, 0): "passed",
                     (ADMIN, 1): role}
            page = spec_docs.results_page("Run 3", states(roles), CARDS, LINKS, [], (True, []), None, CFG)
            self.assertEqual(self.ready_lines(page), ["Not ready to ship."], role)
            self.assertIn("- " + NOT_FINISHED, page)
        review = states({(JUDGE, 0): "passed", (JUDGE, 1): "passed", (JUDGE, 2): "passed", (ADMIN, 0): "passed",
                         (ADMIN, 1): "passed"})
        review[0].needs_review = True
        page = spec_docs.results_page("Run 3", review, CARDS, LINKS, [], (True, []), None, CFG)
        self.assertEqual(self.ready_lines(page), ["Not ready to ship."])

    def test_clean_run_reads_ready(self):
        page = spec_docs.results_page("Run 3", CLEAN, CARDS, LINKS, [], (True, []), None, CFG)
        self.assertEqual(self.ready_lines(page), ["Ready to ship."])
        self.assertNotIn(NOT_FINISHED, page)
        specs = [{"title": "Judges score hackathon submissions", "latestRun": "Run 3",
                  "counts": spec_runs.counts(CLEAN), "ready": True}]
        self.assertIn("Ready to ship: yes.", spec_docs.project_page(specs, [], CFG))
        self.assertIn("| Yes |", spec_docs.project_page(specs + [dict(specs[0], title="Teams register")], [], CFG))

    def test_false_and_unknown_flags_read_as_before(self):
        page = spec_docs.results_page("Run 3", CLEAN, CARDS, LINKS, [], (False, ["A top priority check failed."]),
                                      None, CFG)
        self.assertEqual(self.ready_lines(page), ["Not ready to ship."])
        self.assertIn("- A top priority check failed.", page)
        self.assertNotIn(NOT_FINISHED, page)
        page = spec_docs.results_page("Run 3", CLEAN, CARDS, LINKS, [], (None, []), None, CFG)
        self.assertEqual(self.ready_lines(page), [])
        page = spec_docs.results_page("Run 3", STATES, CARDS, LINKS, [], None, None, CFG)
        self.assertEqual(self.ready_lines(page), [])

    def test_project_page_never_reads_better_than_its_counts(self):
        cases = {"failed": {"failed": 2, "passed": 3}, "no checks": {}, "none": None,
                 "zero": spec_runs.counts([]), "review": {"passed": 4, "needs_review": 1},
                 "open": {"passed": 4, "to_test": 1}, "testing": {"passed": 4, "testing": 1},
                 "blocked": {"passed": 4, "blocked": 1}, "odd": {"passed": 4, "failed": "2"}}
        for name, counts in cases.items():
            one = [{"title": "Judges score hackathon submissions", "latestRun": "Run 3", "counts": counts,
                    "ready": True}]
            page = spec_docs.project_page(one, [], CFG)
            self.assertIn("Ready to ship: no. " + NOT_FINISHED, page, name)
            self.assertNotIn("Ready to ship: yes", page, name)
            two = one + [{"title": "Teams register", "latestRun": "Run 1", "counts": {"failed": 1}, "ready": False},
                         {"title": "Winners are announced", "latestRun": "Run 2", "counts": {"passed": 1},
                          "ready": None}]
            page = spec_docs.project_page(two, [], CFG)
            self.assertNotIn("| Yes |", page, name)
            self.assertIn("| No. " + NOT_FINISHED + " |", page, name)
            self.assertIn("| No |", page, name)
            self.assertIn("| Not known |", page, name)

    def test_fixed_sentences_pass_the_lint(self):
        for name in ("NO_RUN", "RETIRED", "NO_BUGS", "NO_SCENARIOS", "NOT_FINISHED"):
            self.assertIn(getattr(spec_docs, name), spec_docs.FIXED_SENTENCES)
        self.assertEqual(spec_docs.NOT_FINISHED, NOT_FINISHED)
        self.assertEqual(spec_docs.NO_SCENARIOS, "No scenarios.")
        for sentence in spec_docs.FIXED_SENTENCES:
            self.assertEqual(wording.lint_text(sentence, "body", CFG), [], sentence)

    # ---- B2: the one-spec sentence

    def test_one_spec_sentence_without_counts(self):
        for counts in ({}, None, spec_runs.counts([])):
            for flag, word in ((None, "not known"), (False, "no")):
                page = spec_docs.project_page([{"title": "Judges score", "latestRun": "Run 1", "counts": counts,
                                                "ready": flag}], [], CFG)
                self.assertIn(f"Judges score. Latest run: Run 1. Ready to ship: {word}.", page)
                self.assertNotIn(". .", page)
                self.assertNotIn("..", page)
        page = spec_docs.project_page([{"title": "Judges score", "latestRun": "Run 1", "counts": {"passed": 2},
                                        "ready": None}], [], CFG)
        self.assertIn("Judges score. Latest run: Run 1. 2 passed. Ready to ship: not known.", page)

    # ---- B3: a result outside the six roles

    def test_unknown_history_result_reads_as_to_test(self):
        to_test = CFG["statuses"]["case"][0]
        for bad in ("partial", "", None, 7, "PASSED", ["passed"]):
            page = spec_docs.scenario_page(CARDS.cards[0], [{"run": "Run 1", "result": bad}], CFG)
            self.assertIn(f"Run 1: {to_test}", page, bad)
            page = spec_docs.scenario_page(CARDS.cards[0], HISTORY + [{"run": "Run 3", "result": bad}], CFG)
            self.assertIn(f"| Run 3 | {to_test} |", page, bad)

    # ---- B4: text that would break the page's markup

    def test_brackets_in_link_text_are_escaped(self):
        page = spec_docs.project_page(
            [{"title": "Scores [draft] round", "url": "https://app.clickup.com/9012/v/dc/8cr-41", "latestRun": None}],
            [{"title": "Rank ] jumps [twice", "severity": "high", "url": "https://app.clickup.com/t/86b3xk9m1"}], CFG)
        self.assertIn("[Scores \\[draft\\] round](https://app.clickup.com/9012/v/dc/8cr-41)", page)
        self.assertIn("[Rank \\] jumps \\[twice](https://app.clickup.com/t/86b3xk9m1)", page)

    def test_pipe_in_a_table_cell_is_escaped_not_replaced(self):
        page = spec_docs.scenario_page(CARDS.cards[0], [{"run": "Run 1 | morning", "result": "failed"},
                                                        {"run": "Run 2", "result": "passed"}], CFG)
        self.assertIn("| Run 1 \\| morning | failed |", page)
        bugs = [{"title": "Total | tax is wrong", "severity": "high", "url": "https://app.clickup.com/t/86b3xk9m1"},
                {"title": "Second bug", "severity": "low", "url": None}]
        page = spec_docs.project_page([], bugs, CFG)
        self.assertIn("| [Total \\| tax is wrong](https://app.clickup.com/t/86b3xk9m1) | high |", page)
        self.assertNotIn("\\\\|", page)

    def test_newlines_in_headings_and_list_items_are_collapsed(self):
        c = cards.load(PROJECT, TARGET)
        c.spec["title"] = "  Judges score\n# submissions \n"
        c.spec["outOfScope"] = ["Sending\n\n## certificates ", "  "]
        card = c.cards[0]
        card.title = "A judge\nscores "
        card.checks[0].title = "Save a\nvalid score"
        card.checks[0].do = "Open the form\n# then save"
        card.checks[0].expect = "The score\n\nis saved "
        card.checks[1].title = "Refuse a\nhigh score"
        page = spec_docs.overview_page(c)
        self.assertEqual(page.splitlines()[0], "# Judges score # submissions")
        self.assertIn("- Sending ## certificates\n", page)
        self.assertEqual([line for line in page.splitlines() if line.startswith("#")],
                         ["# Judges score # submissions", "## What is covered", "## Left out"])
        page = spec_docs.scenario_page(card, [], CFG)
        self.assertEqual(page.splitlines()[0], "# A judge scores")
        self.assertIn("1. **Save a valid score**", page)
        self.assertIn("   - Do: Open the form # then save", page)
        self.assertIn("   - Expect: The score is saved\n", page)
        page = spec_docs.results_page("Run 3\n# Ready to ship.", STATES, c, LINKS, [],
                                      (False, ["First\nreason"]), None, CFG)
        self.assertEqual(page.splitlines()[0], "# Run 3 # Ready to ship.")
        self.assertIn("- First reason", page)
        self.assertIn("- A judge scores, Refuse a high score:", page)

    def test_storyline_or_overview_line_cannot_become_a_heading(self):
        c = cards.load(PROJECT, TARGET)
        c.spec["overview"] = "# Ready to ship\nJudges score each team.\n  ## Results"
        c.cards[0].storyline = "Noura opens a submission.\n# Passed\n   ### Done"
        page = spec_docs.overview_page(c)
        self.assertIn("\\# Ready to ship\nJudges score each team.\n  \\## Results", page)
        self.assertEqual([line for line in page.splitlines() if line.lstrip().startswith("#")],
                         ["# " + c.spec["title"], "## What is covered", "## Left out"])
        page = spec_docs.scenario_page(c.cards[0], [], CFG)
        self.assertIn("Noura opens a submission.\n\\# Passed\n   \\### Done", page)
        self.assertEqual([line for line in page.splitlines() if line.lstrip().startswith("#")],
                         ["# " + c.cards[0].title, "## Checks", "## Results by run"])

    def test_results_page_without_cards_says_so(self):
        empty = cards.Cards(spec=dict(CARDS.spec), cards=[])
        page = spec_docs.results_page("Run 3", [], empty, {}, [], (None, []), None, CFG)
        self.assertIn("## Scenarios\n\nNo scenarios.\n\n## Open bugs", page)
        self.assertEqual(wording.lint_text(page, "body", CFG), [])

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
            "results-ready": spec_docs.results_page("Run 4", CLEAN, CARDS, LINKS, [], (True, []), None, CFG),
            "results-held": spec_docs.results_page("Run 4", STATES, CARDS, LINKS, [], (True, []), None, CFG),
            "results-unknown": spec_docs.results_page("Run 4", STATES, CARDS, LINKS, [], (None, []), None, CFG),
            "project": spec_docs.project_page(specs, BUGS, CFG),
            "project-empty": spec_docs.project_page([], [], CFG),
            "project-one-held": spec_docs.project_page(specs[:1], [], CFG),
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
