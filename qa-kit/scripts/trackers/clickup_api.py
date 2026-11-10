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

BASE_URL = "https://api.clickup.com/api"
MAX_TRIES = 5
RETRY_STEP = 15
WRITE_PAUSE = 0.35
_TOKEN_RE = re.compile(r"pk_[A-Za-z0-9_]+")


class ConfigError(Exception):
    """Local stand-in; a later integration aliases it to core.ConfigError."""


class ApiError(Exception):
    def __init__(self, method: str, path: str, status: int, body: Any = None):
        self.method = method
        self.path = path
        self.status = status
        self.body = _TOKEN_RE.sub("[redacted]", body if isinstance(body, str) else json.dumps(body)) if body is not None else ""
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

    def request(self, method: str, path: str, body: Optional[dict] = None) -> dict:
        method = method.upper()
        data = json.dumps(body).encode() if body is not None else None
        last_status, last_body = 0, ""
        for n in range(1, MAX_TRIES + 1):
            req = urllib.request.Request(BASE_URL + path, data=data, method=method)
            req.add_header("Authorization", self._token)
            req.add_header("Content-Type", "application/json")
            try:
                with self._open(req, timeout=60) as resp:
                    raw = resp.read()
                result = json.loads(raw) if raw else {}
                if method != "GET":
                    self._sleep(WRITE_PAUSE)
                return result
            except urllib.error.HTTPError as e:
                last_status = e.code
                try:
                    last_body = e.read().decode("utf-8", "replace")
                except Exception:
                    last_body = ""
                if (e.code == 429 or e.code >= 500) and n < MAX_TRIES:
                    self._sleep(RETRY_STEP * n)
                    continue
                raise ApiError(method, path, e.code, last_body.replace(self._token, "[redacted]"))
        raise ApiError(method, path, last_status, last_body.replace(self._token, "[redacted]"))


class FakeTransport(Transport):
    def __init__(self, fixture_dir):
        self.dir = Path(fixture_dir)
        self.calls: list = []

    def request(self, method: str, path: str, body: Optional[dict] = None) -> dict:
        method = method.upper()
        if method != "GET":
            self.calls.append((method, path, body))
            return {}
        name = "%s_%s.json" % (method, path.strip("/").replace("/", "_"))
        f = self.dir / name
        if not f.is_file():
            raise ApiError(method, path, 404, "no fixture %s" % name)
        return json.loads(f.read_text())


def token_from_env() -> str:
    tok = os.environ.get("CLICKUP_API_TOKEN", "").strip()
    if not tok:
        raise ConfigError("set CLICKUP_API_TOKEN (a personal token)")
    return tok
