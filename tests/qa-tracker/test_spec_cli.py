"""Spec verbs through cli.main (dispatch, exit rules, token variable name) and Transport.upload.

The modules behind `cli.SPEC_VERBS` (`trackers.cards`, `trackers.clickup_spec`) arrive in later
tasks; here they are stub modules placed in `sys.modules`, so only the dispatch is under test.
"""
from __future__ import annotations

import contextlib
import io
import json
import os
import shutil
import sys
import tempfile
import types
import unittest
import urllib.error
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1] / "qa-kit" / "scripts"))
sys.path.insert(0, str(HERE))

import test_clickup_init as init_tests  # noqa: E402
import test_clickup_runs as runs_tests  # noqa: E402
from trackers import cli, clickup, core  # noqa: E402
from trackers import clickup_api as api  # noqa: E402

RUNS_FIX = HERE / "fixtures" / "clickup" / "runs"
TOKEN = "pk_1234567890_SECRETSECRETSECRET"
SPEC_VERBS = {
    "lint": "trackers.cards:lint_verb",
    "spec-init": "trackers.clickup_spec:spec_init",
    "push-scenarios": "trackers.clickup_spec:push_scenarios",
    "sync-run": "trackers.clickup_spec:sync_run",
    "push-docs": "trackers.clickup_spec:push_docs",
    "spec-note": "trackers.clickup_spec:spec_note",
    "spec-status": "trackers.clickup_spec:spec_status",
}


class _Resp:
    def __init__(self, body):
        self._b = json.dumps(body).encode()

    def read(self):
        return self._b

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def _http_error(status, body=b"{}"):
    return urllib.error.HTTPError("u", status, "err", {}, io.BytesIO(body))


class CliBase(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.cfg_path = self.tmp / "docs/agents/qa-tracker.json"
        self.cfg_path.parent.mkdir(parents=True)
        self.seen: list = []
        self.env = {"QA_KIT_TRACKER_CONFIG": str(self.tmp / "no-machine-file.json")}

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def write_cfg(self, **over):
        data = {"backend": "clickup", "ids": {"workspace": "9001", "space": "9002", "folder": "9003"}}
        data.update(over)
        self.cfg_path.write_text(json.dumps(data, indent=2) + "\n")

    def stubs(self, fn=None):
        """Stub modules for every handler in SPEC_VERBS; each call is recorded in `self.seen`."""
        def handler(name):
            def run(ctx):
                self.seen.append((name, ctx))
                if fn is not None:
                    fn(ctx)
            return run
        mods = {}
        for target in cli.SPEC_VERBS.values():
            mod_name, func = target.split(":")
            mod = mods.setdefault(mod_name, types.ModuleType(mod_name))
            setattr(mod, func, handler(func))
        return mods

    def run_cli(self, *argv, fn=None, env=None, stub=True):
        out, err = io.StringIO(), io.StringIO()
        environ = dict(self.env)
        environ.update(env or {})
        with contextlib.ExitStack() as stack:
            if stub:
                stack.enter_context(mock.patch.dict(sys.modules, self.stubs(fn)))
            stack.enter_context(mock.patch.dict(os.environ, environ))
            stack.enter_context(contextlib.redirect_stdout(out))
            stack.enter_context(contextlib.redirect_stderr(err))
            rc = cli.main(list(argv) + ["--project", str(self.tmp)])
        return rc, out.getvalue(), err.getvalue()


class SpecVerbTests(CliBase):
    def test_spec_verbs_table_is_exact(self):
        self.assertEqual(cli.SPEC_VERBS, SPEC_VERBS)

    def test_spec_verb_not_set_up_exits_0(self):
        self.write_cfg()
        for verb in SPEC_VERBS:
            rc, out, err = self.run_cli(verb, "--spec", "checkout")
            self.assertEqual(rc, 0, verb)
            self.assertIn("SKIP\tnot-set-up\tcheckout\n", out, verb)
        # no --spec and nothing enabled: the same line, still rc 0
        rc, out, _ = self.run_cli("sync-run")
        self.assertEqual(rc, 0)
        self.assertIn("SKIP\tnot-set-up", out)
        self.assertEqual(self.seen, [])

    def test_spec_verb_not_set_up_never_imports_the_handler(self):
        self.write_cfg(backend="local")
        blocked = {"trackers.cards": None, "trackers.clickup_spec": None}
        with mock.patch.dict(sys.modules, blocked):
            rc, out, _ = self.run_cli("push-scenarios", "--spec", "checkout", stub=False)
        self.assertEqual(rc, 0)
        self.assertIn("SKIP\tnot-set-up\tcheckout\n", out)

    def test_spec_verb_other_backend_exits_2(self):
        self.write_cfg(backend="local", specs={"checkout": {"enabled": True}})
        rc, out, err = self.run_cli("sync-run", "--spec", "checkout")
        self.assertEqual(rc, 2)
        self.assertIn("local does not support sync-run", err)
        self.assertEqual(self.seen, [])

    def test_lint_needs_no_backend_and_no_token(self):
        self.write_cfg(backend="local", specs={"checkout": {"enabled": True}})
        with mock.patch.object(api, "token_from_env", side_effect=AssertionError("token read")):
            rc, out, _ = self.run_cli("lint", "--spec", "checkout")
        self.assertEqual(rc, 0)
        self.assertEqual([n for n, _ in self.seen], ["lint_verb"])

    def test_spec_required_when_two_enabled(self):
        self.write_cfg(specs={"checkout": {"enabled": True}, "refunds": {"enabled": True}})
        rc, out, err = self.run_cli("sync-run")
        self.assertEqual(rc, 1)
        self.assertIn("error: name the spec with --spec\n", err)
        self.assertEqual(self.seen, [])
        rc, _, _ = self.run_cli("sync-run", "--spec", "refunds")
        self.assertEqual(rc, 0)
        self.assertEqual(self.seen[0][1].args.spec, "refunds")

    def test_single_enabled_spec_is_resolved(self):
        self.write_cfg(evidence="failures", specs={"checkout": {"enabled": True, "evidence": "none"},
                                                   "refunds": {"enabled": False}})
        rc, out, _ = self.run_cli("push-scenarios", "--apply")
        self.assertEqual(rc, 0)
        name, ctx = self.seen[0]
        self.assertEqual(name, "push_scenarios")
        self.assertEqual(ctx.args.spec, "checkout")
        self.assertEqual(ctx.cfg["target"], "checkout")
        self.assertEqual(ctx.cfg["evidence"], "none")  # the spec entry wins over the project value
        self.assertIsNone(ctx.catalog)
        self.assertTrue(ctx.log.apply)
        self.assertEqual(ctx.project, self.tmp.resolve())
        self.assertIn("SUMMARY {} apply", out)

    def test_spec_enabled_only_through_defaults_needs_the_flag(self):
        self.write_cfg(specDefaults={"enabled": True})
        rc, out, _ = self.run_cli("sync-run")
        self.assertEqual(rc, 0)
        self.assertIn("SKIP\tnot-set-up", out)
        self.assertEqual(self.seen, [])
        rc, out, _ = self.run_cli("sync-run", "--spec", "checkout")
        self.assertEqual(rc, 0)
        self.assertEqual(self.seen[0][1].cfg["target"], "checkout")

    def test_spec_verbs_never_load_the_catalog(self):
        self.write_cfg(specs={"checkout": {"enabled": True}})
        with mock.patch.object(core, "load_catalog", side_effect=AssertionError("catalog loaded")):
            for verb in SPEC_VERBS:
                rc, _, err = self.run_cli(verb, "--spec", "checkout")
                self.assertEqual(rc, 0, verb + err)
        self.assertEqual([n for n, _ in self.seen], [t.split(":")[1] for t in SPEC_VERBS.values()])

    def test_new_flags_reach_the_handler(self):
        self.write_cfg(specs={"checkout": {"enabled": True}})
        note = self.tmp / "note.txt"
        note.write_text("Two roles have no card yet.\n")
        self.run_cli("spec-note", "--file", str(note), "--blocked")
        self.run_cli("sync-run", "--retest", "--run", "r1")
        a, b = self.seen[0][1].args, self.seen[1][1].args
        self.assertEqual((a.file, a.blocked, a.retest), (str(note), True, False))
        self.assertEqual((b.file, b.blocked, b.retest, b.run), (None, False, True, "r1"))

    def test_skips_make_exit_1(self):
        self.write_cfg(specs={"checkout": {"enabled": True}})
        rc, out, _ = self.run_cli("push-scenarios", fn=lambda ctx: ctx.log.skip("wording", "card 3: title"))
        self.assertEqual(rc, 1)
        self.assertIn("SKIP\twording\tcard 3: title\n", out)
        self.assertIn('SUMMARY {"skip": 1} dry-run', out)

    def test_handler_errors_are_one_clean_line(self):
        self.write_cfg(specs={"checkout": {"enabled": True}})

        class CardsError(Exception):
            pass
        CardsError.__module__ = "trackers.cards"

        def boom(exc):
            def fn(ctx):
                raise exc
            return fn
        for exc, text in ((core.ConfigError("ids.folder is not set"), "config error: ids.folder is not set"),
                          (core.RunError("no checkpoint"), "error: no checkpoint"),
                          (CardsError("tracker-cards.json: not found; run /qa-scenarios"),
                           "error: tracker-cards.json: not found; run /qa-scenarios")):
            rc, out, err = self.run_cli("sync-run", fn=boom(exc))
            self.assertEqual(rc, 1, text)
            self.assertIn(text + "\n", err)
            self.assertNotIn("Traceback", err)
        with self.assertRaises(KeyError):  # a programming error is not dressed up as a clean one
            self.run_cli("sync-run", fn=boom(KeyError("x")))

    def test_api_error_names_the_configured_variable(self):
        self.write_cfg(tokenEnv="QA_TOKEN", specs={"checkout": {"enabled": True}})

        def denied(ctx):
            ctx.log.act("create", "one ticket")
            raise api.ApiError("POST", "/v2/list/1/task", 401, f"token {TOKEN} rejected")
        rc, out, err = self.run_cli("push-scenarios", fn=denied, env={"QA_TOKEN": TOKEN})
        self.assertEqual(rc, 1)
        self.assertIn("clickup error: HTTP 401 POST /v2/list/1/task\n", err)
        self.assertIn("hint: check QA_TOKEN (a personal token with access to this workspace)\n", err)
        self.assertIn('SUMMARY {"create": 1} dry-run', out)
        self.assertNotIn(TOKEN, out + err)
        self.assertNotIn("CLICKUP_API_TOKEN", err)

    def test_missing_module_is_not_hidden(self):
        self.write_cfg(specs={"checkout": {"enabled": True}})
        with mock.patch.dict(sys.modules, {"trackers.clickup_spec": None}):
            with self.assertRaises(ImportError):
                self.run_cli("sync-run", stub=False)


class TokenEnvTests(CliBase):
    def ctx(self, cfg):
        return types.SimpleNamespace(cfg=cfg, args=types.SimpleNamespace())

    def test_token_env_name_used(self):
        self.write_cfg(tokenEnv="QA_TOKEN")
        with mock.patch.dict(os.environ, dict(self.env, QA_TOKEN=TOKEN), clear=True):
            cfg = core.load_config(self.tmp)
            tr = clickup.transport_for(self.ctx(cfg))
            self.assertIsInstance(tr, api.HttpTransport)
            self.assertEqual(tr._token, TOKEN)
            self.assertEqual(api.token_from_env("QA_TOKEN"), TOKEN)

    def test_missing_token_names_the_configured_variable(self):
        self.write_cfg(tokenEnv="QA_TOKEN")
        with mock.patch.dict(os.environ, dict(self.env, CLICKUP_API_TOKEN=TOKEN), clear=True):
            cfg = core.load_config(self.tmp)
            with self.assertRaises(core.ConfigError) as cm:
                clickup.transport_for(self.ctx(cfg))
        self.assertEqual(str(cm.exception), "set QA_TOKEN (a personal token)")

    def test_default_variable_without_the_key(self):
        with mock.patch.dict(os.environ, {"CLICKUP_API_TOKEN": TOKEN}, clear=True):
            self.assertEqual(clickup.transport_for(self.ctx({}))._token, TOKEN)
            self.assertEqual(api.token_from_env(), TOKEN)

    def test_a_token_in_place_of_the_name_is_never_echoed(self):
        # specs.<t>.tokenEnv and specDefaults.tokenEnv are not checked by load_config
        for bad in (TOKEN, "lower_case", "", None, 7):
            with mock.patch.dict(os.environ, {}, clear=True):
                with self.assertRaises(core.ConfigError) as cm:
                    api.token_from_env(bad)
            self.assertNotIn("pk_", str(cm.exception))
            self.assertIn("tokenEnv", str(cm.exception))

    def test_old_verb_hint_names_the_configured_variable(self):
        shutil.copytree(RUNS_FIX / "project", self.tmp, dirs_exist_ok=True)
        shutil.copytree(RUNS_FIX / "run", self.tmp / ".qa" / "runs" / "r1")
        data = json.loads(self.cfg_path.read_text())
        data["tokenEnv"] = "QA_TOKEN"
        self.cfg_path.write_text(json.dumps(data))

        class Denied(runs_tests.FolderFake):
            def request(s, method, path, body=None):
                raise api.ApiError(method, path, 403, f"token {TOKEN} rejected")
        with mock.patch.object(clickup, "transport_for", return_value=Denied()):
            rc, out, err = self.run_cli("push-run", "--run", "r1", stub=False)
        self.assertEqual(rc, 1)
        self.assertIn("hint: check QA_TOKEN (a personal token with access to this workspace)\n", err)
        self.assertNotIn(TOKEN, out + err)


class BugsWithoutCatalogTests(CliBase):
    def setUp(self):
        super().setUp()
        shutil.copytree(RUNS_FIX / "project", self.tmp, dirs_exist_ok=True)
        shutil.copytree(RUNS_FIX / "run", self.tmp / ".qa" / "runs" / "r1")
        shutil.rmtree(self.tmp / "catalog")
        self.fake = runs_tests.FolderFake()

    def run_bugs(self, *argv):
        with mock.patch.object(clickup, "transport_for", return_value=self.fake):
            return self.run_cli(*argv, "--run", "r1", stub=False)

    def test_push_bug_without_catalog_with_spec(self):
        rc, out, err = self.run_bugs("push-bug", "--apply", "--spec", "checkout")
        self.assertNotIn("catalog error", err)
        self.assertEqual(rc, 0, err)
        self.assertTrue(self.fake.writes("POST", r"/v2/list/905/task$"))
        self.assertIn("SUMMARY ", out)

    def test_update_retest_without_catalog_with_spec(self):
        rc, out, err = self.run_bugs("update-retest", "--spec", "checkout")
        self.assertNotIn("catalog error", err)
        self.assertEqual(rc, 0, err)

    def test_without_spec_the_catalog_is_still_required(self):
        for verb in ("push-bug", "update-retest", "push-run", "push-results"):
            rc, out, err = self.run_bugs(verb)
            self.assertEqual(rc, 1, verb)
            self.assertIn("catalog error: ", err, verb)
        rc, _, err = self.run_bugs("push-run", "--spec", "checkout")  # only the two bug verbs
        self.assertEqual(rc, 1)
        self.assertIn("catalog error: ", err)
        self.assertEqual(self.fake.calls, [])


class InitUnchangedTests(init_tests.InitBase):
    def test_init_output_unchanged_without_specs(self):
        # the spec module must not even be imported when no spec is enabled
        fake = init_tests.InitFake()
        self.seed_complete(fake)
        with mock.patch.dict(os.environ, {"QA_KIT_TRACKER_CONFIG": str(self.tmp / "none.json")}):
            before = self.run_init(fake)
            with mock.patch.dict(sys.modules, {"trackers.clickup_spec": None}):
                after = self.run_init(fake)
        self.assertEqual(before, after)
        self.assertFalse(any("folder" in ln.lower() and "Ref" in ln for ln in after))


class UploadTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.file = self.tmp / "private-dir" / "shot 01.png"
        self.file.parent.mkdir()
        self.data = b"\x89PNG\r\n\x1a\n" + bytes(range(256)) + b"\r\n--tail"
        self.file.write_bytes(self.data)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def transport(self, opener, sleeps=None):
        return api.HttpTransport(TOKEN, opener=opener, sleep=(sleeps.append if sleeps is not None else lambda s: None))

    def test_upload_multipart_shape(self):
        reqs, sleeps = [], []

        def opener(req, timeout=None):
            reqs.append(req)
            return _Resp({"id": "att1"})

        t = self.transport(opener, sleeps)
        self.assertEqual(t.upload("/v2/task/t1/attachment", self.file, "sign-in-1.png"), {"id": "att1"})
        req = reqs[0]
        self.assertEqual(req.get_method(), "POST")
        self.assertEqual(req.full_url, "https://api.clickup.com/api/v2/task/t1/attachment")
        self.assertEqual(req.get_header("Authorization"), TOKEN)
        ctype = req.get_header("Content-type")
        self.assertTrue(ctype.startswith("multipart/form-data; boundary="), ctype)
        boundary = ctype.split("boundary=", 1)[1].encode()
        body = req.data
        head, _, rest = body.partition(b"\r\n\r\n")
        self.assertEqual(head.split(b"\r\n"), [
            b"--" + boundary,
            b'Content-Disposition: form-data; name="attachment"; filename="sign-in-1.png"',
            b"Content-Type: image/png"])
        self.assertEqual(rest, self.data + b"\r\n--" + boundary + b"--\r\n")
        # nothing about the local file or the token in the body or any header
        self.assertNotIn(b"private-dir", body)
        self.assertNotIn(b"shot 01", body)
        self.assertNotIn(TOKEN.encode(), body)
        others = {k: v for k, v in req.header_items() if k != "Authorization"}
        self.assertNotIn(TOKEN, json.dumps(others))
        self.assertNotIn("private-dir", json.dumps(others))
        self.assertEqual(sleeps, [0.35])

    def test_boundary_is_random_and_absent_from_the_file(self):
        seen = []

        def opener(req, timeout=None):
            seen.append(req.get_header("Content-type").split("boundary=", 1)[1])
            return _Resp({})

        t = self.transport(opener)
        t.upload("/v2/task/t1/attachment", self.file, "a.png")
        t.upload("/v2/task/t1/attachment", self.file, "a.png")
        self.assertNotEqual(seen[0], seen[1])
        self.assertGreaterEqual(len(seen[0]), 32)
        for b in seen:
            self.assertNotIn(b.encode(), self.data)

    def test_filename_cannot_break_the_header_or_carry_a_path(self):
        reqs = []

        def opener(req, timeout=None):
            reqs.append(req)
            return _Resp({})

        self.transport(opener).upload("/v2/task/t1/attachment", self.file, '../up/a"b\r\nX-Evil: 1.png')
        head = reqs[0].data.partition(b"\r\n\r\n")[0]
        self.assertEqual(len(head.split(b"\r\n")), 3)
        self.assertIn(b'filename="a_b__X-Evil: 1.png"', head)

    def test_upload_retries_only_on_429(self):
        calls, sleeps = [], []

        def limited(req, timeout=None):
            calls.append(1)
            if len(calls) == 1:
                raise _http_error(429)
            return _Resp({"id": "a"})

        self.assertEqual(self.transport(limited, sleeps).upload("/v2/task/t1/attachment", self.file, "a.png"),
                         {"id": "a"})
        self.assertEqual(len(calls), 2)
        self.assertEqual(sleeps, [0.35, 15, 0.35])
        for status, expect in ((500, 500), (0, 0), (400, 400)):
            calls.clear()

            def failing(req, timeout=None, status=status):
                calls.append(1)
                if status == 0:
                    raise urllib.error.URLError("down")
                raise _http_error(status)

            with self.assertRaises(api.ApiError) as cm:
                self.transport(failing).upload("/v2/task/t1/attachment", self.file, "a.png")
            self.assertEqual((len(calls), cm.exception.status), (1, expect))
            self.assertEqual((cm.exception.method, cm.exception.path), ("POST", "/v2/task/t1/attachment"))

    def test_upload_error_never_carries_the_token_or_the_local_path(self):
        def opener(req, timeout=None):
            raise _http_error(401, ('{"err":"bad ' + TOKEN + '"}').encode())

        with self.assertRaises(api.ApiError) as cm:
            self.transport(opener).upload("/v2/task/t1/attachment", self.file, "a.png")
        text = str(cm.exception) + repr(cm.exception) + cm.exception.body
        self.assertNotIn("pk_", text)
        self.assertNotIn("private-dir", text)

        def non_pk(req, timeout=None):
            raise _http_error(403, b"invalid tok-secret")

        t = api.HttpTransport("tok-secret", opener=non_pk, sleep=lambda s: None)
        with self.assertRaises(api.ApiError) as cm:
            t.upload("/v2/task/t1/attachment", self.file, "a.png")
        self.assertNotIn("tok-secret", str(cm.exception) + cm.exception.body)

    def test_missing_file_sends_nothing(self):
        calls = []
        t = self.transport(lambda r, timeout=None: calls.append(1) or _Resp({}))
        with self.assertRaises(FileNotFoundError):
            t.upload("/v2/task/t1/attachment", self.tmp / "gone.png", "a.png")
        self.assertEqual(calls, [])

    def test_base_transport_and_fake(self):
        with self.assertRaises(NotImplementedError):
            api.Transport().upload("/v2/task/t1/attachment", self.file, "a.png")
        f = api.FakeTransport(self.tmp)
        self.assertEqual(f.upload("/v2/task/t1/attachment", self.file, "a.png"), {})
        self.assertEqual(f.calls, [("UPLOAD", "/v2/task/t1/attachment", "a.png")])


if __name__ == "__main__":
    unittest.main()
