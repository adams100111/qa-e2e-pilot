"""HTTP transport for the ClickUp tracker adapter, plus a replay fake for tests."""
from __future__ import annotations

import errno
import json
import mimetypes
import os
import re
import secrets
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Callable, Optional, Tuple

from trackers.core import ConfigError  # noqa: F401  (re-exported: one ConfigError class)

BASE_URL = "https://api.clickup.com/api"
MAX_TRIES = 5
RETRY_STEP = 15
WRITE_PAUSE = 0.35
_TOKEN_RE = re.compile(r"pk_[A-Za-z0-9_]+")
DEFAULT_TOKEN_ENV = "CLICKUP_API_TOKEN"
_TOKEN_ENV_RE = re.compile(r"^[A-Z][A-Z0-9_]*$")  # the same rule core.load_config applies to tokenEnv
_TOKEN_UNSAFE_RE = re.compile(r"[\s\x00-\x1f\x7f-\x9f]")  # whitespace or a control character
UPLOAD_FIELD = "attachment"


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

    def upload(self, path: str, file_path: Path, filename: str) -> dict:
        """POST the file at `file_path` to `path` as multipart field `attachment`, shown to the
        tracker under `filename` (the local path and name are never sent)."""
        raise NotImplementedError


def _neutral_name(filename: str) -> str:
    """The last path segment of a caller-supplied name, with nothing that can end or extend the
    Content-Disposition header (quotes, backslashes, control characters)."""
    name = re.split(r"[/\\]", str(filename or ""))[-1]
    name = re.sub(r'[\x00-\x1f\x7f"]', "_", name).strip()
    return name or UPLOAD_FIELD


def multipart_body(data: bytes, filename: str) -> Tuple[bytes, str]:
    """One-file multipart/form-data body and its Content-Type. The boundary is random and is
    redrawn until it does not occur in the file."""
    name = _neutral_name(filename)
    while True:
        boundary = "qakit" + secrets.token_hex(16)
        if boundary.encode() not in data:
            break
    ctype = mimetypes.guess_type(name)[0] or "application/octet-stream"
    head = ('--%s\r\nContent-Disposition: form-data; name="%s"; filename="%s"\r\nContent-Type: %s\r\n\r\n'
            % (boundary, UPLOAD_FIELD, name, ctype)).encode("utf-8")
    return head + data + ("\r\n--%s--\r\n" % boundary).encode(), "multipart/form-data; boundary=" + boundary


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
        data = json.dumps(body).encode() if body is not None else None
        return self._send(method.upper(), path, data, "application/json")

    def upload(self, path: str, file_path: Path, filename: str) -> dict:
        # a write: retried only on 429, like every non-GET call (it may have landed otherwise)
        data, ctype = multipart_body(Path(file_path).read_bytes(), filename)
        return self._send("POST", path, data, ctype)

    def _send(self, method: str, path: str, data: Optional[bytes], content_type: str) -> dict:
        for n in range(1, MAX_TRIES + 1):
            req = urllib.request.Request(BASE_URL + path, data=data, method=method)
            req.add_header("Authorization", self._token)
            req.add_header("Content-Type", content_type)
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

    def upload(self, path: str, file_path: Path, filename: str) -> dict:
        if not Path(file_path).exists():  # the real transport would fail to read it
            raise FileNotFoundError(errno.ENOENT, os.strerror(errno.ENOENT), str(file_path))
        self.calls.append(("UPLOAD", path, filename))
        f = self.dir / ("UPLOAD_%s.json" % re.sub(r"[/?&=]", "_", path.strip("/")))
        return json.loads(f.read_text()) if f.is_file() else {}


def token_env_name(cfg: Any = None) -> str:
    """The variable name from `cfg["tokenEnv"]`, else the default. A value that is not a variable
    name (a pasted token, say) is rejected without being echoed."""
    name = cfg.get("tokenEnv") if isinstance(cfg, dict) else None
    if name is None:
        return DEFAULT_TOKEN_ENV
    if not (isinstance(name, str) and _TOKEN_ENV_RE.match(name)):
        raise ConfigError("tokenEnv must be the name of an environment variable, not the token")
    return name


def token_from_env(name: str = DEFAULT_TOKEN_ENV) -> str:
    """The token from the environment variable `name`, trimmed. A message names the variable only,
    never the value; a value with whitespace or a control character inside it is refused."""
    if not (isinstance(name, str) and _TOKEN_ENV_RE.match(name)):
        raise ConfigError("tokenEnv must be the name of an environment variable, not the token")
    tok = os.environ.get(name, "").strip()
    if not tok:
        raise ConfigError("set %s (a personal token)" % name)
    if _TOKEN_UNSAFE_RE.search(tok):
        # sent as a header it would fail with an error that repeats the value: refuse it here
        raise ConfigError("%s is not a valid token" % name)
    return tok
