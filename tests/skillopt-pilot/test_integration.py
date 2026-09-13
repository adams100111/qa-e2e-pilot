from __future__ import annotations

import json
import sys
import tempfile
import types
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PILOT = ROOT / "tools" / "skillopt-pilot"
SKILLOPT = Path("/home/dev/.local/share/skillopt")
sys.path.insert(0, str(PILOT))
sys.path.insert(0, str(SKILLOPT))

from stack_profile.adapter import StackProfileAdapter  # noqa: E402
from stack_profile.rollout import process_one, run_batch  # noqa: E402


class RolloutTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.fixture = self.root / "fixture"
        self.fixture.mkdir()
        (self.fixture / "package.json").write_text(
            '{"dependencies":{"next":"16.0.0"}}', encoding="utf-8"
        )
        self.item = {
            "id": "next-1",
            "fixture_path": str(self.fixture),
            "prompt": "Inspect project/ and classify the stack.",
            "assertions": [
                {"path": "framework", "equals": "nextjs"},
                {"path": "signal", "equals": "strong"},
            ],
            "task_type": "manifest-detection",
        }

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_process_one_copies_fixture_scores_and_persists_trajectory(self) -> None:
        calls: list[tuple[Path, str, str]] = []

        def fake_target(work_dir: Path, skill_md: str, task_text: str) -> str:
            calls.append((work_dir, skill_md, task_text))
            self.assertTrue((work_dir / "project" / "package.json").is_file())
            return '{"framework":"nextjs","signal":"strong"}'

        result = process_one(
            self.item,
            out_root=str(self.root / "out"),
            skill_content="# Detect stacks",
            target_runner=fake_target,
        )

        self.assertEqual((result["hard"], result["soft"]), (1, 1.0))
        self.assertTrue(result["agent_ok"])
        self.assertEqual(len(calls), 1)
        self.assertIn("# Detect stacks", calls[0][1])
        self.assertIn("Inspect project/", calls[0][2])
        conversation = self.root / "out" / "predictions" / "next-1" / "conversation.json"
        persisted = json.loads(conversation.read_text(encoding="utf-8"))
        self.assertEqual([turn["role"] for turn in persisted], ["system", "user", "assistant"])

    def test_process_one_records_malformed_response_as_failure(self) -> None:
        result = process_one(
            self.item,
            out_root=str(self.root / "out"),
            skill_content="# Detect stacks",
            target_runner=lambda *_args: "not json",
        )

        self.assertEqual((result["hard"], result["soft"]), (0, 0.0))
        self.assertIn("invalid or missing JSON", result["fail_reason"])

    def test_run_batch_raises_when_every_target_call_crashes(self) -> None:
        def crashing_target(*_args) -> str:
            raise RuntimeError("target unavailable")

        with self.assertRaisesRegex(RuntimeError, "all 1 stack-profile rollouts failed"):
            run_batch(
                items=[self.item],
                skill_content="# Detect stacks",
                out_root=str(self.root / "out"),
                target_runner=crashing_target,
            )


class AdapterTests(unittest.TestCase):
    def test_adapter_builds_batches_and_reports_task_types(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fixtures = root / "fixtures"
            (fixtures / "one").mkdir(parents=True)
            (fixtures / "one" / "README.md").write_text("fixture", encoding="utf-8")
            data = root / "data"
            for split, suffix in (("train", "a"), ("val", "b"), ("test", "c")):
                (data / split).mkdir(parents=True)
                item = [{
                    "id": f"{split}-1",
                    "fixture": "one",
                    "prompt": f"prompt {suffix}",
                    "assertions": [{"path": "framework", "equals": "generic"}],
                    "task_type": f"type-{suffix}",
                }]
                (data / split / "items.json").write_text(json.dumps(item), encoding="utf-8")

            adapter = StackProfileAdapter(
                split_dir=str(data), fixtures_dir=str(fixtures), split_mode="split_dir"
            )
            adapter.setup({})

            batch = adapter.build_eval_env(1, "selection", 42)
            self.assertEqual(batch[0]["id"], "val-1")
            self.assertEqual(adapter.get_task_types(), ["type-a", "type-b", "type-c"])


class RegistryTests(unittest.TestCase):
    def test_train_and_eval_entrypoints_register_local_adapter(self) -> None:
        train_module = types.SimpleNamespace(_ENV_REGISTRY={})
        eval_module = types.SimpleNamespace(_ENV_REGISTRY={})

        from train import register_adapter as register_train
        from eval import register_adapter as register_eval

        register_train(train_module)
        register_eval(eval_module)

        self.assertIs(train_module._ENV_REGISTRY["qa_stack_profile"], StackProfileAdapter)
        self.assertIs(eval_module._ENV_REGISTRY["qa_stack_profile"], StackProfileAdapter)


if __name__ == "__main__":
    unittest.main()
