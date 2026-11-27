"""`push-docs`, `spec-note` and `spec-status` through cli.main, against the in-memory ClickUp
space of the structure and sync tests (its Docs, pages and comment parts are in `SpecFake`).
"""
from __future__ import annotations

import json
import shutil
import sys
import unittest
from pathlib import Path

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
        found = [ln for ln in lines if ln.startswith("{")]
        self.assertEqual(len(found), 1, (lines, err))
        return rc, json.loads(found[0]), lines

    def note(self, text=NOTE, *extra, apply=True):
        path = self.tmp / "analysis-note.md"
        path.write_text(text, encoding="utf-8")
        return self.tracker("spec-note", "--file", str(path), *extra, apply=apply)

    def report(self, text=READY_REPORT, run=RUN_1):
        (self.tmp / ".qa" / "runs" / run / "report.md").write_text(text, encoding="utf-8")

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
                         f"# QA overview\n\n## Specs\n\n{TITLE}. Latest run: {RUN_PAGE_1}. 1 testing, 1 failed. "
                         f"Ready to ship: not known.\n\n## Open bugs\n\nNo open bugs.\n")
        self.fake.calls.clear()
        self.assertEqual(self.docs()[0], 0)
        self.assertEqual(self.fake.calls, [])
        self.overview_doc()

    def test_spec_without_a_run_says_so(self):
        self.pushed()
        self.assertIn(f"{TITLE}. No run yet.", self.dashboard())
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
        self.assertIn(f"| {TITLE} | {RUN_PAGE_1} | 1 testing, 1 failed | Not known |", page)
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

    def test_no_link_is_made_up_when_clickup_gives_none(self):
        self.synced()
        lines = self.pushed("--run", RUN_1)
        self.assertNotIn("Full results", self.summary()["markdown_description"])
        self.assertIn("SKIP\tno-results-link\tClickUp gave no link to the Results page; "
                      "the Run summary has no link to it", lines)
        self.assertNotIn("app.clickup.com/9001", json.dumps(self.fake.calls))


class NotifyTests(DocsBase):
    SENTENCE = f"The results of {RUN_PAGE_1} are ready to read."

    def mentions(self):
        return [c for rows in self.fake.comments.values() for c in rows if "comment" in c]

    def test_notify_once_per_run(self):
        self.edit_cfg(lambda d: d["specs"][TARGET].update(notify={"user": LEAD, "on": "verified"}))
        self.synced()
        self.pushed()                       # no run named: nothing was verified
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
        self.pushed("--run", RUN_2)
        self.assertEqual(len(self.mentions()), 2)

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
                self.assertTrue(lines[-1].startswith("SUMMARY {} dry-run"), lines)

    def test_spec_status_no_list_yet(self):
        self.new_project()
        self.ready()
        rc, out, lines = self.status()
        self.assertEqual(rc, 0, lines)
        self.assertEqual(out, {"spec": TARGET, "folderUrl": None, "docUrl": None, "list": None, "behind": True,
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
        self.assertEqual(out, {"spec": TARGET, "folderUrl": None,
                               "docUrl": f"https://app.clickup.com/{WS}/v/dc/{self.spec_doc()}",
                               "list": {"n": 1, "url": f"https://app.clickup.com/t/{self.summary()['id']}",
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
        self.assertEqual(out["list"], {"n": 1, "url": f"https://app.clickup.com/t/{self.summary()['id']}",
                                       "bound": False})


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
