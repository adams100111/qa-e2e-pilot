"""Layered tracker settings (machine < project < specDefaults < spec) and criterion_rows."""
from __future__ import annotations

import json
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "qa-kit" / "scripts"))

from trackers import core  # noqa: E402

FIX = Path(__file__).resolve().parent / "fixtures"
RUN_R1 = FIX / "runs" / "r1"


class Base(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="qa-tracker-spec."))
        self.addCleanup(shutil.rmtree, str(self.tmp), True)
        self.machine = self.tmp / "machine.json"
        old = os.environ.get(core.MACHINE_ENV)
        os.environ[core.MACHINE_ENV] = str(self.machine)
        self.addCleanup(self._restore, old)

    @staticmethod
    def _restore(old):
        if old is None:
            os.environ.pop(core.MACHINE_ENV, None)
        else:
            os.environ[core.MACHINE_ENV] = old

    def machine_file(self, data) -> None:
        self.machine.write_text(data if isinstance(data, str) else json.dumps(data))

    def project_file(self, data) -> None:
        path = self.tmp / "proj" / "docs" / "agents" / "qa-tracker.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(data))

    def cfg(self) -> dict:
        return core.load_config(self.tmp / "proj")


class SettingsTests(Base):
    def test_machine_path_uses_env(self) -> None:
        self.assertEqual(core.MACHINE_ENV, "QA_KIT_TRACKER_CONFIG")
        self.assertEqual(core.machine_config_path(), self.machine)

    def test_defaults(self) -> None:
        cfg = self.cfg()
        for key, val in (("tokenEnv", "CLICKUP_API_TOKEN"), ("language", "en"), ("evidence", "standard"),
                         ("evidenceCap", 3), ("keepRuns", 3), ("notify", None), ("reportUrl", None),
                         ("specs", {}), ("specDefaults", {})):
            self.assertEqual(cfg[key], val)

    def test_machine_applies_when_project_silent(self) -> None:
        self.machine_file({"language": "ar", "evidence": "failures"})
        cfg = self.cfg()
        self.assertEqual((cfg["language"], cfg["evidence"]), ("ar", "failures"))

    def test_project_overrides_machine(self) -> None:
        self.machine_file({"language": "ar"})
        self.project_file({"language": "en"})
        self.assertEqual(self.cfg()["language"], "en")

    def test_spec_overrides_project(self) -> None:
        self.project_file({"evidence": "failures", "specs": {"judging": {"evidence": "none"}}})
        cfg = self.cfg()
        self.assertEqual(core.spec_settings(cfg, "judging")["evidence"], "none")
        self.assertEqual(core.spec_settings(cfg, "other")["evidence"], "failures")
        self.assertEqual(core.spec_settings(cfg, "judging")["target"], "judging")

    def test_spec_defaults_enable_new_spec(self) -> None:
        self.project_file({"specDefaults": {"enabled": True}})
        self.assertIs(core.spec_settings(self.cfg(), "judging")["enabled"], True)
        self.project_file({"specDefaults": {"enabled": True}, "specs": {"judging": {"enabled": False}}})
        self.assertIs(core.spec_settings(self.cfg(), "judging")["enabled"], False)

    def test_spec_defaults_beat_project(self) -> None:
        self.project_file({"language": "en", "specDefaults": {"language": "ar"}})
        self.assertEqual(core.spec_settings(self.cfg(), "x")["language"], "ar")

    def test_enabled_specs_sorted(self) -> None:
        self.project_file({"specs": {"b": {"enabled": True}, "a": {"enabled": True}, "c": {"enabled": False}, "d": {}}})
        self.assertEqual(core.enabled_specs(self.cfg()), ["a", "b"])

    def test_spec_entry_must_be_object(self) -> None:
        self.project_file({"specs": {"judging": "yes"}})
        with self.assertRaises(core.ConfigError):
            core.spec_settings(self.cfg(), "judging")

    def test_machine_file_cannot_set_specs(self) -> None:
        self.machine_file({"specs": {"a": {"enabled": True}}})
        with self.assertRaises(core.ConfigError) as ctx:
            self.cfg()
        self.assertIn(str(self.machine), str(ctx.exception))

    def test_machine_file_cannot_set_ids_folder(self) -> None:
        self.machine_file({"ids": {"folder": "9"}})
        with self.assertRaises(core.ConfigError):
            self.cfg()
        self.machine_file({"ids": {"workspace": "1"}})
        self.assertEqual(self.cfg()["ids"]["workspace"], "1")

    def test_machine_file_not_object(self) -> None:
        self.machine_file("[1]")
        with self.assertRaises(core.ConfigError) as ctx:
            self.cfg()
        self.assertIn(str(self.machine), str(ctx.exception))

    def test_token_env_rejects_token_value(self) -> None:
        secret = "pk_1234567890_ABCDEFGHIJKLMNOPQRSTUVWX"
        self.project_file({"tokenEnv": secret})
        with self.assertRaises(core.ConfigError) as ctx:
            self.cfg()
        self.assertIn("tokenEnv must be the name of an environment variable, not the token", str(ctx.exception))
        self.assertNotIn(secret, str(ctx.exception))
        self.assertNotIn("pk_123", str(ctx.exception))
        self.project_file({"tokenEnv": "lower case"})
        with self.assertRaises(core.ConfigError):
            self.cfg()
        self.project_file({"tokenEnv": "MY_TOKEN_2"})
        self.assertEqual(self.cfg()["tokenEnv"], "MY_TOKEN_2")

    def test_evidence_enum(self) -> None:
        self.project_file({"evidence": "all"})
        with self.assertRaises(core.ConfigError):
            self.cfg()


class RowsTests(Base):
    # Golden output captured from case_results before it was rebuilt on criterion_rows.
    GOLDEN = '{"TC-A-001": {"confidence": "medium", "criteria": [{"id": "C1", "persona": "user", "verdict": "pass"}, {"id": "C2", "persona": "user", "verdict": "fail"}, {"id": "C4", "persona": "user", "verdict": "pass"}], "verdict": "fail"}, "TC-A-002": {"confidence": "high", "criteria": [{"id": "C3", "persona": "user", "verdict": "fail"}], "verdict": "fail"}, "TC-A-003": {"confidence": "medium", "criteria": [{"id": "C4", "persona": "user", "verdict": "pass"}], "verdict": "pass"}, "TC-B-001": {"confidence": "high", "criteria": [{"id": "C6", "persona": "admin", "verdict": "pass"}], "verdict": "pass"}}'

    def test_case_results_unchanged(self) -> None:
        self.assertEqual(json.dumps(core.case_results(RUN_R1), sort_keys=True), self.GOLDEN)

    def test_criterion_rows_verifier_downgrade(self) -> None:
        rows = core.criterion_rows(RUN_R1)
        got = rows[("C3", "user")]
        self.assertEqual(got["verdict"], "fail")
        run = self.tmp / "r"
        shutil.copytree(str(RUN_R1), str(run))
        vf = json.loads((run / "verification.json").read_text())
        for r in vf:
            if r["criterionId"] == "C3":
                r["verifierVerdict"] = "blocked"
        (run / "verification.json").write_text(json.dumps(vf))
        got = core.criterion_rows(run)[("C3", "user")]
        self.assertEqual(got["verdict"], "blocked")
        self.assertEqual(got["confidence"], "high")
        self.assertEqual(got["row"]["criterion_id"], "C3")

    def test_criterion_rows_persona_supersession(self) -> None:
        run = self.tmp / "r"
        shutil.copytree(str(RUN_R1), str(run))
        cp = json.loads((run / "checkpoint.json").read_text())
        cp["criteria"] += [
            {"criterion_id": "C9", "persona": "", "verdict": "fail", "checkpointed_at": "2026-11-11T08:00:00Z"},
            {"criterion_id": "C9", "persona": "user", "verdict": "pass", "checkpointed_at": "2026-11-11T09:00:00Z"},
        ]
        (run / "checkpoint.json").write_text(json.dumps(cp))
        rows = core.criterion_rows(run)
        self.assertNotIn(("C9", ""), rows)
        self.assertEqual(rows[("C9", "user")]["verdict"], "pass")


if __name__ == "__main__":
    unittest.main()
