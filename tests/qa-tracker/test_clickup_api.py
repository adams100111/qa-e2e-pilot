from __future__ import annotations

import io
import json
import os
import sys
import tempfile
import unittest
import urllib.error
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "qa-kit" / "scripts"))

from trackers import clickup_api as api  # noqa: E402


class _Resp:
    def __init__(self, body, status=200):
        self._b = json.dumps(body).encode()
        self.status = status

    def read(self):
        return self._b

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def _http_error(status, body=b"{}"):
    return urllib.error.HTTPError("u", status, "err", {}, io.BytesIO(body))


class HttpTransportTests(unittest.TestCase):
    def test_retry_on_429_then_success(self):
        calls, sleeps = [], []

        def opener(req, timeout=None):
            calls.append(req)
            if len(calls) == 1:
                raise _http_error(429)
            return _Resp({"ok": True})

        t = api.HttpTransport("pk_" + "a" * 24, opener=opener, sleep=sleeps.append)
        self.assertEqual(t.request("GET", "/v2/team"), {"ok": True})
        self.assertEqual(len(calls), 2)
        self.assertEqual(sleeps, [15])
        self.assertEqual(calls[0].full_url, "https://api.clickup.com/api/v2/team")
        self.assertEqual(calls[0].get_header("Authorization"), "pk_" + "a" * 24)

    def test_non_get_sleeps_after_call(self):
        sleeps = []
        t = api.HttpTransport("tok", opener=lambda r, timeout=None: _Resp({}), sleep=sleeps.append)
        t.request("POST", "/v2/list/1/task", {"name": "x"})
        self.assertEqual(sleeps, [0.35])

    def test_gives_up_after_five_tries(self):
        calls = []

        def opener(req, timeout=None):
            calls.append(1)
            raise _http_error(503)

        t = api.HttpTransport("tok", opener=opener, sleep=lambda s: None)
        with self.assertRaises(api.ApiError) as cm:
            t.request("GET", "/v2/x")
        self.assertEqual(len(calls), 5)
        self.assertEqual(cm.exception.status, 503)

    def test_token_never_in_error_text(self):
        token = "pk_" + "b" * 30

        def opener(req, timeout=None):
            raise _http_error(401, ('{"err":"bad ' + token + '"}').encode())

        t = api.HttpTransport(token, opener=opener, sleep=lambda s: None)
        with self.assertRaises(api.ApiError) as cm:
            t.request("GET", "/v2/x")
        self.assertNotIn("pk_", str(cm.exception))
        self.assertNotIn("pk_", repr(cm.exception))
        self.assertNotIn(token, repr(t))


class FakeTransportTests(unittest.TestCase):
    def test_fake_records_writes(self):
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "GET_v2_list_1_task.json").write_text('{"tasks": []}')
            f = api.FakeTransport(d)
            self.assertEqual(f.request("GET", "/v2/list/1/task"), {"tasks": []})
            f.request("POST", "/v2/list/1/task", {"name": "n"})
            self.assertEqual(f.calls, [("POST", "/v2/list/1/task", {"name": "n"})])

    def test_unknown_get_raises(self):
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaises(Exception):
                api.FakeTransport(d).request("GET", "/v2/nope")


class TokenTests(unittest.TestCase):
    def test_token_missing_message(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            with self.assertRaises(api.ConfigError) as cm:
                api.token_from_env()
        self.assertIn("set CLICKUP_API_TOKEN (a personal token)", str(cm.exception))

    def test_token_present(self):
        with mock.patch.dict(os.environ, {"CLICKUP_API_TOKEN": "pk_x"}):
            self.assertEqual(api.token_from_env(), "pk_x")


if __name__ == "__main__":
    unittest.main()
