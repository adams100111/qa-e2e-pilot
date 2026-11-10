"""Tests for qa-kit/scripts/trackers/core.py (pure tracker helpers)."""
from __future__ import annotations

import io
import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "qa-kit" / "scripts"))

from trackers import core  # noqa: E402

FIX = Path(__file__).resolve().parent / "fixtures"
CATALOG = FIX / "catalog"
RUN_R1 = FIX / "runs" / "r1"


class TempProject(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="qa-tracker-test."))
        self.addCleanup(shutil.rmtree, str(self.tmp), True)

    def copy_catalog(self) -> Path:
        dest = self.tmp / ".qa" / "catalog"
        shutil.copytree(str(CATALOG), str(dest))
        return dest

    def cfg(self) -> dict:
        return core.load_config(self.tmp)


class ConfigTests(TempProject):
    def test_defaults_on_empty_project(self) -> None:
        cfg = self.cfg()
        self.assertEqual(cfg["backend"], "local")
        self.assertEqual(cfg["catalog"], ".qa/catalog")
        self.assertEqual(cfg["statusCeiling"], "none")
        self.assertEqual(cfg["guideAs"], "tasks")
        self.assertEqual(cfg["secrets"], ["sharedPassword"])
        for key in ("ids", "lists", "statuses", "fields", "wording", "guideDir"):
            self.assertIn(key, cfg)
        self.assertEqual(set(cfg["ids"]), {"workspace", "space", "folder"})
        self.assertIn("agent", cfg["wording"]["forbidden"])
        template = json.loads((ROOT / "qa-kit" / "templates" / "qa-tracker-config.json").read_text())
        self.assertEqual(cfg, template)

    def test_project_values_override_and_nested_merge(self) -> None:
        path = self.tmp / "docs" / "agents" / "qa-tracker.json"
        path.parent.mkdir(parents=True)
        path.write_text(json.dumps({"backend": "clickup", "ids": {"folder": "901"}}))
        cfg = self.cfg()
        self.assertEqual(cfg["backend"], "clickup")
        self.assertEqual(cfg["ids"]["folder"], "901")
        self.assertIn("workspace", cfg["ids"])
        self.assertEqual(cfg["statusCeiling"], "none")

    def test_bad_json_raises_config_error_with_path(self) -> None:
        path = self.tmp / "docs" / "agents" / "qa-tracker.json"
        path.parent.mkdir(parents=True)
        path.write_text("{not json")
        with self.assertRaises(core.ConfigError) as ctx:
            self.cfg()
        self.assertIn(str(path), str(ctx.exception))

    def test_bad_status_ceiling_raises(self) -> None:
        path = self.tmp / "docs" / "agents" / "qa-tracker.json"
        path.parent.mkdir(parents=True)
        path.write_text(json.dumps({"statusCeiling": "passed"}))
        with self.assertRaises(core.ConfigError) as ctx:
            self.cfg()
        self.assertIn(str(path), str(ctx.exception))


class CatalogTests(TempProject):
    def test_validate_clean_catalog(self) -> None:
        self.copy_catalog()
        cat = core.load_catalog(self.tmp, self.cfg())
        self.assertEqual(core.validate_catalog(cat), [])
        self.assertEqual([a.prefix for a in cat.areas], ["A", "B"])
        area = cat.areas[0]
        self.assertEqual(area.file, "area-a.json")
        self.assertEqual(area.list, "Core: Sign-in")
        self.assertEqual(area.order, 10)
        self.assertIn("what", area.intro)
        self.assertEqual(len(area.cases), 3)

    def test_validate_reports_duplicate_and_count_drift(self) -> None:
        dest = self.copy_catalog()
        b = json.loads((dest / "area-b.json").read_text())
        dup = dict(b["cases"][0])
        dup["id"] = "TC-A-001"
        b["cases"].append(dup)
        (dest / "area-b.json").write_text(json.dumps(b))
        errors = core.validate_catalog(core.load_catalog(self.tmp, self.cfg()))
        reasons = " | ".join(e["reason"] for e in errors)
        self.assertIn("duplicate id", reasons)
        self.assertIn("counts", reasons)
        self.assertIn("prefix", reasons)
        dup_err = [e for e in errors if "duplicate id" in e["reason"]][0]
        self.assertEqual(dup_err["id"], "TC-A-001")
        self.assertEqual(dup_err["file"], "area-b.json")
        for e in errors:
            self.assertEqual(set(e), {"file", "id", "reason"})

    def test_counts_include_retired_cases(self) -> None:
        dest = self.copy_catalog()
        man = json.loads((dest / "manifest.json").read_text())
        man["areas"][0]["counts"] = {"P1": 1, "P2": 1, "P3": 0, "retired": 1}
        man["areas"][1]["counts"]["retired"] = 1
        (dest / "manifest.json").write_text(json.dumps(man))
        errors = core.validate_catalog(core.load_catalog(self.tmp, self.cfg()))
        reasons = sorted(e["reason"] for e in errors)
        self.assertEqual(reasons, ["counts P2: manifest 1, catalog 2", "counts retired: manifest 1, catalog 0"])

    def test_validate_reports_missing_and_unlisted_files(self) -> None:
        dest = self.copy_catalog()
        (dest / "area-b.json").rename(dest / "extra.json")
        errors = core.validate_catalog(core.load_catalog(self.tmp, self.cfg()))
        by_file = {e["file"]: e["reason"] for e in errors}
        self.assertIn("missing", by_file.get("area-b.json", ""))
        self.assertIn("not listed in the manifest", by_file.get("extra.json", ""))

    def test_validate_reports_schema_problems(self) -> None:
        dest = self.copy_catalog()
        a = json.loads((dest / "area-a.json").read_text())
        a["cases"][0]["priority"] = "P9"
        a["cases"][1]["steps"] = []
        del a["cases"][1]["expected"]
        a["cases"][0]["colour"] = "blue"
        (dest / "area-a.json").write_text(json.dumps(a))
        errors = core.validate_catalog(core.load_catalog(self.tmp, self.cfg()))
        reasons = " | ".join(e["reason"] for e in errors)
        self.assertIn("priority", reasons)
        self.assertIn("steps", reasons)
        self.assertIn("expected", reasons)
        self.assertIn("colour", reasons)

    def test_case_index_includes_retired(self) -> None:
        self.copy_catalog()
        idx = core.case_index(core.load_catalog(self.tmp, self.cfg()))
        self.assertEqual(sorted(idx), ["TC-A-001", "TC-A-002", "TC-A-003", "TC-B-001", "TC-B-002"])
        area, case = idx["TC-A-003"]
        self.assertEqual(area.prefix, "A")
        self.assertTrue(case["retired"])

    def test_missing_manifest_raises(self) -> None:
        with self.assertRaises(core.CatalogError):
            core.load_catalog(self.tmp, self.cfg())

    @unittest.skipUnless(core.yaml is not None, "PyYAML not installed")
    def test_yaml_catalog_loads(self) -> None:
        dest = self.tmp / ".qa" / "catalog"
        dest.mkdir(parents=True)
        man = json.loads((CATALOG / "manifest.json").read_text())
        for area in man["areas"]:
            data = json.loads((CATALOG / area["file"]).read_text())
            area["file"] = area["file"].replace(".json", ".yaml")
            (dest / area["file"]).write_text(core.yaml.safe_dump(data, allow_unicode=True))
        (dest / "manifest.yaml").write_text(core.yaml.safe_dump(man))
        cat = core.load_catalog(self.tmp, self.cfg())
        self.assertEqual(core.validate_catalog(cat), [])
        self.assertEqual(len(core.case_index(cat)), 5)

    def test_schema_file_is_the_source_of_case_rules(self) -> None:
        schema = json.loads((ROOT / "qa-kit" / "templates" / "catalog-schema.json").read_text())
        case = schema["$defs"]["case"]
        self.assertEqual(
            sorted(case["required"]),
            sorted(["id", "title", "priority", "preconditions", "steps", "expected"]),
        )
        self.assertEqual(case["properties"]["id"]["pattern"], r"^TC-[A-Z]+-\d{3}$")
        self.assertEqual(case["properties"]["priority"]["enum"], ["P1", "P2", "P3"])
        self.assertEqual(case["properties"]["level"]["enum"], ["beginner", "needs-setup", "technical"])


class HashTests(unittest.TestCase):
    def test_norm_drops_links_and_punctuation(self) -> None:
        self.assertEqual(core.norm("See [the docs](https://x.example/a) — now!"), "seethedocsnow")
        self.assertEqual(core.norm(None), "")

    def test_content_hash_ignores_rendering(self) -> None:
        self.assertEqual(core.content_hash("- Open *the* page"), core.content_hash("Open the page"))
        self.assertEqual(len(core.content_hash("x")), 40)

    def test_fingerprint_stable_across_digits(self) -> None:
        a = core.fingerprint("TC-A-001", "admin", "Total off by 3")
        b = core.fingerprint("TC-A-001", "admin", "Total off by 7")
        self.assertEqual(a, b)
        self.assertEqual(len(a), 12)
        self.assertNotEqual(a, core.fingerprint("TC-A-001", "viewer", "Total off by 3"))
        self.assertEqual(a, core.fingerprint("TC-A-001", "admin", "  total, OFF   by 42!"))


class ResultsTests(TempProject):
    def test_case_results_rollup_worst_and_override(self) -> None:
        res = core.case_results(RUN_R1)
        self.assertEqual(res["TC-A-001"]["verdict"], "fail")
        self.assertEqual(res["TC-A-002"]["verdict"], "fail")
        # the last checkpoint row wins; a verification row for another persona does not apply
        self.assertEqual(res["TC-B-001"]["verdict"], "pass")
        self.assertEqual(res["TC-A-001"]["confidence"], "medium")

    def test_catalogref_list_joins_two_cases(self) -> None:
        res = core.case_results(RUN_R1)
        ids_001 = [c["id"] for c in res["TC-A-001"]["criteria"]]
        ids_003 = [c["id"] for c in res["TC-A-003"]["criteria"]]
        self.assertIn("C4", ids_001)
        self.assertEqual(ids_003, ["C4"])
        self.assertEqual(res["TC-A-003"]["verdict"], "pass")
        self.assertEqual(res["TC-A-003"]["criteria"][0], {"id": "C4", "verdict": "pass", "persona": "user"})

    def test_rows_without_case_are_ignored(self) -> None:
        res = core.case_results(RUN_R1)
        self.assertEqual(sorted(res), ["TC-A-001", "TC-A-002", "TC-A-003", "TC-B-001"])

    def test_override_needs_matching_in_run_verdict(self) -> None:
        # C4's verification row says inRunVerdict "fail" but the checkpoint says "pass": stale, not applied
        res = core.case_results(RUN_R1)
        c4 = [c for c in res["TC-A-003"]["criteria"] if c["id"] == "C4"][0]
        self.assertEqual(c4["verdict"], "pass")

    def test_override_ignores_unknown_verifier_verdict(self) -> None:
        run = self.tmp / "r1"
        shutil.copytree(str(RUN_R1), str(run))
        rows = json.loads((run / "verification.json").read_text())
        for r in rows:
            if r["criterionId"] == "C3":
                r["verifierVerdict"] = "maybe"
        (run / "verification.json").write_text(json.dumps(rows))
        self.assertEqual(core.case_results(run)["TC-A-002"]["verdict"], "pass")

    def test_superseded_personaless_row_is_dropped(self) -> None:
        run = self.tmp / "r1"
        shutil.copytree(str(RUN_R1), str(run))
        cl = json.loads((run / "checklist.json").read_text())
        cl.append({"id": "C7", "title": "Event page direction", "catalogRef": ["TC-B-002"]})
        cl.append({"id": "C8", "title": "Event page fonts", "catalogRef": ["TC-B-002"]})
        (run / "checklist.json").write_text(json.dumps(cl))
        cp = json.loads((run / "checkpoint.json").read_text())
        cp["criteria"] += [
            {"criterion_id": "C7", "persona": "", "verdict": "fail", "checkpointed_at": "2026-11-11T08:00:00Z"},
            {"criterion_id": "C7", "persona": "user", "verdict": "pass", "checkpointed_at": "2026-11-11T09:00:00Z"},
            {"criterion_id": "C8", "persona": "", "verdict": "blocked", "checkpointed_at": "2026-11-11T09:00:00Z"},
            {"criterion_id": "C8", "persona": "user", "verdict": "pass", "checkpointed_at": "2026-11-11T09:00:00Z"},
        ]
        (run / "checkpoint.json").write_text(json.dumps(cp))
        crit = core.case_results(run)["TC-B-002"]["criteria"]
        self.assertEqual(
            sorted((c["id"], c["persona"], c["verdict"]) for c in crit),
            [("C7", "user", "pass"), ("C8", "", "blocked"), ("C8", "user", "pass")],
        )

    def test_missing_verification_is_not_an_error(self) -> None:
        run = self.tmp / "r1"
        shutil.copytree(str(RUN_R1), str(run))
        (run / "verification.json").unlink()
        res = core.case_results(run)
        self.assertEqual(res["TC-A-002"]["verdict"], "pass")


class OutboundTests(TempProject):
    def test_outbound_blocks_word_and_path(self) -> None:
        cfg = self.cfg()
        with self.assertRaises(core.WordingError) as ctx:
            core.outbound("the agent saw", cfg)
        self.assertEqual(ctx.exception.word, "agent")
        with self.assertRaises(core.WordingError):
            core.outbound("see app/Http/X.php", cfg)
        self.assertEqual(core.outbound("Agentur", cfg), "Agentur")

    def test_outbound_blocks_branch_and_pr(self) -> None:
        cfg = self.cfg()
        for text in ("fixed on feat/new-sidebar", "merged in PR #12", "see PR#7"):
            with self.assertRaises(core.WordingError):
                core.outbound(text, cfg)

    def test_redact_shared_password_from_guide(self) -> None:
        guide = self.tmp / ".qa" / "guide"
        guide.mkdir(parents=True)
        (guide / "02-test-accounts.md").write_text(
            "# Test accounts\n\nEvery QA account uses the **same password**:\n\n```\nS3cret!x\n```\n"
        )
        cfg = self.cfg()
        out = core.redact("Sign in with qa.user and S3cret!x.", cfg)
        self.assertEqual(out, "Sign in with qa.user and the shared QA password.")
        self.assertEqual(core.outbound("Use S3cret!x on qa.admin too", cfg), "Use the shared QA password on qa.admin too")
        self.assertEqual(core.redact("Password: S3cret!x", cfg), "[redacted]")

    def test_catalog_source_skips_forbidden_words_but_not_patterns(self) -> None:
        cfg = self.cfg()
        self.assertEqual(core.outbound("AI Assistant answers", cfg, source="catalog"), "AI Assistant answers")
        with self.assertRaises(core.WordingError):
            core.outbound("AI Assistant answers", cfg, source="generated")
        with self.assertRaises(core.WordingError):
            core.outbound("AI Assistant answers", cfg)
        with self.assertRaises(core.WordingError):
            core.outbound("see app/Http/X.php", cfg, source="catalog")
        with self.assertRaises(ValueError):
            core.outbound("x", cfg, source="other")

    def test_allow_phrases_are_exempt(self) -> None:
        cfg = self.cfg()
        self.assertEqual(cfg["wording"]["allow"], [])
        cfg["wording"]["allow"] = ["AI Screening"]
        text = "The ai screening score is missing"
        self.assertEqual(core.outbound(text, cfg), text)
        with self.assertRaises(core.WordingError) as ctx:
            core.outbound("AI Screening ran but the AI agent stopped", cfg)
        self.assertIn(ctx.exception.word, ("AI", "agent"))

    def test_redact_bug_export_patterns(self) -> None:
        cfg = self.cfg()
        self.assertEqual(core.redact("password: hunter2", cfg), "[redacted]")
        self.assertEqual(core.redact("send Bearer abc.def now", cfg), "send [redacted] now")
        self.assertNotIn("hunter2", core.redact("Token=hunter2 and more", cfg))

    def test_redact_pk_token(self) -> None:
        cfg = self.cfg()
        out = core.redact("token pk_live_ABCDEFGHIJKLMNOPQRSTUV end", cfg)
        self.assertEqual(out, "token [redacted] end")
        self.assertEqual(core.redact("pk_short", cfg), "pk_short")


class MapCacheTests(TempProject):
    def test_put_save_reload(self) -> None:
        cache = core.MapCache(self.tmp)
        self.assertIsNone(cache.get("case", "TC-A-001"))
        cache.put("case", "TC-A-001", "86abc", "h1")
        cache.save()
        path = self.tmp / ".qa" / "tracker-map.json"
        self.assertTrue(path.is_file())
        again = core.MapCache(self.tmp)
        self.assertEqual(again.get("case", "TC-A-001"), {"id": "86abc", "hash": "h1"})
        self.assertEqual([p.name for p in path.parent.iterdir() if p.name.startswith("tracker-map")],
                         ["tracker-map.json"])


    def test_corrupt_cache_is_empty_with_warning(self) -> None:
        path = self.tmp / ".qa" / "tracker-map.json"
        path.parent.mkdir(parents=True)
        for body in ("{broken", "[1, 2]"):
            path.write_text(body)
            err = io.StringIO()
            old, sys.stderr = sys.stderr, err
            try:
                cache = core.MapCache(self.tmp)
            finally:
                sys.stderr = old
            self.assertIsNone(cache.get("case", "TC-A-001"))
            self.assertEqual(len(err.getvalue().strip().splitlines()), 1)
            self.assertIn(str(path), err.getvalue())
        cache.put("case", "TC-A-001", "86abc", "h1")
        cache.save()
        self.assertEqual(core.MapCache(self.tmp).get("case", "TC-A-001"), {"id": "86abc", "hash": "h1"})


class ActionLogTests(unittest.TestCase):
    def test_action_log_format(self) -> None:
        out = io.StringIO()
        log = core.ActionLog(False, out=out)
        called = []
        log.act("create", "TC-A-001 · Sign in", lambda: called.append(1))
        log.act("update", "TC-A-002 · Wrong password", lambda: called.append(2))
        self.assertEqual(called, [])
        self.assertEqual(
            out.getvalue().splitlines(),
            ["DRY\tcreate\tTC-A-001 · Sign in", "DRY\tupdate\tTC-A-002 · Wrong password"],
        )
        self.assertEqual(log.summary(), 'SUMMARY {"create": 1, "update": 1} dry-run')

    def test_apply_calls_fn(self) -> None:
        out = io.StringIO()
        log = core.ActionLog(True, out=out)
        self.assertEqual(log.act("create", "x", lambda: 42), 42)
        self.assertEqual(out.getvalue(), "APPLY\tcreate\tx\n")
        self.assertEqual(log.summary(), 'SUMMARY {"create": 1} apply')


if __name__ == "__main__":
    unittest.main()
