from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PILOT = ROOT / "tools" / "skillopt-pilot"
SKILLOPT = Path("/home/dev/.local/share/skillopt")
sys.path.insert(0, str(PILOT))
sys.path.insert(0, str(SKILLOPT))

from stack_profile.dataloader import StackProfileDataLoader  # noqa: E402
from stack_profile.scoring import extract_result, score_result  # noqa: E402


class ExtractResultTests(unittest.TestCase):
    def test_extracts_plain_json_object(self) -> None:
        self.assertEqual(
            extract_result('{"framework":"laravel","signal":"strong"}'),
            {"framework": "laravel", "signal": "strong"},
        )

    def test_extracts_json_fence_with_surrounding_prose(self) -> None:
        text = 'Done.\n```json\n{"framework":"nextjs"}\n```\n'
        self.assertEqual(extract_result(text), {"framework": "nextjs"})

    def test_malformed_response_returns_empty_object(self) -> None:
        self.assertEqual(extract_result("not json"), {})


class ScoreResultTests(unittest.TestCase):
    def test_scores_required_and_forbidden_assertions(self) -> None:
        result = {
            "components": [{"framework": "laravel", "signal": "strong"}],
            "guardrails": None,
        }
        assertions = [
            {"path": "components.0.framework", "equals": "laravel"},
            {"path": "components.0.signal", "equals": "strong"},
            {"path": "guardrails", "equals": None},
            {"path": "components.0.framework", "not_equals": "generic"},
        ]

        score = score_result(result, assertions)

        self.assertEqual(score.hard, 1)
        self.assertEqual(score.soft, 1.0)
        self.assertEqual(score.passed, 4)
        self.assertEqual(score.total, 4)
        self.assertEqual(score.failures, ())

    def test_partial_score_names_failed_path(self) -> None:
        result = {"framework": "generic", "signal": "weak"}
        assertions = [
            {"path": "framework", "equals": "laravel"},
            {"path": "signal", "equals": "weak"},
        ]

        score = score_result(result, assertions)

        self.assertEqual(score.hard, 0)
        self.assertEqual(score.soft, 0.5)
        self.assertEqual(score.failures, ("framework: expected 'laravel', got 'generic'",))

    def test_empty_result_scores_zero(self) -> None:
        score = score_result({}, [{"path": "framework", "equals": "laravel"}])
        self.assertEqual((score.hard, score.soft), (0, 0.0))

    def test_rejects_ambiguous_assertion(self) -> None:
        with self.assertRaisesRegex(ValueError, "exactly one of equals or not_equals"):
            score_result({"x": 1}, [{"path": "x", "equals": 1, "not_equals": 2}])


class LoaderValidationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.data = self.root / "data"
        self.fixtures = self.root / "fixtures"
        self.fixtures.mkdir()
        (self.fixtures / "app").mkdir()
        (self.fixtures / "app" / "package.json").write_text('{"dependencies":{}}', encoding="utf-8")
        for split in ("train", "val", "test"):
            (self.data / split).mkdir(parents=True)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def write_split(self, split: str, items: list[dict]) -> None:
        (self.data / split / "items.json").write_text(json.dumps(items), encoding="utf-8")

    @staticmethod
    def item(item_id: str, prompt: str = "Inspect the fixture") -> dict:
        return {
            "id": item_id,
            "fixture": "app",
            "prompt": prompt,
            "assertions": [{"path": "framework", "equals": "generic"}],
            "task_type": "stack-profile",
        }

    def make_loader(self) -> StackProfileDataLoader:
        loader = StackProfileDataLoader(
            split_dir=str(self.data),
            split_mode="split_dir",
            fixtures_dir=str(self.fixtures),
        )
        loader.setup({})
        return loader

    def test_loads_unique_valid_items(self) -> None:
        self.write_split("train", [self.item("train-1", "train prompt")])
        self.write_split("val", [self.item("val-1", "validation prompt")])
        self.write_split("test", [self.item("test-1", "test prompt")])

        loader = self.make_loader()

        self.assertEqual([item["id"] for item in loader.train_items], ["train-1"])
        self.assertEqual(Path(loader.train_items[0]["fixture_path"]), self.fixtures / "app")

    def test_rejects_duplicate_ids_across_splits(self) -> None:
        self.write_split("train", [self.item("duplicate", "train prompt")])
        self.write_split("val", [self.item("duplicate", "validation prompt")])
        self.write_split("test", [self.item("test-1", "test prompt")])

        with self.assertRaisesRegex(ValueError, "duplicate item id 'duplicate'"):
            self.make_loader()

    def test_rejects_missing_fixture(self) -> None:
        item = self.item("train-1", "train prompt")
        item["fixture"] = "missing"
        self.write_split("train", [item])
        self.write_split("val", [self.item("val-1", "validation prompt")])
        self.write_split("test", [self.item("test-1", "test prompt")])

        with self.assertRaisesRegex(ValueError, "fixture does not exist"):
            self.make_loader()

    def test_rejects_semantically_identical_items_across_splits(self) -> None:
        self.write_split("train", [self.item("train-1")])
        self.write_split("val", [self.item("val-1")])
        self.write_split("test", [self.item("test-1", "different prompt")])

        with self.assertRaisesRegex(ValueError, "content overlaps splits train and val"):
            self.make_loader()


if __name__ == "__main__":
    unittest.main()
