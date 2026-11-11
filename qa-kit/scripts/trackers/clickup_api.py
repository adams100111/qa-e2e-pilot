"""HTTP transport for the ClickUp tracker adapter, plus a replay fake for tests."""
from __future__ import annotations

import json
import os
import re
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Callable, Optional

from trackers.core import ConfigError  # noqa: F401  (re-exported: one ConfigError class)

BASE_URL = "https://api.clickup.com/api"
MAX_TRIES = 5
RETRY_STEP = 15
WRITE_PAUSE = 0.35
_TOKEN_RE = re.compile(r"pk_[A-Za-z0-9_]+")


class ApiError(Exception):
    """A failed API call.

    status 0 means a network or decode failure. Contract: a non-GET ApiError with
    status >= 500 or 0 may have landed; callers re-read by name before retrying a create.
    """

    def __init__(self, method: str, path: str, status: int, body: Any = None):
        self.method = method
        self.path = path
        self.status = status
        text = "" if body is None else (body if isinstance(body, str) else json.dumps(body))
        self.body = _TOKEN_RE.sub("[redacted]", text)
        super().__init__("%s %s -> HTTP %s %s" % (method, path, status, self.body[:300]))


class Transport:
    def request(self, method: str, path: str, body: Optional[dict] = None) -> dict:
        raise NotImplementedError


class HttpTransport(Transport):
    def __init__(self, token: str, opener: Optional[Callable] = None,
                 sleep: Callable[[float], None] = time.sleep):
        self._token = token
        self._open = opener or urllib.request.urlopen
        self._sleep = sleep

    def __repr__(self) -> str:
        return "HttpTransport()"

    def _clean(self, text: str) -> str:
        return text.replace(self._token, "[redacted]") if self._token else text

    def request(self, method: str, path: str, body: Optional[dict] = None) -> dict:
        method = method.upper()
        data = json.dumps(body).encode() if body is not None else None
        for n in range(1, MAX_TRIES + 1):
            req = urllib.request.Request(BASE_URL + path, data=data, method=method)
            req.add_header("Authorization", self._token)
            req.add_header("Content-Type", "application/json")
            status, text = 0, ""
            try:
                with self._open(req, timeout=60) as resp:
                    raw = resp.read()
                result = json.loads(raw) if raw else {}
                if method != "GET":
                    self._sleep(WRITE_PAUSE)
                return result
            except urllib.error.HTTPError as e:
                status = e.code
                try:
                    text = e.read().decode("utf-8", "replace")
                except Exception:
                    text = ""
                finally:
                    e.close()
            except (urllib.error.URLError, OSError, ValueError) as e:
                text = "%s: %s" % (type(e).__name__, e)
            if method != "GET":
                self._sleep(WRITE_PAUSE)
            retryable = (status == 429 or status >= 500 or status == 0) if method == "GET" else status == 429
            if not retryable or n == MAX_TRIES:
                raise ApiError(method, path, status, self._clean(text))
            self._sleep(RETRY_STEP * n)
        raise AssertionError("unreachable")


class FakeTransport(Transport):
    def __init__(self, fixture_dir):
        self.dir = Path(fixture_dir)
        self.calls: list = []

    def request(self, method: str, path: str, body: Optional[dict] = None) -> dict:
        method = method.upper()
        if method != "GET":
            self.calls.append((method, path, body))
        name = "%s_%s.json" % (method, re.sub(r"[/?&=]", "_", path.strip("/")))
        f = self.dir / name
        if method != "GET":
            return json.loads(f.read_text()) if f.is_file() else {}
        if not f.is_file():
            raise ApiError(method, path, 404, "no fixture %s" % name)
        return json.loads(f.read_text())


def token_from_env() -> str:
    tok = os.environ.get("CLICKUP_API_TOKEN", "").strip()
    if not tok:
        raise ConfigError("set CLICKUP_API_TOKEN (a personal token)")
    return tok
