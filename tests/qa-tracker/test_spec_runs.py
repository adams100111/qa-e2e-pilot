"""Tests for qa-kit/scripts/trackers/spec_runs.py (run results to ticket states)."""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "qa-kit" / "scripts"))
import offline_guard  # noqa: E402,F401  (first: no test reaches the network)

from trackers import cards, core, spec_runs, wording  # noqa: E402

FIXTURES = Path(__file__).resolve().parent / "fixtures" / "spec"
PROJECT = FIXTURES / "cards" / "project"
RUN = FIXTURES / "run"
TARGET = "judge-scoring"
TEMPLATE = json.loads((ROOT / "qa-kit" / "templates" / "qa-tracker-config.json").read_text(encoding="utf-8"))
JUDGE, ADMIN = "judge-scores-a-submission", "admin-watches-the-ranking"
LOAD = "load-clean:GET /admin/hackathons:admin"


def cfg(**over):
    out = dict(TEMPLATE)
    out.update(over)
    return out


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.run_dir = self.tmp / "run"
        shutil.copytree(RUN, self.run_dir)
        self.cards = cards.load(PROJECT, TARGET)

    def record(self, rows):
        (self.run_dir / "checkpoint.json").write_text(json.dumps({"criteria": rows}), encoding="utf-8")

    def states(self, **over):
        return spec_runs.states(self.run_dir, self.cards, cfg(**over))

    def state(self, card, criterion, **over):
        found = [s for s in self.states(**over) if s.card_id == card and s.criterion == criterion]
        self.assertEqual(len(found), 1)
        return found[0]

    def names(self, state):
        return [p.name for p in state.evidence]


def st(role, needs_review=False):
    return spec_runs.CheckState(card_id="k", criterion="c", persona="p", role=role, needs_review=needs_review)


class Mapping(Base):
    def test_verdict_mapping(self):
        table = {"pass": "passed", "fail": "failed", "blocked": "blocked", "error": "blocked", "deferred": "skipped"}
        for verdict, role in table.items():
            self.record([{"criterion_id": "C-SCORE-01", "persona": "judge", "verdict": verdict, "confidence": "high"}])
            s = self.state(JUDGE, "C-SCORE-01")
            self.assertEqual(s.role, role, verdict)
            self.assertFalse(s.needs_review, verdict)
            self.assertEqual(s.persona, "judge")
        self.record([{"criterion_id": "C-SCORE-01", "persona": "judge", "verdict": "error", "confidence": "high"}])
        self.assertEqual(self.state(JUDGE, "C-SCORE-01").note, "Could not be checked on this run.")
        self.record([{"criterion_id": "C-SCORE-01", "persona": "judge", "verdict": "pass", "confidence": "high"}])
        self.assertIsNone(self.state(JUDGE, "C-SCORE-01").note)

    def test_unknown_verdict_is_never_passed(self):
        self.record([{"criterion_id": "C-SCORE-01", "persona": "judge", "verdict": "partial", "confidence": "high"}])
        self.assertEqual(self.state(JUDGE, "C-SCORE-01").role, "blocked")

    def test_low_confidence_pass_is_testing(self):
        for confidence in ("low", "medium", None, "", "HIGH"):
            self.record([{"criterion_id": "C-SCORE-01", "persona": "judge", "verdict": "pass", "confidence": confidence}])
            s = self.state(JUDGE, "C-SCORE-01")
            self.assertEqual(s.role, "testing", confidence)
            self.assertTrue(s.needs_review, confidence)
            self.assertEqual(s.note, "Passed on this run. A person needs to confirm the expected result.")

    def test_verifier_downgrade_is_kept(self):
        self.record([{"criterion_id": "C-SCORE-01", "persona": "judge", "verdict": "pass", "confidence": "high"}])
        (self.run_dir / "verification.json").write_text(json.dumps([
            {"criterionId": "C-SCORE-01", "persona": "judge", "inRunVerdict": "pass", "verifierVerdict": "fail",
             "confidence": "high", "reasons": ["no read-back"]}]), encoding="utf-8")
        self.assertEqual(self.state(JUDGE, "C-SCORE-01").role, "failed")

    def test_unrun_check_is_to_test(self):
        s = self.state(ADMIN, LOAD)
        self.assertIsNone(s.role)
        self.assertFalse(s.needs_review)
        self.assertIsNone(s.note)
        self.assertEqual(s.evidence, [])
        self.assertFalse(s.raised)
        got = spec_runs.counts(self.states())
        self.assertEqual(got, {"to_test": 1, "testing": 1, "failed": 1, "blocked": 1, "passed": 1,
                               "skipped": 0, "needs_review": 1})

    def test_missing_checkpoint_raises_run_error(self):
        (self.run_dir / "checkpoint.json").unlink()
        with self.assertRaises(core.RunError):
            self.states()

    def test_persona_rows_join_their_own_card(self):
        judge = self.state(JUDGE, "C-RANK-01")
        admin = self.state(ADMIN, "C-RANK-01")
        self.assertEqual((judge.role, judge.persona), ("blocked", "judge"))
        self.assertEqual((admin.role, admin.persona, admin.needs_review), ("testing", "admin", True))
        self.assertTrue(all("judge" in p.parts for p in judge.evidence))
        self.assertTrue(all("admin" in p.parts for p in admin.evidence))

    def test_row_without_persona_joins_only_a_single_holder(self):
        self.record([{"criterion_id": "C-SCORE-01", "verdict": "fail", "confidence": "high"},
                     {"criterion_id": "C-RANK-01", "verdict": "fail", "confidence": "high"}])
        s = self.state(JUDGE, "C-SCORE-01")
        self.assertEqual((s.role, s.persona), ("failed", ""))
        self.assertIsNone(self.state(JUDGE, "C-RANK-01").role)
        self.assertIsNone(self.state(ADMIN, "C-RANK-01").role)

    def test_row_of_another_role_does_not_join(self):
        self.record([{"criterion_id": "C-SCORE-01", "persona": "admin", "verdict": "pass", "confidence": "high"}])
        self.assertIsNone(self.state(JUDGE, "C-SCORE-01").role)


class RollUp(unittest.TestCase):
    def test_card_rollup_worst_wins(self):
        order = ["failed", "blocked", "testing", "skipped", "passed"]
        for i, worst in enumerate(order):
            got = spec_runs.card_role([st(r) for r in reversed(order[i:])])
            self.assertEqual(got, worst)
        self.assertEqual(spec_runs.card_role([st("failed"), st(None), st("passed")]), "failed")
        self.assertEqual(spec_runs.card_role([st("blocked"), st(None)]), "blocked")
        self.assertEqual(spec_runs.card_role([st("passed"), st("passed")]), "passed")
        self.assertEqual(spec_runs.ROLLUP_ORDER, ("failed", "blocked", "testing", "to_test", "skipped", "passed"))

    def test_card_rollup_reads_the_one_order(self):
        with mock.patch.object(spec_runs, "ROLLUP_ORDER", ("blocked", "failed", "testing", "to_test", "skipped",
                                                           "passed")):
            self.assertEqual(spec_runs.card_role([st("failed"), st("blocked")]), "blocked")
        with mock.patch.object(spec_runs, "ROLLUP_ORDER", ("failed", "blocked", "testing", "to_test", "passed",
                                                           "skipped")):
            self.assertEqual(spec_runs.card_role([st("skipped"), st("passed")]), "passed")

    def test_card_testing_while_open(self):
        self.assertEqual(spec_runs.card_role([st("passed"), st(None)]), "testing")
        self.assertEqual(spec_runs.card_role([st("skipped"), st(None)]), "testing")
        self.assertEqual(spec_runs.card_role([st("passed"), st("testing", True)]), "testing")
        self.assertEqual(spec_runs.card_role([st(None), st(None)]), "to_test")
        self.assertEqual(spec_runs.card_role([]), "to_test")

    def test_counts_keys(self):
        got = spec_runs.counts([])
        self.assertEqual(sorted(got), sorted(list(core.CASE_ROLES) + ["needs_review"]))
        self.assertEqual(set(got.values()), {0})


class Evidence(Base):
    def test_evidence_standard_cap(self):
        failed = self.state(JUDGE, "C-SCORE-02")
        self.assertEqual(self.names(failed), ["screenshot-before.png", "screenshot-after-message.png",
                                              "screenshot-after.png"])
        self.assertTrue(all(p.is_file() and p.is_absolute() for p in failed.evidence))
        self.assertEqual(self.names(self.state(JUDGE, "C-SCORE-01")), ["screenshot-after.png"])
        self.assertEqual(len(self.state(JUDGE, "C-SCORE-02", evidenceCap=10).evidence), 4)
        self.assertEqual(len(self.state(JUDGE, "C-SCORE-02", evidenceCap=1).evidence), 1)
        self.assertEqual(self.state(JUDGE, "C-SCORE-02", evidenceCap=0).evidence, [])
        self.assertEqual(self.names(self.state(ADMIN, "C-RANK-01")), ["screenshot-after.png"])

    def test_evidence_failures_mode_skips_passed(self):
        self.assertEqual(self.state(JUDGE, "C-SCORE-01", evidence="failures").evidence, [])
        # A check that waits for a person's review is picked like a failed one.
        self.assertEqual(self.names(self.state(ADMIN, "C-RANK-01", evidence="failures")), ["screenshot-after.png"])
        self.assertEqual(len(self.state(JUDGE, "C-SCORE-02", evidence="failures").evidence), 3)

    def test_evidence_none_mode(self):
        self.assertTrue(all(s.evidence == [] for s in self.states(evidence="none")))
        self.assertEqual(spec_runs.missing_evidence(self.run_dir, self.cards, cfg(evidence="none")), [])

    def test_missing_screenshot_reported_not_raised(self):
        blocked = self.state(JUDGE, "C-RANK-01")
        self.assertEqual(self.names(blocked), ["screenshot-before.png"])
        self.assertEqual(spec_runs.missing_evidence(self.run_dir, self.cards, cfg()), [("C-RANK-01", "judge")])

    def test_altered_screenshot_is_left_out_and_reported(self):
        img = self.run_dir / "evidence" / "judge" / "C-SCORE-01" / "screenshot-before.png"
        img.write_bytes(img.read_bytes() + b"x")
        self.assertEqual(self.names(self.state(JUDGE, "C-SCORE-01")), ["screenshot-after.png"])
        self.assertIn(("C-SCORE-01", "judge"), spec_runs.missing_evidence(self.run_dir, self.cards, cfg()))

    def test_passed_check_shows_the_after_state_first(self):
        folder = self.run_dir / "evidence" / "judge" / "C-SCORE-01"
        self.assertEqual(self.names(self.state(JUDGE, "C-SCORE-01")), ["screenshot-after.png"])
        (folder / "screenshot-after.png").unlink()
        (folder / "screenshot-after.json").unlink()
        self.assertEqual(self.names(self.state(JUDGE, "C-SCORE-01")), ["screenshot-before.png"])
        self.assertEqual(spec_runs.missing_evidence(self.run_dir, self.cards, cfg()), [("C-RANK-01", "judge")])

    def test_review_check_is_picked_like_a_failed_one(self):
        self.record([{"criterion_id": "C-SCORE-02", "persona": "judge", "verdict": "pass", "confidence": "low"}])
        for mode in ("standard", "failures"):
            s = self.state(JUDGE, "C-SCORE-02", evidence=mode)
            self.assertTrue(s.needs_review)
            self.assertEqual(self.names(s), ["screenshot-before.png", "screenshot-after-message.png",
                                             "screenshot-after.png"], mode)
        self.assertEqual(self.state(JUDGE, "C-SCORE-02", evidence="none").evidence, [])
        folder = self.run_dir / "evidence" / "judge" / "C-SCORE-02"
        (folder / "screenshot-after.png").unlink()
        self.assertEqual(spec_runs.missing_evidence(self.run_dir, self.cards, cfg(evidence="failures")),
                         [("C-SCORE-02", "judge")])

    def test_evidence_refs_and_loose_images(self):
        loose = self.run_dir / "evidence" / "judge" / "C-SCORE-02" / "after-save.png"
        loose.write_bytes(b"loose")
        other = self.run_dir / "shots" / "page.png"
        other.parent.mkdir()
        other.write_bytes(b"other")
        self.record([{"criterion_id": "C-SCORE-02", "persona": "judge", "verdict": "fail", "confidence": "high",
                      "evidence_refs": ["shots/page.png", "shots/gone.png", "../outside.png", "notes/trace.json"]}])
        s = self.state(JUDGE, "C-SCORE-02", evidenceCap=10)
        self.assertEqual(self.names(s), ["screenshot-before.png", "after-save.png", "screenshot-after-message.png",
                                         "screenshot-after.png", "screenshot-image-list.png", "page.png"])
        self.assertEqual(spec_runs.missing_evidence(self.run_dir, self.cards, cfg()), [("C-SCORE-02", "judge")])

    def test_checklist_card_raises_only_failures(self):
        self.record([
            {"criterion_id": "C-RANK-01", "persona": "admin", "verdict": "pass", "confidence": "high"},
            {"criterion_id": LOAD, "persona": "admin", "verdict": "fail", "confidence": "high"},
            {"criterion_id": "C-SCORE-02", "persona": "judge", "verdict": "fail", "confidence": "high"},
        ])
        self.assertFalse(self.state(ADMIN, "C-RANK-01").raised)
        self.assertTrue(self.state(ADMIN, LOAD).raised)
        self.assertFalse(self.state(JUDGE, "C-SCORE-02").raised)  # a subtasks card: already a subtask
        for verdict, confidence, raised in (("blocked", "high", True), ("error", "high", True), ("pass", "low", True),
                                            ("deferred", "high", False)):
            self.record([{"criterion_id": LOAD, "persona": "admin", "verdict": verdict, "confidence": confidence}])
            self.assertEqual(self.state(ADMIN, LOAD).raised, raised, verdict)
        self.assertFalse(self.state(ADMIN, "C-RANK-01").raised)  # not run


class WorseRowWins(Base):
    """A1: a single holder card takes the worse of its persona row and a live persona-less row."""

    def test_later_row_without_persona_that_failed_is_not_hidden(self):
        self.record([
            {"criterion_id": "C-SCORE-01", "persona": "judge", "verdict": "pass", "confidence": "high",
             "checkpointed_at": "2026-11-27T09:00:00Z"},
            {"criterion_id": "C-SCORE-01", "verdict": "fail", "confidence": "high",
             "checkpointed_at": "2026-11-27T10:00:00Z"}])
        s = self.state(JUDGE, "C-SCORE-01")
        self.assertEqual((s.role, s.persona), ("failed", ""))
        self.assertEqual(spec_runs.unjoined(self.run_dir, self.cards), [])

    def test_later_pass_without_persona_does_not_hide_a_persona_fail(self):
        self.record([
            {"criterion_id": "C-SCORE-01", "persona": "judge", "verdict": "fail", "confidence": "high",
             "checkpointed_at": "2026-11-27T09:00:00Z"},
            {"criterion_id": "C-SCORE-01", "verdict": "pass", "confidence": "high",
             "checkpointed_at": "2026-11-27T10:00:00Z"}])
        s = self.state(JUDGE, "C-SCORE-01")
        self.assertEqual((s.role, s.persona), ("failed", "judge"))

    def test_review_is_worse_than_a_clean_pass(self):
        self.record([
            {"criterion_id": "C-SCORE-01", "persona": "judge", "verdict": "pass", "confidence": "high",
             "checkpointed_at": "2026-11-27T09:00:00Z"},
            {"criterion_id": "C-SCORE-01", "verdict": "pass", "confidence": "low",
             "checkpointed_at": "2026-11-27T10:00:00Z"}])
        s = self.state(JUDGE, "C-SCORE-01")
        self.assertEqual((s.role, s.needs_review), ("testing", True))

    def test_equal_rows_keep_the_persona_row(self):
        self.record([
            {"criterion_id": "C-SCORE-01", "persona": "judge", "verdict": "pass", "confidence": "high",
             "checkpointed_at": "2026-11-27T09:00:00Z"},
            {"criterion_id": "C-SCORE-01", "verdict": "pass", "confidence": "high",
             "checkpointed_at": "2026-11-27T10:00:00Z"}])
        s = self.state(JUDGE, "C-SCORE-01")
        self.assertEqual((s.role, s.persona), ("passed", "judge"))


class Confidence(Base):
    """A4: the lower of the recorded confidence and the one after verification."""

    def verify(self, confidence):
        (self.run_dir / "verification.json").write_text(json.dumps([
            {"criterionId": "C-SCORE-01", "persona": "judge", "inRunVerdict": "pass", "verifierVerdict": "pass",
             "confidence": confidence, "reasons": []}]), encoding="utf-8")

    def test_verification_cannot_raise_a_recorded_low_confidence(self):
        self.record([{"criterion_id": "C-SCORE-01", "persona": "judge", "verdict": "pass", "confidence": "low"}])
        self.verify("high")
        s = self.state(JUDGE, "C-SCORE-01")
        self.assertEqual((s.role, s.needs_review), ("testing", True))

    def test_pass_without_recorded_confidence_stays_in_review(self):
        self.record([{"criterion_id": "C-SCORE-01", "persona": "judge", "verdict": "pass"}])
        self.verify("high")
        s = self.state(JUDGE, "C-SCORE-01")
        self.assertEqual((s.role, s.needs_review), ("testing", True))

    def test_verification_lowers_a_recorded_high_confidence(self):
        self.record([{"criterion_id": "C-SCORE-01", "persona": "judge", "verdict": "pass", "confidence": "high"}])
        self.verify("low")
        self.assertEqual(self.state(JUDGE, "C-SCORE-01").role, "testing")
        self.verify("high")
        s = self.state(JUDGE, "C-SCORE-01")
        self.assertEqual((s.role, s.needs_review), ("passed", False))


class Unjoined(Base):
    def test_rows_that_join_no_card_are_listed(self):
        self.assertEqual(spec_runs.unjoined(self.run_dir, self.cards), [])
        self.record([
            {"criterion_id": "C-SCORE-01", "persona": "judge", "verdict": "pass", "confidence": "high"},
            {"criterion_id": "C-SCORE-01", "persona": "visitor", "verdict": "fail", "confidence": "high"},
            {"criterion_id": "C-RANK-01", "verdict": "blocked", "confidence": "high"},
            {"criterion_id": "C-PRIZE-01", "persona": "judge", "verdict": "pass", "confidence": "low"}])
        self.assertEqual(spec_runs.unjoined(self.run_dir, self.cards),
                         [("C-PRIZE-01", "judge", "pass"), ("C-RANK-01", "", "blocked"),
                          ("C-SCORE-01", "visitor", "fail")])


class Containment(Base):
    """A2: only image files inside the run folder are ever picked."""

    def setUp(self):
        super().setUp()
        self.outside = self.tmp / "auth"
        self.outside.mkdir()
        self.secret = self.outside / "session.png"
        self.secret.write_bytes(b"not for upload")
        self.folder = self.run_dir / "evidence" / "judge" / "C-SCORE-02"
        self.root = self.run_dir.resolve()

    def sidecar(self, folder, name, image, phase="after"):
        digest = hashlib.sha256((folder / image).read_bytes()).hexdigest()
        (folder / name).write_text(json.dumps({"kind": "screenshot", "phase": phase, "label": "", "image": image,
                                               "sha256": digest}), encoding="utf-8")

    def assert_nothing_leaves_the_run(self, key=("C-SCORE-02", "judge")):
        for s in self.states(evidenceCap=50):
            for path in s.evidence:
                real = path.resolve()
                self.assertNotEqual(real, self.secret.resolve())
                self.assertEqual(os.path.commonpath([str(real), str(self.root)]), str(self.root), path)
                self.assertNotEqual(path.read_bytes(), b"not for upload")
        self.assertIn(key, spec_runs.missing_evidence(self.run_dir, self.cards, cfg(evidenceCap=50)))

    def test_link_to_a_file_outside_the_run_is_dropped(self):
        (self.folder / "after-leak.png").symlink_to(self.secret)
        self.assertNotIn("after-leak.png", self.names(self.state(JUDGE, "C-SCORE-02", evidenceCap=50)))
        self.assert_nothing_leaves_the_run()

    def test_recorded_link_to_a_file_outside_the_run_is_dropped(self):
        (self.folder / "screenshot-leak.png").symlink_to(self.secret)
        self.sidecar(self.folder, "screenshot-leak.json", "screenshot-leak.png")
        self.assertNotIn("screenshot-leak.png", self.names(self.state(JUDGE, "C-SCORE-02", evidenceCap=50)))
        self.assert_nothing_leaves_the_run()

    def test_ref_through_a_linked_folder_is_dropped(self):
        (self.run_dir / "shots").symlink_to(self.outside, target_is_directory=True)
        self.record([{"criterion_id": "C-SCORE-02", "persona": "judge", "verdict": "fail", "confidence": "high",
                      "evidence_refs": ["shots/session.png"]}])
        self.assertNotIn("session.png", self.names(self.state(JUDGE, "C-SCORE-02", evidenceCap=50)))
        self.assert_nothing_leaves_the_run()

    def test_linked_evidence_folder_is_dropped(self):
        shutil.rmtree(self.folder)
        self.folder.symlink_to(self.outside, target_is_directory=True)
        self.assertEqual(self.state(JUDGE, "C-SCORE-02", evidenceCap=50).evidence, [])
        self.assert_nothing_leaves_the_run()

    def test_criterion_id_that_climbs_out_is_refused(self):
        for bad in ("../../../auth", "C-SCORE-02/../C-SCORE-02", "/" + str(self.outside).lstrip("/")):
            self.cards = cards.load(PROJECT, TARGET)
            self.cards.cards[0].checks[1].criterion = bad
            self.record([{"criterion_id": bad, "persona": "judge", "verdict": "fail", "confidence": "high"}])
            s = self.state(JUDGE, bad, evidenceCap=50)
            self.assertEqual(s.role, "failed", bad)
            self.assertEqual(s.evidence, [], bad)
            self.assertEqual(spec_runs.missing_evidence(self.run_dir, self.cards, cfg()), [(bad, "judge")], bad)

    def test_persona_that_climbs_out_is_refused(self):
        for bad in ("judge/../judge", "../../auth"):
            self.cards = cards.load(PROJECT, TARGET)
            self.cards.cards[0].role = bad
            self.record([{"criterion_id": "C-SCORE-02", "persona": bad, "verdict": "fail", "confidence": "high"}])
            s = self.state(JUDGE, "C-SCORE-02", evidenceCap=50)
            self.assertEqual((s.role, s.evidence), ("failed", []), bad)
            self.assertEqual(spec_runs.missing_evidence(self.run_dir, self.cards, cfg()), [("C-SCORE-02", bad)], bad)

    def test_ref_that_climbs_out_is_reported(self):
        self.record([{"criterion_id": "C-SCORE-02", "persona": "judge", "verdict": "fail", "confidence": "high",
                      "evidence_refs": ["../auth/session.png", str(self.secret)]}])
        self.assertNotIn("session.png", self.names(self.state(JUDGE, "C-SCORE-02", evidenceCap=50)))
        self.assert_nothing_leaves_the_run()

    def test_recorded_file_that_is_not_an_image_is_dropped(self):
        (self.folder / "notes.txt").write_bytes(b"typed values")
        self.sidecar(self.folder, "screenshot-notes.json", "notes.txt")
        (self.folder / "screenshot-page.PNG").write_bytes(b"upper case image")
        self.sidecar(self.folder, "screenshot-page.json", "screenshot-page.PNG")
        got = self.names(self.state(JUDGE, "C-SCORE-02", evidenceCap=50))
        self.assertNotIn("notes.txt", got)
        self.assertIn("screenshot-page.PNG", got)
        self.assertEqual(spec_runs.missing_evidence(self.run_dir, self.cards, cfg()),
                         [("C-SCORE-02", "judge"), ("C-RANK-01", "judge")])

    def test_criterion_id_with_slash_and_colon_keeps_its_evidence(self):
        # scripts/render-report.js collectEvidence joins the id as it is: "evidence/<persona>/<id>".
        folder = self.run_dir / "evidence" / "admin" / LOAD
        folder.mkdir(parents=True)
        (folder / "screenshot-after.png").write_bytes(b"users list")
        self.sidecar(folder, "screenshot-after.json", "screenshot-after.png")
        self.record([{"criterion_id": LOAD, "persona": "admin", "verdict": "fail", "confidence": "high"}])
        s = self.state(ADMIN, LOAD)
        self.assertEqual(self.names(s), ["screenshot-after.png"])
        self.assertEqual(s.evidence[0].resolve(), (folder / "screenshot-after.png").resolve())
        self.assertEqual(spec_runs.missing_evidence(self.run_dir, self.cards, cfg()), [])


class HashOnce(Base):
    def test_one_sync_reads_each_image_once(self):
        spec_runs._HASHES.clear()
        seen = []
        real = spec_runs._hash_file

        def counting(path):
            seen.append(Path(path).resolve())
            return real(path)

        with mock.patch.object(spec_runs, "_hash_file", counting):
            self.states()
            spec_runs.missing_evidence(self.run_dir, self.cards, cfg())
            self.states(evidence="failures")
        self.assertGreater(len(seen), 0)
        self.assertEqual(len(seen), len(set(seen)))

    def test_changed_image_is_read_again(self):
        img = self.run_dir / "evidence" / "judge" / "C-SCORE-02" / "screenshot-after.png"
        self.assertIn("screenshot-after.png", self.names(self.state(JUDGE, "C-SCORE-02")))
        img.write_bytes(img.read_bytes() + b"x")
        self.assertNotIn("screenshot-after.png", self.names(self.state(JUDGE, "C-SCORE-02")))


def report(verdict, conditions):
    out = ["# QA report — Judges", "", "**Run:** `r`", "", "---", "", "## Ship readiness", "", "**" + verdict + "**", ""]
    out += ["- " + c for c in conditions]
    if conditions:
        out.append("")
    out += ["| Check | Result |", "|---|---|", "| Census coverage | 4 of 4 covered (100%) · 0 uncovered |", "",
            "## Summary", "", "- not a ship condition"]
    return "\n".join(out) + "\n"


class Ready(Base):
    def test_ready_none_without_ship_files(self):
        self.assertEqual(spec_runs.ready(self.run_dir), (None, []))
        (self.run_dir / "report.md").write_text("# QA report — Judges\n\n## Summary\n\nSHIP-READY is not claimed.\n",
                                                encoding="utf-8")
        self.assertEqual(spec_runs.ready(self.run_dir), (None, []))
        (self.run_dir / "report.md").write_text("## Ship readiness\n\nsomething else\n", encoding="utf-8")
        self.assertEqual(spec_runs.ready(self.run_dir), (None, []))

    def test_ready_true(self):
        (self.run_dir / "report.md").write_text(report("SHIP-READY", []), encoding="utf-8")
        self.assertEqual(spec_runs.ready(self.run_dir), (True, []))

    def test_ready_false_with_plain_reasons(self):
        (self.run_dir / "report.md").write_text(report("NOT SHIP-READY", [
            "2 census surface(s) uncovered", "P1 journey J1 is fail", "coding-layer fail on P1 C-SCORE-01 (service)",
            "coding-layer fail on P1 C-SCORE-02 (route)", "something the table does not know"]), encoding="utf-8")
        ok, reasons = spec_runs.ready(self.run_dir)
        self.assertIs(ok, False)
        self.assertEqual(reasons, ["Some screens have not been checked yet.", "A main user journey did not pass.",
                                   "A top priority check failed.",
                                   "Another condition is not met; see the Results page."])

    def test_ready_never_true_with_conditions(self):
        (self.run_dir / "report.md").write_text(report("SHIP-READY", ["not independently verified"]), encoding="utf-8")
        self.assertIs(spec_runs.ready(self.run_dir)[0], False)

    def write(self, *lines):
        (self.run_dir / "report.md").write_text("\n".join(lines) + "\n", encoding="utf-8")

    def test_ready_line_followed_by_not_ready_line_is_not_ready(self):
        self.write("# QA report", "", "## Ship readiness", "", "**SHIP-READY**", "**NOT SHIP-READY**", "",
                   "- not independently verified", "", "| Check | Result |", "|---|---|", "", "## Summary")
        self.assertEqual(spec_runs.ready(self.run_dir), (False, ["The results have not had their second check yet."]))
        self.write("## Ship readiness", "", "**SHIP-READY**", "", "| Check | Result |", "|---|---|",
                   "| Verdict | NOT SHIP-READY |", "", "## Summary")
        self.assertEqual(spec_runs.ready(self.run_dir), (False, []))

    def test_indented_or_quoted_copy_of_the_section_is_not_read(self):
        self.write("# QA report", "", "  ## Ship readiness", "", "  **SHIP-READY**", "", "## Summary")
        self.assertEqual(spec_runs.ready(self.run_dir), (None, []))
        self.write("# QA report", "", "> ## Ship readiness", ">", "> **SHIP-READY**", "", "## Summary")
        self.assertEqual(spec_runs.ready(self.run_dir), (None, []))
        self.write("# QA report", "", "## Ship readiness", "", "  **SHIP-READY**", "", "## Summary")
        self.assertEqual(spec_runs.ready(self.run_dir), (None, []))
        self.write("# QA report", "", "## Ship readiness", "", "> **SHIP-READY**", "", "## Summary")
        self.assertEqual(spec_runs.ready(self.run_dir), (None, []))
        self.write("# QA report", "", "## Ship readiness", "", "**SHIP-READY** for now", "", "## Summary")
        self.assertEqual(spec_runs.ready(self.run_dir), (None, []))

    def test_two_sections_are_never_ready(self):
        ready = ["## Ship readiness", "", "**SHIP-READY**", "", "| Check | Result |", "|---|---|", ""]
        not_ready = ["## Ship readiness", "", "**NOT SHIP-READY**", "", "- no P1 journeys declared", "",
                     "| Check | Result |", "|---|---|", ""]
        self.write(*(ready + not_ready + ["## Summary"]))
        self.assertEqual(spec_runs.ready(self.run_dir), (False, ["No main user journey is listed for this run."]))
        self.write(*(not_ready + ready + ["## Summary"]))
        self.assertEqual(spec_runs.ready(self.run_dir), (False, ["No main user journey is listed for this run."]))
        self.write(*(ready + ready + ["## Summary"]))
        self.assertEqual(spec_runs.ready(self.run_dir), (None, []))

    def test_ready_section_stops_at_the_next_heading(self):
        self.write("## Ship readiness", "", "**SHIP-READY**", "", "| Check | Result |", "|---|---|", "",
                   "## Summary", "", "A reader may write NOT SHIP-READY here.")
        self.assertEqual(spec_runs.ready(self.run_dir), (True, []))

    def test_every_engine_condition_has_a_plain_reason(self):
        conditions = [
            "3 census surface(s) uncovered", "census is empty", "census coverage unknown", "census adapter failed",
            "no P1 journeys declared", "P1 journey J2 is incomplete (disputed: C-1)",
            "coding-layer fail on P1 C-1 (db)", "fail on P1 with unknown layer C-1 (layer unknown)",
            "not independently verified", "verifier override on P1 C-1", "verification out of date on P1 C-1",
            "verifier disputed P1 C-1", "2 P1 low-confidence pass(es) not re-judged: C-1, C-2",
            "re-adjudication unavailable — 1 P1 low-confidence pass(es) unreviewed: C-1",
            "re-adjudication did not run — 1 P1 low-confidence pass(es) unreviewed: C-1",
            "re-adjudication decision on P1 C-1 was not applied", "adjudication/decisions.json is not a JSON array",
        ]
        for cond in conditions:
            self.assertNotEqual(spec_runs.plain_reason(cond), spec_runs.REASON_UNKNOWN, cond)


class Wording(unittest.TestCase):
    def test_fixed_sentences_pass_the_lint(self):
        self.assertGreaterEqual(len(spec_runs.FIXED_SENTENCES), 4)
        for name in ("NOTE_ERROR", "NOTE_REVIEW", "NOTE_DEFERRED", "REASON_UNKNOWN"):
            self.assertIn(getattr(spec_runs, name), spec_runs.FIXED_SENTENCES)
        for _, text in spec_runs.REASON_TABLE:
            self.assertIn(text, spec_runs.FIXED_SENTENCES)
        for sentence in spec_runs.FIXED_SENTENCES:
            self.assertEqual(wording.lint_text(sentence, "body", TEMPLATE), [], sentence)

    def test_states_carry_no_ids_or_paths_in_text(self):
        c = cards.load(PROJECT, TARGET)
        for s in spec_runs.states(RUN, c, TEMPLATE):
            if s.note is not None:
                self.assertIn(s.note, spec_runs.FIXED_SENTENCES)


if __name__ == "__main__":
    unittest.main()
