"""`push-docs`, `spec-note` and `spec-status` through cli.main, against the in-memory ClickUp
space of the structure and sync tests (its Docs, pages and comment parts are in `SpecFake`).
"""
from __future__ import annotations

import json
import shutil
import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "qa-kit" / "scripts"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from test_spec_clickup_structure import ADMIN_CARD, JUDGE_CARD, QA, TARGET, TITLE, WS  # noqa: E402
from test_spec_clickup_sync import ALL_PASS, BUG_TITLE, RUN_1, RUN_2, SyncBase, cs, row  # noqa: E402
from trackers import cards, core, spec_docs, spec_runs  # noqa: E402

RUN_PAGE_1, RUN_PAGE_2 = "Run 1 · 2026-11-27", "Run 2 · 2026-11-28"
NOTE = ("Two screens of the judging flow have no check yet: the score history and the export.\n"
        "The plan is ready for a first run once those are added.")
LEAD = 48211907
READY_REPORT = "# Judging report\n\n## Ship readiness\n\n**SHIP-READY**\n\n## Results\n"
KEYS = ["spec", "folderUrl", "docUrl", "list", "behind", "reasons"]


class DocsBase(SyncBase):
    def docs(self, *extra, apply=True):
        return self.tracker("push-docs", *extra, apply=apply)

    def synced(self, run=RUN_1):
        """The run is on its list and the calls so far are forgotten."""
        rc, lines, err = self.sync(run=run)
        self.assertEqual(rc, 0, (lines, err))
        self.fake.calls.clear()

    def pushed(self, *extra):
        rc, lines, err = self.docs(*extra)
        self.assertEqual(rc, 0, (lines, err))
        self.fake.calls.clear()
        return lines

    def spec_doc(self):
        return self.cfg()["specs"][TARGET]["doc"]

    def overview_doc(self):
        found = [d for d in self.fake.docs.values() if d["name"] == "QA overview"]
        self.assertEqual(len(found), 1, found)
        return found[0]

    def page(self, name, parent=None, doc=None):
        return self.fake.page_named(doc or self.spec_doc(), name, parent)

    def names(self, doc=None, parent=None):
        doc = doc or self.spec_doc()
        top = None if parent is None else self.page(parent, doc=doc)["id"]
        return [p["name"] for p in self.fake.pages[doc] if p["parent"] == top]

    def dashboard(self):
        doc = self.overview_doc()["id"]
        return self.page("QA overview", doc=doc)["content"]

    def cards(self):
        return cards.load(self.tmp, TARGET)

    def status(self, *extra):
        """`spec-status`: its exit code, the one JSON line, and every line it printed."""
        rc, lines, err = self.tracker("spec-status", *extra, apply=False)
        self.assertEqual(len(lines), 1, (lines, err))     # the JSON line and nothing else
        return rc, json.loads(lines[0]), lines

    def note(self, text=NOTE, *extra, apply=True):
        path = self.tmp / "analysis-note.md"
        path.write_text(text, encoding="utf-8")
        return self.tracker("spec-note", "--file", str(path), *extra, apply=apply)

    def report(self, text=READY_REPORT, run=RUN_1):
        (self.tmp / ".qa" / "runs" / run / "report.md").write_text(text, encoding="utf-8")

    def verify(self, run=RUN_1, report="# Judging report\n"):
        """The run was verified and its report rendered (a report with no ship section says nothing)."""
        run_dir = self.tmp / ".qa" / "runs" / run
        (run_dir / "verification.json").write_text(json.dumps({"rows": []}), encoding="utf-8")
        (run_dir / "report.md").write_text(report, encoding="utf-8")

    def doc_url(self, doc=None):
        return f"https://app.clickup.com/{WS}/v/dc/{doc or self.spec_doc()}"

    def project_rows(self, *extra):
        """`push-docs --apply`; the rows it handed to the project page, by spec title."""
        seen, real = [], spec_docs.project_page

        def spy(rows, bugs, cfg):
            seen.append(rows)
            return real(rows, bugs, cfg)
        with mock.patch.object(spec_docs, "project_page", spy):
            rc, lines, err = self.docs(*extra)
        self.assertEqual(rc, 0, (lines, err))
        return {r["title"]: r for r in seen[-1]}

    def no_cache(self):
        """A machine that has never pushed: the local cache is not there."""
        cache = self.tmp / ".qa" / "tracker-map.json"
        if cache.exists():
            cache.unlink()

    def no_runs(self):
        """No run has been made on this machine yet."""
        shutil.rmtree(self.tmp / ".qa" / "runs")


class PushDocsTests(DocsBase):
    def test_push_docs_creates_pages(self):
        self.synced()
        rc, lines, err = self.docs("--run", RUN_1)
        self.assertEqual(rc, 0, (lines, err))
        # the spec Doc: the empty page ClickUp made with it became the Overview; no page has no name
        self.assertEqual(self.names(), ["Overview", "Scenarios", "Results"])
        self.assertEqual(self.names(parent="Scenarios"), [JUDGE_CARD, ADMIN_CARD])
        self.assertEqual(self.names(parent="Results"), [RUN_PAGE_1])
        c = self.cards()
        self.assertEqual(self.page("Overview")["content"], spec_docs.overview_page(c))
        history = [{"run": RUN_PAGE_1, "result": "failed"}]
        self.assertEqual(self.page(JUDGE_CARD, "Scenarios")["content"],
                         spec_docs.scenario_page(c.cards[0], history, self.cfg_for_pages()))
        self.assertIn(f"{RUN_PAGE_1}: testing", self.page(ADMIN_CARD, "Scenarios")["content"])
        results = self.page(RUN_PAGE_1, "Results")["content"]
        self.assertTrue(results.startswith(f"# {RUN_PAGE_1}\n\n5 checks: 1 to test, 1 testing, 1 failed, "
                                           f"1 blocked, 1 passed.\nA person needs to confirm 1 result.\n"), results)
        judge = self.fake.task(JUDGE_CARD)["id"]
        self.assertIn(f"| {JUDGE_CARD} | failed | [Open ticket](https://app.clickup.com/t/{judge}) |", results)
        self.assertIn("No open bugs.", results)
        self.assertNotIn("eady to ship", results)   # no report, so nothing is said about it
        # every page went as markdown, sub-pages under their parent
        scenarios = self.page("Scenarios")["id"]
        create = next(c for c in self.fake.writes("POST", r"/pages$") if c[2]["name"] == JUDGE_CARD)
        self.assertEqual(create, ("POST", f"/v3/workspaces/{WS}/docs/{self.spec_doc()}/pages",
                                  {"name": JUDGE_CARD, "content": self.page(JUDGE_CARD, "Scenarios")["content"],
                                   "content_format": "text/md", "parent_page_id": scenarios}))
        update = self.fake.writes("PUT", r"/pages/\w+$")[0]
        self.assertEqual(update[2], {"name": "Overview", "content": spec_docs.overview_page(c),
                                     "content_format": "text/md", "content_edit_mode": "replace"})
        self.assert_quiet()

    def cfg_for_pages(self):
        return core.spec_settings(core.load_config(self.tmp), TARGET)

    def test_push_docs_unchanged_no_writes(self):
        self.synced()
        self.pushed("--run", RUN_1)
        text = self.cfg_path.read_text(encoding="utf-8")
        rc, lines, err = self.docs("--run", RUN_1)
        self.assertEqual(rc, 0, (lines, err))
        self.assertEqual(self.fake.calls, [])
        self.assertEqual(self.cfg_path.read_text(encoding="utf-8"), text)

    def test_second_machine_without_a_cache_writes_nothing(self):
        self.synced()
        self.pushed()
        cache = self.tmp / ".qa" / "tracker-map.json"
        if cache.exists():
            cache.unlink()
        rc, lines, err = self.docs()
        self.assertEqual(rc, 0, (lines, err))
        self.assertEqual(self.fake.calls, [])

    def test_page_is_written_again_only_when_its_text_changed(self):
        self.synced()
        self.pushed()
        self.edit_cards(lambda d: d["cards"][1].update(storyline="Faisal follows the judging from the leaderboard."))
        rc, lines, err = self.docs()
        self.assertEqual(rc, 0, (lines, err))
        self.assertEqual([c[2]["name"] for c in self.fake.calls], [ADMIN_CARD])
        self.assertIn("Faisal follows the judging", self.page(ADMIN_CARD, "Scenarios")["content"])

    def test_dry_run_writes_nothing(self):
        self.synced()
        text = self.cfg_path.read_text(encoding="utf-8")
        rc, lines, err = self.docs("--run", RUN_1, apply=False)
        self.assertEqual(rc, 0, (lines, err))
        self.assertEqual(self.fake.calls, [])
        self.assertEqual(self.cfg_path.read_text(encoding="utf-8"), text)
        self.assertIn("DRY\tpage-create\tScenarios", lines)
        self.assertIn(f"DRY\tpage-create\t{RUN_PAGE_1}", lines)
        self.assertIn("DRY\tdoc-create\tQA overview", lines)

    def test_history_from_two_runs(self):
        self.synced()
        self.add_run(RUN_2, ALL_PASS)
        self.synced(RUN_2)
        # the first run's files are not on this machine: its history still comes from ClickUp
        shutil.rmtree(self.tmp / ".qa" / "runs" / RUN_1)
        first = self.lists()[0]["id"]
        lines = self.pushed()
        judge = self.page(JUDGE_CARD, "Scenarios")["content"]
        self.assertIn(f"| Run | Result |\n| --- | --- |\n| {RUN_PAGE_1} | failed |\n| {RUN_PAGE_2} | passed |", judge)
        self.assertIn(f"| {RUN_PAGE_1} | testing |\n| {RUN_PAGE_2} | passed |",
                      self.page(ADMIN_CARD, "Scenarios")["content"])
        # a results page is made only from results that are here; the other run is said, not failed
        self.assertEqual(self.names(parent="Results"), [RUN_PAGE_2])
        self.assertIn(f"SKIP\trun-not-here\t{RUN_PAGE_1}: its results are not on this machine; "
                      f"its page is left as it is", lines)
        # a status move that stopped half way reads as the status the ticket shows
        card = self.fake.task(JUDGE_CARD, first)
        card["values"]["f-ref"] = cs.reletter(card["values"]["f-ref"], "failed", pending="passed")
        self.assertEqual(self.docs()[0], 0)
        self.assertEqual(self.fake.calls, [])
        # what a person set on a ticket is what the page says
        card["status"]["status"] = "blocked"
        self.pushed()
        self.assertIn(f"| {RUN_PAGE_1} | blocked |", self.page(JUDGE_CARD, "Scenarios")["content"])

    def test_history_keeps_a_run_whose_list_was_archived(self):
        self.synced()
        self.add_run(RUN_2, ALL_PASS)
        self.synced(RUN_2)
        self.lists()[0]["archived"] = True
        self.pushed()
        self.assertIn(f"| {RUN_PAGE_1} | failed |\n| {RUN_PAGE_2} | passed |",
                      self.page(JUDGE_CARD, "Scenarios")["content"])

    def test_results_page_follows_the_report_and_the_report_link(self):
        self.synced()
        self.add_run(RUN_2, ALL_PASS)
        self.report(run=RUN_2)
        self.synced(RUN_2)
        self.edit_cfg(lambda d: d.update(reportUrl="https://reports.innovation-lab.co/judging/latest"))
        self.pushed("--run", RUN_2)
        page = self.page(RUN_PAGE_2, "Results")["content"]
        self.assertIn("5 checks: 5 passed.\nReady to ship.\n\nFull report: "
                      "https://reports.innovation-lab.co/judging/latest\n", page)
        self.assertIn("Ready to ship: yes.", self.dashboard())
        self.assertNotIn("Ready to ship.", self.page(RUN_PAGE_1, "Results")["content"])

    def test_retired_scenario_page_stays_and_is_marked(self):
        self.synced()
        self.pushed()
        before = self.page(ADMIN_CARD, "Scenarios")["content"]
        self.edit_cards(lambda d: d.update(cards=d["cards"][:1]))
        self.edit_plan(lambda rows: [r for r in rows if r.get("persona") != "admin"])
        rc, lines, err = self.docs()
        self.assertEqual(rc, 0, (lines, err))
        self.assertEqual(self.names(parent="Scenarios"), [JUDGE_CARD, ADMIN_CARD])
        self.assertEqual(self.page(ADMIN_CARD, "Scenarios")["content"],
                         f"No longer part of the plan.\n\n{before.rstrip()}\n")
        self.fake.calls.clear()
        self.assertEqual(self.docs()[0], 0)
        self.assertEqual(self.fake.calls, [])

    def retire_admin_card(self):
        self.edit_cards(lambda d: d.update(cards=d["cards"][:1]))
        self.edit_plan(lambda rows: [r for r in rows if r.get("persona") != "admin"])

    def test_retired_page_is_rebuilt_from_the_text_the_tool_wrote(self):
        self.synced()
        self.pushed()
        page = self.page(ADMIN_CARD, "Scenarios")
        before = page["content"]
        page["content"] = before.replace("   - Do:", "* Do:").replace("## ", "### ")   # ClickUp's own layout
        self.assertNotEqual(page["content"], before)
        self.retire_admin_card()
        self.assertEqual(self.docs()[0], 0)
        self.assertEqual(page["content"], f"No longer part of the plan.\n\n{before.rstrip()}\n")

    def test_retired_page_without_the_cache_keeps_what_clickup_holds(self):
        self.synced()
        self.pushed()
        page = self.page(ADMIN_CARD, "Scenarios")
        page["content"] = page["content"].replace("   - Do:", "* Do:")
        held = page["content"]
        self.no_cache()
        self.retire_admin_card()
        self.assertEqual(self.docs()[0], 0)
        self.assertEqual(page["content"], f"No longer part of the plan.\n\n{held.rstrip()}\n")
        self.fake.calls.clear()
        self.assertEqual(self.docs()[0], 0)
        self.assertEqual(self.fake.calls, [])

    def test_retired_page_a_person_edited_keeps_the_persons_text(self):
        self.synced()
        self.pushed()
        page = self.page(ADMIN_CARD, "Scenarios")
        page["content"] += "\nThe ranking is also shown on the hall screen.\n"
        held = page["content"]
        self.retire_admin_card()
        self.assertEqual(self.docs()[0], 0)
        self.assertEqual(page["content"], f"No longer part of the plan.\n\n{held.rstrip()}\n")

    def test_page_under_scenarios_that_the_tool_did_not_make_is_left_alone(self):
        self.synced()
        self.pushed()
        doc = self.spec_doc()
        theirs = {"id": "p-review-notes", "name": "Notes from the review", "parent": self.page("Scenarios")["id"],
                  "content": "Ask Noura which team wins when two scores are equal."}
        self.fake.pages[doc].append(theirs)
        kept = dict(theirs)
        for cached in (True, False):
            with self.subTest(cached=cached):
                if not cached:
                    self.no_cache()
                rc, lines, err = self.docs()
                self.assertEqual(rc, 0, (lines, err))
                self.assertEqual(self.fake.calls, [])
                self.assertEqual(theirs, kept)
                self.assertIn("SKIP\tpage-not-ours\tNotes from the review: a page under Scenarios that was not "
                              "made here; it is left as it is", lines)

    def test_page_that_breaks_the_writing_rules_is_not_written(self):
        self.synced()
        self.edit_cards(lambda d: d["spec"].update(overview="Judges score each submission. See C-900 for the rules."))
        rc, lines, _ = self.docs()
        self.assertEqual(rc, 1)
        self.assertIn("SKIP\twording\tpage Overview: looks like an id: C-900", lines)
        self.assertNotIn("Overview", self.names())
        self.assertEqual(self.names(parent="Scenarios"), [JUDGE_CARD, ADMIN_CARD])   # the others are written
        self.assertNotIn("C-900", json.dumps(self.fake.calls))

    def test_build_number_of_a_run_label_is_let_through(self):
        self.add_run(RUN_1, manifest={"build": "v1.4.46 (next@beb2492a7) nightly"})
        self.synced()
        rc, lines, err = self.docs("--run", RUN_1)
        self.assertEqual(rc, 0, (lines, err))
        name = "Run 1 · 2026-11-27 v1.4.46"
        self.assertEqual(self.names(parent="Results"), [name])
        self.assertIn(f"{name}: failed", self.page(JUDGE_CARD, "Scenarios")["content"])
        self.assertIn(f"Latest run: {name}.", self.dashboard())

    def test_run_that_was_never_synced_is_a_failure(self):
        rc, lines, _ = self.docs("--run", RUN_1)
        self.assertEqual(rc, 1)
        self.assertIn("SKIP\trun-not-synced\tthis run has no list in ClickUp yet; run sync-run first", lines)

    def test_needs_spec_init_first(self):
        self.new_project()
        rc, lines, _ = self.docs()
        self.assertEqual(rc, 1)
        self.assertTrue(any(ln.startswith("SKIP\tnot-ready\t") for ln in lines), lines)
        self.assertEqual(self.fake.calls, [])


class RecoveryTests(DocsBase):
    def test_doc_create_that_landed_behind_an_error_is_not_repeated(self):
        self.synced()
        self.fail_after("POST", r"/docs$")
        rc, lines, err = self.docs()
        self.assertEqual(rc, 0, (lines, err))
        self.assertIn("APPLY\treconciled\tQA overview: the create had landed", lines)
        self.assertEqual(self.cfg()["ids"]["overviewDoc"], self.overview_doc()["id"])
        self.assertEqual(self.docs()[0], 0)
        self.overview_doc()   # still one

    def test_doc_create_that_failed_is_made_on_the_next_run(self):
        self.synced()
        self.fail_after("POST", r"/docs$", lands=False)
        rc, lines, _ = self.docs()
        self.assertEqual(rc, 1)
        self.assertNotIn("overviewDoc", self.cfg()["ids"])
        self.assertEqual(self.docs()[0], 0)
        self.assertIn(TITLE, self.dashboard())

    def test_page_create_that_landed_behind_an_error_is_not_repeated(self):
        self.synced()
        self.fail_after("POST", r"/pages$", times=2)
        rc, lines, err = self.docs()
        self.assertEqual(rc, 0, (lines, err))
        self.assertIn("APPLY\treconciled\tScenarios: the create had landed", lines)
        self.assertEqual(self.names(), ["Overview", "Scenarios", "Results"])
        self.assertEqual(self.names(parent="Scenarios"), [JUDGE_CARD, ADMIN_CARD])
        self.fake.calls.clear()
        self.assertEqual(self.docs()[0], 0)
        self.assertEqual(self.fake.calls, [])

    def test_page_create_that_failed_is_made_on_the_next_run(self):
        self.synced()
        self.fail_after("POST", r"/pages$", lands=False)
        rc, lines, _ = self.docs()
        self.assertEqual(rc, 1)
        self.assertTrue(any(ln.startswith("SKIP\tapi-error\tScenarios: HTTP 502") for ln in lines), lines)
        self.assertEqual(self.docs()[0], 0)
        self.assertEqual(sorted(self.names()), ["Overview", "Results", "Scenarios"])
        self.assertEqual(self.names(parent="Scenarios"), [JUDGE_CARD, ADMIN_CARD])

    def test_spec_doc_is_found_or_made_when_the_config_lost_it(self):
        self.synced()
        doc = self.spec_doc()
        self.edit_cfg(lambda d: d["specs"][TARGET].pop("doc"))
        self.assertEqual(self.docs()[0], 0)
        self.assertEqual(self.spec_doc(), doc)
        self.assertEqual(len([d for d in self.fake.docs.values() if d["name"] == TITLE]), 1)


class ProjectDocTests(DocsBase):
    def test_project_doc_created_once_and_id_saved(self):
        self.synced()
        before = self.cfg()
        rc, lines, err = self.docs()
        self.assertEqual(rc, 0, (lines, err))
        doc = self.overview_doc()
        self.assertEqual(doc["parent"], {"id": QA, "type": 5})
        after = self.cfg()
        self.assertEqual(after["ids"], dict(before["ids"], overviewDoc=doc["id"]))
        self.assertEqual({k: v for k, v in after.items() if k != "ids"}, {k: v for k, v in before.items() if k != "ids"})
        self.assertEqual(list(after), list(before))
        self.assertEqual(self.cfg_path.read_text(encoding="utf-8"), json.dumps(after, indent=2, ensure_ascii=False) + "\n")
        self.assertEqual(self.names(doc=doc["id"]), ["QA overview"])
        self.assertEqual(self.dashboard(),
                         f"# QA overview\n\n## Specs\n\n[{TITLE}]({self.doc_url()}). Latest run: {RUN_PAGE_1}. "
                         f"1 testing, 1 failed. "
                         f"Ready to ship: not known.\n\n## Open bugs\n\nNo open bugs.\n")
        self.fake.calls.clear()
        self.assertEqual(self.docs()[0], 0)
        self.assertEqual(self.fake.calls, [])
        self.overview_doc()

    def test_spec_without_a_run_says_so(self):
        self.pushed()
        self.assertIn(f"[{TITLE}]({self.doc_url()}). No run yet.", self.dashboard())
        self.assertEqual(self.names(parent="Results"), [])

    def test_every_tracked_spec_is_listed_and_one_that_cannot_be_read_is_not_known(self):
        self.synced()
        self.edit_cfg(lambda d: d["specs"].update({
            "team-registration": {"enabled": True, "folder": "F404", "title": "Teams register for the hackathon"},
            "certificates": {"enabled": False}}))
        rc, lines, err = self.docs()
        self.assertEqual(rc, 0, (lines, err))
        page = self.dashboard()
        self.assertIn("| Spec | Latest run | Results | Ready to ship |", page)
        self.assertIn(f"| [{TITLE}]({self.doc_url()}) | {RUN_PAGE_1} | 1 testing, 1 failed | Not known |", page)
        self.assertIn("| Teams register for the hackathon | Not known |  | Not known |", page)
        self.assertNotIn("ertificates", page)
        self.assertNotIn("F404", page)

    def test_open_bugs_come_from_the_bugs_list(self):
        self.synced()
        bugs = self.tmp / ".qa" / "runs" / RUN_1 / "bugs"
        bugs.mkdir(exist_ok=True)
        (bugs / "bugs.json").write_text(json.dumps([{"title": BUG_TITLE, "criterionId": "C-SCORE-02",
                                                     "persona": "judge", "severity": "high"}]), encoding="utf-8")
        mine = self.fake.add_bug(BUG_TITLE, core.fingerprint("C-SCORE-02", "judge", BUG_TITLE))
        mine["priority"] = {"id": "2"}
        other = self.fake.add_bug("Team name is cut off on the certificate",
                                  core.fingerprint("C-CERT-01", "admin", "Team name is cut off on the certificate"))
        done = self.fake.add_bug("Ranking shows a team twice",
                                 core.fingerprint("C-RANK-01", "judge", "Ranking shows a team twice"), "closed")
        self.pushed()
        results = self.page(RUN_PAGE_1, "Results")["content"]
        link = f"[{BUG_TITLE}](https://app.clickup.com/t/{mine['id']}), high."
        self.assertIn(f"## Open bugs\n\n{link}\n", results)       # the run's own open bug only
        self.assertNotIn("certificate", results)
        page = self.dashboard()
        self.assertIn(f"| [{BUG_TITLE}](https://app.clickup.com/t/{mine['id']}) | high |", page)
        self.assertIn(f"| [Team name is cut off on the certificate](https://app.clickup.com/t/{other['id']}) |", page)
        self.assertNotIn(done["name"], page)
        # bugs kept in the project's issue tracker are not shown
        self.edit_cfg(lambda d: d.update(bugsTo="issue-tracker"))
        self.pushed()
        self.assertIn("No open bugs.", self.dashboard())
        self.assertIn("No open bugs.", self.page(RUN_PAGE_1, "Results")["content"])


    def test_bug_title_that_breaks_the_writing_rules_is_shown_as_open_bug(self):
        self.synced()
        title = "Score C-900 is saved twice"
        bugs = self.tmp / ".qa" / "runs" / RUN_1 / "bugs"
        bugs.mkdir(exist_ok=True)
        (bugs / "bugs.json").write_text(json.dumps([{"title": title, "criterionId": "C-SCORE-02",
                                                     "persona": "judge", "severity": "high"}]), encoding="utf-8")
        bug = self.fake.add_bug(title, core.fingerprint("C-SCORE-02", "judge", title))
        bug["priority"] = {"id": "2"}
        rc, lines, err = self.docs()
        self.assertEqual(rc, 0, (lines, err))
        link = f"[Open bug](https://app.clickup.com/t/{bug['id']}), high."
        self.assertIn(f"## Open bugs\n\n{link}\n", self.page(RUN_PAGE_1, "Results")["content"])
        self.assertIn(f"## Open bugs\n\n{link}\n", self.dashboard())
        self.assertNotIn("C-900", json.dumps(self.fake.calls))
        self.assertNotIn("C-900", "\n".join(lines))
        self.assertEqual([ln for ln in lines if ln.startswith("SKIP\t")],
                         ["SKIP\tbug-title\ta bug title does not follow the writing rules; "
                          "the pages show it as Open bug"])
        self.fake.calls.clear()
        self.assertEqual(self.docs()[0], 0)
        self.assertEqual(self.fake.calls, [])


class ProjectReadyTests(DocsBase):
    """The project page's ready word follows the tickets as they stand now, not only the summary."""

    def ready_run(self):
        """Run 2 passed everything and its report says ready; both runs are on their lists."""
        self.synced()
        self.add_run(RUN_2, ALL_PASS)
        self.report(run=RUN_2)
        self.synced(RUN_2)
        self.assertIn("Ready to ship.", self.summary(self.lists()[1]["id"])["markdown_description"])
        return self.lists()[1]["id"]

    def test_ready_when_the_summary_says_so_and_every_scenario_ticket_passed(self):
        self.ready_run()
        row = self.project_rows()[TITLE]
        self.assertIs(row["ready"], True)
        self.assertEqual((row["counts"]["passed"], row["counts"]["to_test"]), (2, 0))
        self.assertIn(f"Latest run: {RUN_PAGE_2}. 2 passed. Ready to ship: yes.\n", self.dashboard())

    def test_not_ready_when_a_ticket_was_moved_after_the_summary_was_written(self):
        second = self.ready_run()
        for status in ("failed", "blocked", "testing", "to test"):
            with self.subTest(status=status):
                self.fake.task(JUDGE_CARD, second)["status"]["status"] = status
                row = self.project_rows()[TITLE]
                self.assertIs(row["ready"], False)
                self.assertEqual(row["counts"]["passed"], 1)
                self.assertIn(f"1 {status}, 1 passed. Ready to ship: no.\n", self.dashboard())

    def test_not_ready_while_a_result_waits_for_a_persons_review(self):
        second = self.ready_run()
        self.fake.task(JUDGE_CARD, second)["values"]["f-review"] = True
        row = self.project_rows()[TITLE]
        self.assertIs(row["ready"], False)
        self.assertEqual(row["counts"]["needs_review"], 1)

    def test_only_skipped_tickets_are_not_ready(self):
        second = self.ready_run()
        for name in (JUDGE_CARD, ADMIN_CARD):
            self.fake.task(name, second)["status"]["status"] = "skipped"
        self.assertIs(self.project_rows()[TITLE]["ready"], False)

    def test_half_filled_list_is_not_known_and_counts_the_missing_scenarios(self):
        second = self.ready_run()
        gone = self.fake.task(ADMIN_CARD, second)["id"]
        for tid in [t["id"] for t in self.fake.tasks.values() if gone in (t["id"], t["parent"])]:
            del self.fake.tasks[tid]
        row = self.project_rows()[TITLE]
        self.assertIs(row["ready"], None)
        self.assertEqual((row["counts"]["passed"], row["counts"]["to_test"]), (1, 1))
        self.assertIn("1 to test, 1 passed. Ready to ship: not known.\n", self.dashboard())

    def test_summary_that_says_not_ready_stays_no(self):
        self.synced()
        self.report("# Judging report\n\n## Ship readiness\n\n**NOT SHIP-READY**\n\n- 1 P1 criterion failed\n")
        self.synced()
        self.assertIn("Not ready to ship.", self.summary()["markdown_description"])
        self.assertIs(self.project_rows()[TITLE]["ready"], False)

    def test_spec_whose_tickets_cannot_be_read_is_not_known(self):
        self.ready_run()
        self.edit_cfg(lambda d: d["specs"].update({
            "team-registration": {"enabled": True, "folder": "F404", "title": "Teams register for the hackathon"}}))
        rows = self.project_rows()
        self.assertIs(rows["Teams register for the hackathon"]["ready"], None)
        self.assertEqual(rows["Teams register for the hackathon"]["counts"], {})
        self.assertIs(rows[TITLE]["ready"], True)


class ResultsLinkTests(DocsBase):
    def test_results_link_is_on_the_run_summary_and_every_sync_keeps_it(self):
        self.fake.doc_urls = True
        self.synced()
        self.pushed("--run", RUN_1)
        page = self.page(RUN_PAGE_1, "Results")["id"]
        line = f"Full results: https://app.clickup.com/{WS}/v/dc/{self.spec_doc()}/{page}"
        text = self.summary()["markdown_description"]
        self.assertEqual(text, "5 checks: 1 to test, 1 testing, 1 failed, 1 blocked, 1 passed.\n\n"
                               f"A person needs to confirm 1 result.\n\n{line}")
        self.assertEqual(self.sync()[0], 0)
        self.assertEqual(self.docs("--run", RUN_1)[0], 0)
        self.assertEqual(self.fake.calls, [])
        self.assertEqual(self.summary()["markdown_description"], text)
        # the links ClickUp gave are the ones the dashboard uses
        self.assertIn(f"[{TITLE}](https://app.clickup.com/{WS}/v/dc/{self.spec_doc()}).", self.dashboard())

    def test_links_are_built_from_ids_when_clickup_returns_none(self):
        self.synced()
        lines = self.pushed("--run", RUN_1)
        page = self.page(RUN_PAGE_1, "Results")["id"]
        line = f"Full results: https://app.clickup.com/{WS}/v/dc/{self.spec_doc()}/{page}"
        text = self.summary()["markdown_description"]
        self.assertEqual(text, "5 checks: 1 to test, 1 testing, 1 failed, 1 blocked, 1 passed.\n\n"
                               f"A person needs to confirm 1 result.\n\n{line}")
        self.assertFalse(any("no-results-link" in ln for ln in lines), lines)
        self.assertIn(f"[{TITLE}]({self.doc_url()}).", self.dashboard())
        # the line is written once and every sync keeps it
        self.assertEqual(self.sync()[0], 0)
        self.assertEqual(self.docs("--run", RUN_1)[0], 0)
        self.assertEqual(self.fake.calls, [])
        self.assertEqual(self.summary()["markdown_description"], text)


class LinkTests(unittest.TestCase):
    BASE = "https://app.clickup.com"

    def link_of(self, *args, **kw):
        from trackers import clickup_spec_docs as docs
        return docs.link_of(*args, **kw)

    def test_each_standard_form_is_built_from_ids(self):
        for kind, args, want in (
                ("task", {}, "/t/86c2xk4"),
                ("list", {"ws": "9001"}, "/9001/v/li/86c2xk4"),
                ("folder", {"ws": "9001"}, "/9001/v/f/86c2xk4"),
                ("doc", {"ws": "9001"}, "/9001/v/dc/86c2xk4"),
                ("page", {"ws": "9001", "doc": "2ky4-311"}, "/9001/v/dc/2ky4-311/86c2xk4")):
            with self.subTest(kind=kind):
                self.assertEqual(self.link_of({"id": "86c2xk4"}, kind, **args), self.BASE + want)
                self.assertEqual(self.link_of("86c2xk4", kind, **args), self.BASE + want)
                self.assertEqual(self.link_of({"id": 86024}, kind, **args), self.BASE + want.replace("86c2xk4", "86024"))

    def test_link_clickup_returned_is_preferred(self):
        given = "https://app.clickup.com/9001/v/dc/2ky4-311/2ky4-99?block=x"
        self.assertEqual(self.link_of({"id": "86c2xk4", "url": given}, "page", ws="9001", doc="2ky4-311"), given)
        self.assertEqual(self.link_of({"id": "86c2xk4", "url": given}), given)
        # anything else than an https link is not used; the standard form is
        self.assertEqual(self.link_of({"id": "86c2xk4", "url": "javascript:alert(1)"}, "task"), self.BASE + "/t/86c2xk4")

    def test_id_that_is_not_plain_is_refused(self):
        for bad in ("../../settings", "86c2/xk4", "86c2xk4?x=1", "86c2xk4#x", "86 c2", "<new:Results>", "86c2xk4\n",
                    "٨٦", "", None, True, {"id": "a/b"}, {}):
            with self.subTest(bad=bad):
                for kind in ("task", "list", "folder", "doc", "page"):
                    self.assertIsNone(self.link_of(bad, kind, ws="9001", doc="2ky4-311"))
        for kind in ("list", "folder", "doc", "page"):
            with self.subTest(kind=kind):
                self.assertIsNone(self.link_of("86c2xk4", kind, ws="9001/x", doc="2ky4-311"))
        self.assertIsNone(self.link_of("86c2xk4", "page", ws="9001", doc="2ky4/../311"))

    def test_missing_workspace_or_doc_or_kind_gives_no_link(self):
        for kind in ("list", "folder", "doc", "page"):
            self.assertIsNone(self.link_of("86c2xk4", kind))
            self.assertIsNone(self.link_of("86c2xk4", kind, ws=""))
        self.assertIsNone(self.link_of("86c2xk4", "page", ws="9001"))
        self.assertIsNone(self.link_of({"id": "86c2xk4"}))
        self.assertIsNone(self.link_of({"id": "86c2xk4"}, "space", ws="9001"))


class ResultsPageIdentityTests(DocsBase):
    RENAMED = "Run 1 · 2026-11-27 evening"

    def relabel(self):
        self.lists()[0]["name"] = self.RENAMED

    def assert_renamed(self, page):
        rc, lines, err = self.docs()
        self.assertEqual(rc, 0, (lines, err))
        self.assertEqual(self.names(parent="Results"), [self.RENAMED])
        self.assertEqual(self.page(self.RENAMED, "Results")["id"], page)
        self.assertTrue(self.page(self.RENAMED, "Results")["content"].startswith(f"# {self.RENAMED}\n"))
        self.assertEqual(self.fake.writes("POST", r"/pages$"), [])
        self.fake.calls.clear()
        self.assertEqual(self.docs()[0], 0)
        self.assertEqual(self.fake.calls, [])

    def test_changed_label_renames_the_results_page(self):
        self.synced()
        self.pushed()
        page = self.page(RUN_PAGE_1, "Results")["id"]
        self.relabel()
        self.assert_renamed(page)

    def test_changed_label_renames_the_results_page_on_a_machine_without_the_cache(self):
        self.synced()
        self.pushed()
        page = self.page(RUN_PAGE_1, "Results")["id"]
        self.no_cache()
        self.relabel()
        self.assert_renamed(page)

    def test_page_a_person_renamed_is_found_by_the_remembered_id(self):
        self.synced()
        self.pushed()
        page = self.page(RUN_PAGE_1, "Results")
        page["name"] = "First judging round"
        self.relabel()
        self.assert_renamed(page["id"])

    def test_each_run_keeps_its_own_page(self):
        self.synced()
        self.add_run(RUN_2, ALL_PASS)
        self.synced(RUN_2)
        self.pushed()
        self.no_cache()
        self.relabel()
        self.assertEqual(self.docs()[0], 0)
        self.assertEqual(self.names(parent="Results"), [self.RENAMED, RUN_PAGE_2])


class NotifyTests(DocsBase):
    SENTENCE = f"The results of {RUN_PAGE_1} are ready to read."

    def mentions(self):
        return [c for rows in self.fake.comments.values() for c in rows if "comment" in c]

    def test_notify_once_per_run(self):
        self.edit_cfg(lambda d: d["specs"][TARGET].update(notify={"user": LEAD, "on": "verified"}))
        self.synced()
        self.verify()
        self.pushed()                       # no run named: nobody is told
        self.assertEqual(self.mentions(), [])
        rc, lines, err = self.docs("--run", RUN_1, apply=False)
        self.assertEqual(rc, 0, (lines, err))
        self.assertEqual(self.mentions(), [])
        for _ in range(2):
            rc, lines, err = self.docs("--run", RUN_1)
            self.assertEqual(rc, 0, (lines, err))
        self.assertEqual(self.mentions(), [{"comment": [{"text": self.SENTENCE + " "},
                                                        {"type": "tag", "user": {"id": LEAD}}],
                                            "notify_all": False}])
        self.assertEqual([c for c in self.fake.comments[self.summary()["id"]] if "comment" in c], self.mentions())
        # the next run gets its own
        self.add_run(RUN_2, ALL_PASS)
        self.synced(RUN_2)
        self.verify(RUN_2)
        self.pushed("--run", RUN_2)
        self.assertEqual(len(self.mentions()), 2)

    def test_no_mention_for_a_run_that_is_not_verified(self):
        self.edit_cfg(lambda d: d["specs"][TARGET].update(notify={"user": LEAD, "on": "verified"}))
        self.synced()                       # on its list, and not verified
        run_dir = self.tmp / ".qa" / "runs" / RUN_1
        said = f"SKIP\tnot-verified\t{RUN_PAGE_1}: this run is not verified yet; no one was mentioned"
        for have in ((), ("verification.json",), ("report.md",)):
            with self.subTest(have=have):
                for name in ("verification.json", "report.md"):
                    if (run_dir / name).exists():
                        (run_dir / name).unlink()
                for name in have:
                    (run_dir / name).write_text("{}" if name.endswith(".json") else "# Judging report\n", encoding="utf-8")
                for apply in (False, True, True):
                    rc, lines, err = self.docs("--run", RUN_1, apply=apply)
                    self.assertEqual(rc, 0, (lines, err))     # said, and not a failure
                    self.assertEqual(lines.count(said), 1, lines)
                self.assertEqual(self.mentions(), [])
                self.assertEqual(self.fake.writes("POST", r"/comment"), [])
                self.assertNotIn('"tag"', json.dumps(self.fake.calls))
                self.assertNotIn(str(LEAD), json.dumps(self.fake.calls))
        # once it is verified its person is told, once
        self.verify()
        for _ in range(2):
            rc, lines, err = self.docs("--run", RUN_1)
            self.assertEqual(rc, 0, (lines, err))
            self.assertNotIn(said, lines)
        self.assertEqual(len(self.mentions()), 1)
        self.assertEqual(len(self.fake.writes("POST", r"/comment")), 1)

    def test_not_verified_is_not_said_when_nobody_is_to_be_told(self):
        self.synced()
        rc, lines, err = self.docs("--run", RUN_1)
        self.assertEqual(rc, 0, (lines, err))
        self.assertFalse(any("not-verified" in ln for ln in lines), lines)

    def test_mention_is_not_repeated_behind_many_newer_comments(self):
        self.edit_cfg(lambda d: d["specs"][TARGET].update(notify={"user": LEAD, "on": "verified"}))
        self.synced()
        self.verify()
        self.pushed("--run", RUN_1)
        self.assertEqual(len(self.mentions()), 1)
        self.fake.comments[self.summary()["id"]] += [
            {"comment_text": f"Round {i} of the judging screen was checked again.", "notify_all": False}
            for i in range(1, 61)]
        rc, lines, err = self.docs("--run", RUN_1)
        self.assertEqual(rc, 0, (lines, err))
        self.assertEqual(self.fake.calls, [])
        self.assertEqual(len(self.mentions()), 1)

    def test_no_notify_by_default(self):
        self.synced()
        rc, lines, err = self.docs("--run", RUN_1)
        self.assertEqual(rc, 0, (lines, err))
        self.assertEqual(self.mentions(), [])
        self.assertEqual(self.fake.writes("POST", r"/comment$"), [])
        self.assertNotIn('"tag"', json.dumps(self.fake.calls))

    def test_no_mention_while_a_page_could_not_be_written(self):
        self.edit_cfg(lambda d: d["specs"][TARGET].update(notify={"user": LEAD, "on": "verified"}))
        self.synced()
        self.verify()
        self.fail_after("POST", r"/pages$", lands=False)
        self.assertEqual(self.docs("--run", RUN_1)[0], 1)
        self.assertEqual(self.mentions(), [])

    def test_notify_that_is_not_understood_stops_before_anything_is_sent(self):
        self.edit_cfg(lambda d: d["specs"][TARGET].update(notify={"user": "the QA lead", "on": "verified"}))
        self.synced()
        rc, _, err = self.docs("--run", RUN_1)
        self.assertEqual(rc, 1)
        self.assertIn("notify", err)
        self.assertEqual(self.fake.calls, [])


class SpecNoteTests(DocsBase):
    def test_spec_note_posts_once(self):
        rc, lines, err = self.note()
        self.assertEqual(rc, 0, (lines, err))
        summary = self.summary()["id"]
        self.assertEqual(self.fake.calls, [("POST", f"/v2/task/{summary}/comment",
                                            {"comment_text": NOTE, "notify_all": False})])
        self.assertEqual(self.note()[0], 0)
        self.assertEqual(len(self.fake.calls), 1)
        self.assertEqual(self.state("Run summary"), ("to test", "t"))
        self.assertNotIn("analysis-note", json.dumps(self.fake.calls))

    def test_spec_note_is_not_posted_again_behind_many_newer_comments(self):
        self.assertEqual(self.note()[0], 0)
        self.fake.comments[self.summary()["id"]] += [
            {"comment_text": f"Round {i} of the judging screen was checked again.", "notify_all": False}
            for i in range(1, 61)]
        self.fake.calls.clear()
        self.assertEqual(self.note()[0], 0)
        self.assertEqual(self.fake.calls, [])
        self.assertEqual(self.texts("Run summary").count(NOTE), 1)

    def test_spec_note_dry_run_sends_nothing(self):
        rc, lines, _ = self.note(NOTE, "--blocked", apply=False)
        self.assertEqual(rc, 0, lines)
        self.assertEqual(self.fake.calls, [])
        self.assertIn("DRY\tcomment\tRun summary: note", lines)
        self.assertIn("DRY\tstatus\tRun summary: blocked", lines)

    def test_spec_note_blocked_sets_status(self):
        rc, lines, err = self.note(NOTE, "--blocked")
        self.assertEqual(rc, 0, (lines, err))
        self.assertEqual(self.state("Run summary"), ("blocked", "b"))
        summary = self.summary()
        # the status and its mark only: no other field, no text of the ticket
        puts = [c for c in self.fake.writes("PUT") if c[1] == f"/v2/task/{summary['id']}"]
        self.assertEqual([c[2] for c in puts], [{"status": "blocked"}])
        self.assertEqual({c[1] for c in self.fake.writes("POST", r"/field/")}, {f"/v2/task/{summary['id']}/field/f-ref"})
        self.assertEqual(summary["markdown_description"], "")
        self.fake.calls.clear()
        self.assertEqual(self.note(NOTE, "--blocked")[0], 0)
        self.assertEqual(self.fake.calls, [])

    def test_blocked_summary_follows_the_next_sync_and_is_not_a_persons_change(self):
        self.assertEqual(self.note(NOTE, "--blocked")[0], 0)
        self.add_run(RUN_1, ALL_PASS)
        rc, lines, err = self.sync()
        self.assertEqual(rc, 0, (lines, err))
        self.assertFalse(any("changed-by-person" in ln for ln in lines), lines)
        self.assertEqual(self.state("Run summary"), ("passed", "p"))
        self.assertEqual(self.texts("Run summary"), [NOTE])

    def test_blocked_leaves_a_summary_a_person_moved(self):
        self.move("Run summary", "passed")
        rc, lines, _ = self.note(NOTE, "--blocked")
        self.assertEqual(rc, 0, lines)
        self.assertIn("SKIP\tchanged-by-person\tRun summary", lines)
        self.assertEqual(self.state("Run summary"), ("passed", "t"))
        self.assertEqual(self.texts("Run summary"), [NOTE])

    def test_spec_note_lint_failure_rc1(self):
        for text, why in (("Coverage gaps were found by the automated review.", "forbidden word: automated"),
                          ("C-SCORE-02 has no check for a score of zero.", "looks like an id: C-SCORE-02"),
                          ("Ask @noura to confirm the scoring rules.", "mentions a person"),
                          ("  \n", "empty")):
            with self.subTest(why=why):
                rc, lines, _ = self.note(text, "--blocked")
                self.assertEqual(rc, 1)
                self.assertIn(f"SKIP\twording\tnote: {why}", lines)
                self.assertEqual(self.fake.calls, [])

    def test_spec_note_needs_its_file(self):
        rc, _, err = self.tracker("spec-note")
        self.assertEqual(rc, 1)
        self.assertIn("--file", err)
        rc, _, err = self.tracker("spec-note", "--file", str(self.tmp / "missing-note.md"))
        self.assertEqual(rc, 1)
        self.assertEqual(self.fake.calls, [])

    def test_note_goes_to_the_open_list_else_the_latest_or_the_named_run(self):
        self.synced()
        self.assertEqual(self.note()[0], 0)                     # no open list: the latest one
        self.assertEqual(self.texts("Run summary"), [NOTE])
        self.assertEqual(self.push()[0], 0)                     # list 2 is the open one now
        first, second = self.lists()
        other = "The plan now covers the score history. It is ready for the next run."
        self.assertEqual(self.note(other)[0], 0)
        self.assertEqual(self.texts("Run summary", second["id"]), [other])
        third = "The export still has no check."
        self.assertEqual(self.note(third, "--run", RUN_1)[0], 0)
        self.assertEqual(self.texts("Run summary", first["id"]), [NOTE, third])

    def test_note_without_a_run_summary_is_a_failure(self):
        self.new_project()
        self.ready()
        rc, lines, _ = self.note()
        self.assertEqual(rc, 1)
        self.assertIn("SKIP\tno-run-summary\tthere is no Run summary ticket yet; run push-scenarios first", lines)
        self.assertEqual(self.fake.calls, [])


class SpecStatusTests(DocsBase):
    def frozen(self):
        """Everything a read-only verb must leave as it is: the calls, the config, the cache."""
        cache = self.tmp / ".qa" / "tracker-map.json"
        return (list(self.fake.calls), self.cfg_path.read_text(encoding="utf-8"),
                cache.read_text(encoding="utf-8") if cache.exists() else None,
                json.dumps({"tasks": self.fake.tasks, "pages": self.fake.pages, "docs": self.fake.docs,
                            "comments": self.fake.comments, "lists": self.fake.lists}, sort_keys=True, default=str))

    def test_spec_status_makes_no_writes(self):
        for step in ("pushed scenarios", "synced", "docs pushed", "cards changed"):
            if step == "synced":
                self.synced()
            elif step == "docs pushed":
                self.pushed("--run", RUN_1)
            elif step == "cards changed":
                self.edit_cards(lambda d: d["cards"][0].update(title="A judge scores one team submission"))
            with self.subTest(step=step):
                self.fake.calls.clear()
                before = self.frozen()
                rc, out, lines = self.status()
                self.assertEqual(rc, 0, lines)
                self.assertEqual(self.fake.calls, [])
                self.assertEqual(self.frozen(), before)
                self.assertEqual(list(out), KEYS)
                self.assertEqual(lines, [json.dumps(out, ensure_ascii=False)])   # one JSON line, nothing else

    def test_spec_status_no_list_yet(self):
        self.new_project()
        self.ready()
        rc, out, lines = self.status()
        self.assertEqual(rc, 0, lines)
        folder = self.cfg()["specs"][TARGET]["folder"]
        self.assertEqual(out, {"spec": TARGET, "folderUrl": f"https://app.clickup.com/{WS}/v/f/{folder}",
                               "docUrl": self.doc_url(), "list": None, "behind": True,
                               "reasons": ["there is no run list yet", "a Doc page is not up to date"]})

    def test_spec_status_not_set_up_in_clickup(self):
        self.new_project()
        rc, out, lines = self.status()
        self.assertEqual(rc, 0, lines)
        self.assertEqual(out, {"spec": TARGET, "folderUrl": None, "docUrl": None, "list": None, "behind": True,
                               "reasons": ["the spec is not set up in ClickUp yet"]})
        self.assertEqual(self.fake.calls, [])

    def test_spec_status_up_to_date(self):
        self.fake.doc_urls = True
        self.synced()
        self.pushed("--run", RUN_1)
        rc, out, lines = self.status()
        self.assertEqual(rc, 0, lines)
        folder = self.cfg()["specs"][TARGET]["folder"]
        self.assertEqual(out, {"spec": TARGET, "folderUrl": f"https://app.clickup.com/{WS}/v/f/{folder}",
                               "docUrl": self.doc_url(),
                               "list": {"n": 1, "url": f"https://app.clickup.com/{WS}/v/li/{self.lists()[0]['id']}",
                                        "bound": True},
                               "behind": False, "reasons": []})

    def test_spec_status_open_list_up_to_date(self):
        self.no_runs()
        self.pushed()
        rc, out, _ = self.status()
        self.assertEqual((rc, out["behind"], out["reasons"]), (0, False, []))
        self.assertEqual(out["list"]["bound"], False)

    def test_spec_status_behind_when_cards_changed(self):
        self.no_runs()
        self.pushed()
        self.edit_cards(lambda d: d["cards"][0].update(title="A judge scores one team submission"))
        rc, out, lines = self.status()
        self.assertEqual(rc, 0, lines)        # behind is an answer, not a failure
        self.assertIs(out["behind"], True)
        self.assertEqual(out["reasons"], ["the scenario tickets do not match the cards file",
                                          "a Doc page is not up to date"])
        # once both are pushed it is up to date again
        self.assertEqual(self.push()[0], 0)
        self.pushed()
        self.assertEqual(self.status()[1]["reasons"], [])

    def test_spec_status_behind_when_cards_changed_after_a_run(self):
        self.synced()
        self.pushed()
        self.add_check()
        self.assertEqual(self.status()[1]["reasons"], ["the scenario tickets do not match the cards file",
                                                       "a Doc page is not up to date"])

    def test_spec_status_behind_when_a_run_is_not_synced_or_changed(self):
        self.pushed()
        self.assertEqual(self.status()[1]["reasons"], ["the newest run's results are not in ClickUp yet"])
        self.synced()
        self.assertEqual(self.status()[1]["reasons"], ["a Doc page is not up to date"])
        self.pushed()
        self.assertEqual(self.status()[1]["reasons"], [])
        self.record(RUN_1, [row("C-SCORE-01", "judge", "fail")])
        self.assertEqual(self.status()[1]["reasons"], ["the newest run's results differ from the tickets",
                                                       "a Doc page is not up to date"])

    def test_spec_status_behind_when_a_page_was_changed(self):
        self.synced()
        self.pushed()
        self.page("Overview")["content"] = "Judges score submissions."
        rc, out, _ = self.status()
        self.assertEqual((rc, out["behind"], out["reasons"]), (0, True, ["a Doc page is not up to date"]))

    def test_spec_status_says_when_the_cards_cannot_be_read(self):
        self.cards_path.write_text("{", encoding="utf-8")
        rc, out, _ = self.status()
        self.assertEqual(rc, 0)
        self.assertEqual(out["reasons"], ["the cards file cannot be read"])
        self.assertEqual(out["list"], {"n": 1, "url": f"https://app.clickup.com/{WS}/v/li/{self.lists()[0]['id']}",
                                       "bound": False})

    def test_spec_status_says_when_the_latest_run_cannot_be_read(self):
        self.synced()
        self.pushed()
        self.assertEqual(self.status()[1]["reasons"], [])
        (self.tmp / ".qa" / "runs" / RUN_1 / "checkpoint.json").write_text("{", encoding="utf-8")
        rc, out, _ = self.status()
        self.assertEqual((rc, out["behind"], out["reasons"]), (0, True, ["the latest run could not be read"]))

    def test_spec_status_with_a_named_run_that_is_not_there_has_nothing_to_compare(self):
        self.synced()
        self.pushed()
        rc, out, _ = self.status("--run", "2026-11-30-judge-scoring")
        self.assertEqual((rc, out["behind"], out["reasons"]), (0, False, []))


class WordingPinTests(unittest.TestCase):
    def test_ready_sentences_are_the_ones_the_results_page_writes(self):
        from trackers import clickup_spec_docs as docs
        cfg = core.load_config(Path(__file__).resolve().parent / "fixtures" / "spec" / "project")
        none = spec_runs.CheckState("card", "check", "judge", "passed")
        blank = type("Plan", (), {"cards": []})()
        self.assertIn(f"\n{docs.SAID_READY}\n", spec_docs.results_page("Run", [none], blank, {}, [], (True, []), None, cfg))
        self.assertIn(f"\n{docs.SAID_NOT_READY}\n",
                      spec_docs.results_page("Run", [none], blank, {}, [], (False, []), None, cfg))


if __name__ == "__main__":
    unittest.main()
