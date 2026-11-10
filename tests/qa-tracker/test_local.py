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
from trackers.ctx import run_dir_for, run_label  # noqa: E402

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

    def test_run_helpers(self) -> None:
        self.add_run("2026-11-02-b", {"build": "v1.4.2"})
        run_dir = self.tmp / ".qa" / "runs" / "2026-11-02-b"
        self.assertEqual(run_label(run_dir, types.SimpleNamespace(label=None)), "2026-11-02 v1.4.2")
        self.assertEqual(run_label(run_dir, types.SimpleNamespace(label="Beta")), "Beta")
        self.assertEqual(run_label(self.tmp / ".qa" / "runs" / "2026-11-05-x"), "2026-11-05")
        self.assertEqual(run_dir_for(self.tmp, "r1").name, "r1")
        self.assertIn(run_dir_for(self.tmp, None).name, ("r1", "2026-11-02-b"))


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


if __name__ == "__main__":
    unittest.main()
