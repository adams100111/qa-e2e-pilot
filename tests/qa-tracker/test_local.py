"""Tests for the tracker CLI (cli.py) and the local files backend (local.py)."""
from __future__ import annotations

import contextlib
import io
import json
import shutil
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "qa-kit" / "scripts"))

from trackers import cli, core  # noqa: E402
from trackers.ctx import build_token, run_dir_for, run_label  # noqa: E402

FIX = Path(__file__).resolve().parent / "fixtures"


class LocalProject(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="qa-tracker-local."))
        self.addCleanup(shutil.rmtree, str(self.tmp), True)
        shutil.copytree(str(FIX / "catalog"), str(self.tmp / ".qa" / "catalog"))
        self.add_run("r1")

    def add_run(self, run_id: str, manifest: dict = None) -> Path:
        dest = self.tmp / ".qa" / "runs" / run_id
        shutil.copytree(str(FIX / "runs" / "r1"), str(dest))
        if manifest is not None:
            (dest / "run-manifest.json").write_text(json.dumps(manifest))
        return dest

    def run_cli(self, *argv: str):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = cli.main(list(argv) + ["--project", str(self.tmp)])
        return rc, out.getvalue(), err.getvalue()

    def tracker(self) -> Path:
        return self.tmp / ".qa" / "tracker"


class CliTests(LocalProject):
    def test_cli_validate_exit_codes(self) -> None:
        rc, out, _ = self.run_cli("validate")
        self.assertEqual(rc, 0)
        self.assertEqual(json.loads(out), {"errors": [], "ok": True})
        manifest = self.tmp / ".qa" / "catalog" / "manifest.json"
        data = json.loads(manifest.read_text())
        data["areas"][0]["counts"]["P1"] = 9
        manifest.write_text(json.dumps(data))
        rc, out, _ = self.run_cli("validate")
        self.assertEqual(rc, 1)
        self.assertFalse(json.loads(out)["ok"])

    def test_results_prints_case_results(self) -> None:
        rc, out, _ = self.run_cli("results", "--run", "r1")
        self.assertEqual(rc, 0)
        self.assertEqual(json.loads(out)["TC-A-001"]["verdict"], "fail")

    def test_unsupported_verb_exit_2(self) -> None:
        fake = types.SimpleNamespace(push_run=lambda ctx: None)
        with mock.patch.dict(cli.BACKENDS, {"local": "fake"}), \
                mock.patch.object(cli, "load_backend", return_value=fake):
            rc, _, err = self.run_cli("pull-plan")
        self.assertEqual(rc, 2)
        self.assertIn("local does not support pull-plan", err)

    def test_status_with_broken_catalog_prints_catalog_error(self) -> None:
        (self.tmp / ".qa" / "catalog" / "manifest.json").unlink()
        cfgdir = self.tmp / "docs" / "agents"
        cfgdir.mkdir(parents=True)
        (cfgdir / "qa-tracker.json").write_text(json.dumps({
            "backend": "clickup", "ids": {"workspace": "1", "folder": "2"}}))
        rc, _, err = self.run_cli("status")
        self.assertEqual(rc, 1)
        self.assertIn("catalog error:", err)
        self.assertIn("no manifest", err)
        self.assertNotIn("needs a catalog", err)

    def test_missing_config_notes_local_backend_once(self) -> None:
        rc, _, err = self.run_cli("status")
        self.assertEqual(rc, 0)
        note = "no docs/agents/qa-tracker.json: using the local backend"
        self.assertEqual(err.count(note), 1)
        cfgdir = self.tmp / "docs" / "agents"
        cfgdir.mkdir(parents=True)
        (cfgdir / "qa-tracker.json").write_text("{}")
        _, _, err = self.run_cli("status")
        self.assertNotIn(note, err)

    def test_run_helpers(self) -> None:
        self.add_run("2026-11-02-b", {"build": "v1.4.2"})
        run_dir = self.tmp / ".qa" / "runs" / "2026-11-02-b"
        self.assertEqual(run_label(run_dir, types.SimpleNamespace(label=None)), "2026-11-02 v1.4.2")
        self.assertEqual(run_label(run_dir, types.SimpleNamespace(label="Beta")), "Beta")
        self.assertEqual(run_label(self.tmp / ".qa" / "runs" / "2026-11-05-x"), "2026-11-05")
        self.assertEqual(run_dir_for(self.tmp, "r1").name, "r1")

    def test_run_label_keeps_only_the_version_token(self) -> None:
        self.add_run("2026-11-09-v3", {"build_id": "v1.4.46 (next@beb2492a7) - preflight could not auto-detect"})
        run_dir = self.tmp / ".qa" / "runs" / "2026-11-09-v3"
        self.assertEqual(run_label(run_dir, types.SimpleNamespace(label=None)), "2026-11-09 v1.4.46")
        self.assertIn(run_dir_for(self.tmp, None).name, ("r1", "2026-11-02-b"))

    def test_build_token_keeps_only_a_version(self) -> None:
        self.assertEqual(build_token("next@abc1234"), "")
        self.assertEqual(build_token("3f9da0c"), "")
        self.assertEqual(build_token("v1.4.46 (next@x)"), "v1.4.46")
        self.assertEqual(build_token("1.2"), "1.2")
        self.assertEqual(build_token("v2.0.1-rc.1"), "v2.0.1-rc.1")
        self.assertEqual(build_token("feature/login"), "")
        self.add_run("2026-11-10-c", {"build": "3f9da0c"})
        run_dir = self.tmp / ".qa" / "runs" / "2026-11-10-c"
        self.assertEqual(run_label(run_dir, types.SimpleNamespace(label=None)), "2026-11-10")


class LocalBackendTests(LocalProject):
    def test_dry_run_writes_nothing(self) -> None:
        for verb in ("init", "push-run", "push-results", "push-bug"):
            rc, out, _ = self.run_cli(verb, "--run", "r1")
            self.assertEqual(rc, 0, verb)
        self.assertFalse((self.tmp / ".qa" / "tracker").exists())
        self.assertIn("SUMMARY", out)

    def test_init_creates_dirs(self) -> None:
        self.assertEqual(self.run_cli("init", "--apply")[0], 0)
        self.assertTrue((self.tracker() / "runs").is_dir())
        self.assertTrue((self.tracker() / "bugs").is_dir())

    def test_plan_verbs_have_nothing_to_do(self) -> None:
        for verb in ("push-plan", "pull-plan"):
            rc, out, _ = self.run_cli(verb, "--apply")
            self.assertEqual(rc, 0)
            self.assertIn("nothing to do: cases live in the catalog", out)

    def test_local_push_run_writes_table_once(self) -> None:
        rc, out, _ = self.run_cli("push-run", "--apply", "--run", "r1", "--label", "2026-11-02 v1")
        self.assertEqual(rc, 0)
        files = list((self.tracker() / "runs").glob("*.md"))
        self.assertEqual([f.name for f in files], ["r1.md"])
        text = files[0].read_text()
        self.assertTrue(text.startswith("# Run 2026-11-02 v1"))
        self.assertIn("| Case | Title | Result | Criteria |", text)
        self.assertLess(text.index("TC-A-001"), text.index("TC-A-002"))
        self.assertIn("create", out)
        rc, out2, _ = self.run_cli("push-results", "--apply", "--run", "r1", "--label", "2026-11-02 v1")
        self.assertEqual(rc, 0)
        self.assertNotIn("update", out2)
        self.assertEqual(files[0].read_text(), text)
        rc, out3, _ = self.run_cli("push-run", "--apply", "--run", "r1", "--label", "2026-11-03 v2")
        self.assertIn("update", out3)

    def test_local_push_bug_dedupes_by_fingerprint(self) -> None:
        self.add_run("r2")
        self.assertEqual(self.run_cli("push-bug", "--apply", "--run", "r1", "--label", "L1")[0], 0)
        bugs = sorted((self.tracker() / "bugs").glob("*.md"))
        self.assertEqual(len(bugs), 1)
        self.assertRegex(bugs[0].name, r"^001-sidebar-shows-the-wrong-name")
        text = bugs[0].read_text()
        self.assertTrue(text.startswith("---\n"))
        for line in ("status: open", "severity: high", "case: TC-A-001", "found_in: L1"):
            self.assertIn(line, text)
        self.assertIn("ref: " + core.fingerprint("TC-A-001", "user", "Sidebar shows the wrong name after sign in"), text)
        self.run_cli("push-bug", "--apply", "--run", "r2", "--label", "L2")
        bugs = sorted((self.tracker() / "bugs").glob("*.md"))
        self.assertEqual(len(bugs), 1)
        self.assertEqual(bugs[0].read_text().count("- Still happens on L2"), 1)
        self.run_cli("push-bug", "--apply", "--run", "r2", "--label", "L2")
        self.assertEqual(bugs[0].read_text().count("- Still happens on L2"), 1)

    def test_push_bug_wording_hit_skips_item(self) -> None:
        run = self.tmp / ".qa" / "runs" / "r1" / "bugs" / "bugs.json"
        rows = json.loads(run.read_text())
        rows[0]["actual"] = "The automated agent saw the old name."
        run.write_text(json.dumps(rows))
        rc, out, _ = self.run_cli("push-bug", "--apply", "--run", "r1")
        self.assertEqual(rc, 0)
        self.assertIn("SKIP\twording\t", out)
        self.assertFalse((self.tracker() / "bugs").exists() and list((self.tracker() / "bugs").glob("*.md")))

    def test_local_retest_never_changes_status(self) -> None:
        bugs = self.tracker() / "bugs"
        bugs.mkdir(parents=True)
        (self.tmp / ".qa" / "runs" / "r1" / "checkpoint.json").write_text(json.dumps({"criteria": [
            {"criterion_id": "C3", "persona": "user", "verdict": "pass"}]}))
        (self.tmp / ".qa" / "runs" / "r1" / "verification.json").unlink()
        f = bugs / "001-wrong-password.md"
        f.write_text("---\nstatus: retest\nseverity: low\ncase: TC-A-002\nref: abc\nfound_in: L0\n---\n# Wrong password\n")
        g = bugs / "002-other.md"
        g.write_text("---\nstatus: open\nseverity: low\ncase: TC-A-002\nref: def\nfound_in: L0\n---\n# Other\n")
        rc, _, _ = self.run_cli("update-retest", "--apply", "--run", "r1", "--label", "L9")
        self.assertEqual(rc, 0)
        text = f.read_text()
        self.assertIn("- Retest on L9: passed", text)
        self.assertIn("status: retest", text)
        self.assertNotIn("Retest", g.read_text())
        self.run_cli("update-retest", "--apply", "--run", "r1", "--label", "L9")
        self.assertEqual(f.read_text().count("Retest on L9"), 1)

    def _ref(self) -> str:
        return core.fingerprint("TC-A-001", "user", "Sidebar shows the wrong name after sign in")

    def _bug(self, name: str, status: str, found_in: str = "L0", extra: str = "", bom: bool = False,
             case: str = "TC-A-001") -> Path:
        d = self.tracker() / "bugs"
        d.mkdir(parents=True, exist_ok=True)
        f = d / name
        text = ("\ufeff" if bom else "") + f"---  \nstatus: {status}\nseverity: high\ncase: {case}\n" \
            f"ref: {self._ref()}\nfound_in: {found_in}\n---  \n# Sidebar\n{extra}"
        f.write_text(text, encoding="utf-8")
        return f

    def test_front_matter_tolerance_closed_variants(self) -> None:
        f = self._bug("001-sidebar.md", "Closed", bom=True)
        self.run_cli("push-bug", "--apply", "--run", "r1", "--label", "L2")
        self.assertEqual(len(list((self.tracker() / "bugs").glob("*.md"))), 2)
        self.assertNotIn("Still happens", f.read_text(encoding="utf-8"))

    def test_front_matter_tolerance_quoted_retest(self) -> None:
        f = self._bug("001-sidebar.md", '"retest"', bom=True)
        self.run_cli("update-retest", "--apply", "--run", "r1", "--label", "L5")
        self.assertIn("- Retest on L5: still failing", f.read_text(encoding="utf-8"))
        self.assertIn('status: "retest"', f.read_text(encoding="utf-8"))

    def test_still_happens_dedupe_is_exact_not_substring(self) -> None:
        f = self._bug("001-sidebar.md", "open", found_in="L10", extra="- Still happens on L10\n")
        self.run_cli("push-bug", "--apply", "--run", "r1", "--label", "L1")
        text = f.read_text(encoding="utf-8")
        self.assertIn("- Still happens on L1\n", text)
        self.assertEqual(len(list((self.tracker() / "bugs").glob("*.md"))), 1)

    def test_dry_run_same_ref_twice_logs_one_create(self) -> None:
        run = self.tmp / ".qa" / "runs" / "r1" / "bugs" / "bugs.json"
        rows = json.loads(run.read_text())
        run.write_text(json.dumps(rows + rows))
        _, out, _ = self.run_cli("push-bug", "--run", "r1")
        self.assertEqual(out.count("DRY\tcreate"), 1)
        self.assertNotIn("DRY\tupdate", out)

    def test_same_ref_twice_in_apply_makes_one_file(self) -> None:
        run = self.tmp / ".qa" / "runs" / "r1" / "bugs" / "bugs.json"
        rows = json.loads(run.read_text())
        run.write_text(json.dumps(rows + rows))
        self.run_cli("push-bug", "--apply", "--run", "r1", "--label", "L1")
        files = list((self.tracker() / "bugs").glob("*.md"))
        self.assertEqual(len(files), 1)
        self.assertNotIn("Still happens", files[0].read_text(encoding="utf-8"))

    def test_malformed_bugs_json_is_a_clean_error(self) -> None:
        (self.tmp / ".qa" / "runs" / "r1" / "bugs" / "bugs.json").write_text("{not json")
        rc, _, err = self.run_cli("push-bug", "--apply", "--run", "r1")
        self.assertEqual(rc, 1)
        self.assertIn("bugs.json", err)
        self.assertNotIn("Traceback", err)

    def test_create_collision_fails_loudly(self) -> None:
        from trackers import local
        p = self.tmp / "x.md"
        p.write_text("a")
        with self.assertRaises(FileExistsError):
            local._create(p, "b")
        self.assertEqual(p.read_text(), "a")

    def test_bugs_to_issue_tracker_skips_bug_verbs(self) -> None:
        cfgdir = self.tmp / "docs" / "agents"
        cfgdir.mkdir(parents=True)
        (cfgdir / "qa-tracker.json").write_text(json.dumps({"bugsTo": "issue-tracker"}))
        for verb in ("push-bug", "update-retest"):
            rc, out, _ = self.run_cli(verb, "--apply", "--run", "r1")
            self.assertEqual(rc, 0)
            self.assertIn("SKIP\tbugs-elsewhere\tbugs are tracked in the project's issue tracker "
                          "(docs/agents/issue-tracker.md)", out)
        self.assertFalse((self.tracker() / "bugs").exists())

    def test_bugs_to_invalid_value_is_config_error(self) -> None:
        cfgdir = self.tmp / "docs" / "agents"
        cfgdir.mkdir(parents=True)
        (cfgdir / "qa-tracker.json").write_text(json.dumps({"bugsTo": "nowhere"}))
        rc, _, err = self.run_cli("push-bug", "--run", "r1")
        self.assertEqual(rc, 1)
        self.assertIn("bugsTo", err)


if __name__ == "__main__":
    unittest.main()
