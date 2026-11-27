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


class SpecValidationTests(Base):
    SECRET = "pk_1234567890_ABCDEFGHIJKLMNOPQRSTUVWX"
    NOT_TOKEN = "tokenEnv must be the name of an environment variable, not the token"
    NOT_NAME = "tokenEnv must be an environment variable name (A-Z, 0-9, _)"

    def spec_error(self, data, target="judging") -> str:
        self.project_file(data)
        cfg = self.cfg()
        with self.assertRaises(core.ConfigError) as ctx:
            core.spec_settings(cfg, target)
        msg = str(ctx.exception)
        self.assertIn(str(self.tmp / "proj" / core.CONFIG_REL), msg)
        self.assertIn(f"specs.{target}", msg)
        return msg

    def load_error(self, data) -> str:
        self.project_file(data)
        with self.assertRaises(core.ConfigError) as ctx:
            self.cfg()
        return str(ctx.exception)

    def test_returns_config_with_project(self) -> None:
        self.project_file({"specs": {"judging": {"enabled": True}}})
        cfg = self.cfg()
        got = core.spec_settings(cfg, "judging")
        self.assertIsInstance(got, core.Config)
        self.assertEqual(got.project, self.tmp / "proj")
        self.assertEqual(core._project_of(got), self.tmp / "proj")
        # a plain dict in still works and carries no project
        plain = core.spec_settings(dict(cfg), "judging")
        self.assertIsInstance(plain, core.Config)
        self.assertIsNone(plain.project)

    def test_shared_password_masked_when_cwd_is_elsewhere(self) -> None:
        password = "Riyadh#2026x"
        self.project_file({"specs": {"judging": {"enabled": True}}})
        guide = self.tmp / "proj" / ".qa" / "guide" / "02-test-accounts.md"
        guide.parent.mkdir(parents=True)
        guide.write_text("All accounts use the same password:\n\n```\n" + password + "\n```\n")
        elsewhere = self.tmp / "elsewhere"
        elsewhere.mkdir()
        old = os.getcwd()
        os.chdir(str(elsewhere))
        self.addCleanup(os.chdir, old)
        cfg = self.cfg()
        text = f"Sign in with {password} and open the judging page"
        for source in core.OUTBOUND_SOURCES:
            out = core.outbound(text, core.spec_settings(cfg, "judging"), source)
            self.assertNotIn(password, out)
            self.assertIn(core.SHARED_PASSWORD_TEXT, out)
        self.assertNotIn(password, core.redact(text, core.spec_settings(cfg, "judging")))

    def test_spec_token_env_rejects_token_value(self) -> None:
        msg = self.spec_error({"specs": {"judging": {"tokenEnv": self.SECRET}}})
        self.assertIn(self.NOT_TOKEN, msg)
        self.assertNotIn(self.SECRET, msg)
        self.assertNotIn("pk_123", msg)

    def test_spec_defaults_token_env_rejects_token_value(self) -> None:
        msg = self.spec_error({"specDefaults": {"tokenEnv": self.SECRET}})
        self.assertIn(self.NOT_TOKEN, msg)
        self.assertNotIn(self.SECRET, msg)
        self.assertNotIn("pk_123", msg)

    def test_spec_token_env_rejects_non_name(self) -> None:
        for bad in ("lower case", "", 7, None, ["X"]):
            msg = self.spec_error({"specs": {"judging": {"tokenEnv": bad}}})
            self.assertIn(self.NOT_NAME, msg)
            if isinstance(bad, str) and bad:
                self.assertNotIn(bad, msg)
        self.project_file({"specs": {"judging": {"tokenEnv": "MY_TOKEN_2"}}})
        self.assertEqual(core.spec_settings(self.cfg(), "judging")["tokenEnv"], "MY_TOKEN_2")

    def test_spec_layout_enum(self) -> None:
        self.assertIn("layout", self.spec_error({"specs": {"judging": {"layout": "nested"}}}))
        self.assertIn("layout", self.spec_error({"specDefaults": {"layout": 1}}))
        for ok in ("subfolder", "flat"):
            self.project_file({"specs": {"judging": {"layout": ok}}})
            self.assertEqual(core.spec_settings(self.cfg(), "judging")["layout"], ok)
        self.project_file({"specs": {"judging": {}}})
        self.assertNotIn("layout", core.spec_settings(self.cfg(), "judging"))

    def test_spec_list_mode_enum(self) -> None:
        self.assertIn("listMode", self.spec_error({"specs": {"judging": {"listMode": "append"}}}))
        for ok in ("fresh", "reuse"):
            self.project_file({"specs": {"judging": {"listMode": ok}}})
            self.assertEqual(core.spec_settings(self.cfg(), "judging")["listMode"], ok)

    def test_spec_enabled_must_be_bool(self) -> None:
        for bad in ("yes", 1, 0, None):
            self.assertIn("enabled", self.spec_error({"specs": {"judging": {"enabled": bad}}}))
        self.assertIn("enabled", self.spec_error({"specDefaults": {"enabled": "true"}}))

    def test_enabled_specs_rejects_bad_entry(self) -> None:
        self.project_file({"specs": {"a": {"enabled": True}, "b": {"enabled": "yes"}}})
        with self.assertRaises(core.ConfigError):
            core.enabled_specs(self.cfg())

    def test_spec_evidence_cap_and_keep_runs(self) -> None:
        self.assertIn("evidenceCap", self.spec_error({"specs": {"judging": {"evidenceCap": 0}}}))
        self.assertIn("keepRuns", self.spec_error({"specs": {"judging": {"keepRuns": True}}}))
        for key in ("evidenceCap", "keepRuns"):
            for bad in (-1, 1.5, "3", None, False):
                self.assertIn(key, self.spec_error({"specDefaults": {key: bad}}))
        self.project_file({"specs": {"judging": {"evidenceCap": 1, "keepRuns": 10}}})
        got = core.spec_settings(self.cfg(), "judging")
        self.assertEqual((got["evidenceCap"], got["keepRuns"]), (1, 10))

    def test_spec_language_and_evidence(self) -> None:
        for bad in ("", "  ", 5, None):
            self.assertIn("language", self.spec_error({"specs": {"judging": {"language": bad}}}))
        self.assertIn("evidence", self.spec_error({"specs": {"judging": {"evidence": "all"}}}))

    def test_top_level_types(self) -> None:
        path = str(self.tmp / "proj" / core.CONFIG_REL)
        for data, key in (({"evidenceCap": 0}, "evidenceCap"), ({"evidenceCap": True}, "evidenceCap"),
                          ({"keepRuns": "3"}, "keepRuns"), ({"keepRuns": True}, "keepRuns"),
                          ({"language": ""}, "language"), ({"language": 3}, "language")):
            msg = self.load_error(data)
            self.assertIn(path, msg)
            self.assertIn(key, msg)

    def test_null_spec_entry_is_empty(self) -> None:
        self.project_file({"evidence": "failures", "specDefaults": {"language": "ar"}, "specs": {"judging": None}})
        cfg = self.cfg()
        got = core.spec_settings(cfg, "judging")
        want = core.spec_settings(cfg, "absent")
        want["target"] = "judging"
        self.assertEqual(got, want)
        self.assertIs(got["enabled"], False)
        self.assertEqual((got["evidence"], got["language"]), ("failures", "ar"))
        self.assertEqual(core.enabled_specs(cfg), [])

    def test_spec_defaults_deep_merge(self) -> None:
        self.project_file({"ids": {"workspace": "1", "space": "2", "folder": "3"},
                           "specDefaults": {"ids": {"space": "20"}, "wording": {"allow": ["AI Lab"]}},
                           "specs": {"judging": {"ids": {"folder": "30"}}}})
        cfg = self.cfg()
        got = core.spec_settings(cfg, "judging")
        self.assertEqual(got["ids"], {"workspace": "1", "space": "20", "folder": "30"})
        self.assertEqual(got["wording"]["allow"], ["AI Lab"])
        self.assertEqual(got["wording"]["forbidden"], cfg["wording"]["forbidden"])
        self.assertEqual(got["wording"]["patterns"], cfg["wording"]["patterns"])
        # the project config itself is left as it was
        self.assertEqual(cfg["ids"], {"workspace": "1", "space": "2", "folder": "3"})
        self.assertEqual(cfg["wording"]["allow"], [])


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
