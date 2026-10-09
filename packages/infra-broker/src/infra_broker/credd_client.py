"""Minimal client for infra-credd, reached through the broker's vsock bridge."""

from __future__ import annotations

import json
import os
import urllib.error
import urllib.request
from typing import Any

DEFAULT_URL = "http://127.0.0.1:9100"
DEFAULT_TOKEN_FILE = "/run/infra/credd-token"


class CreddError(Exception):
    pass


def base_url() -> str:
    return os.environ.get("INFRA_CREDD_URL", DEFAULT_URL).rstrip("/")


def token() -> str:
    value = os.environ.get("INFRA_CREDD_TOKEN")
    if value:
        return value
    path = os.environ.get("INFRA_CREDD_TOKEN_FILE", DEFAULT_TOKEN_FILE)
    try:
        with open(path, encoding="utf-8") as stream:
            return stream.read().strip()
    except OSError as error:
        raise CreddError(f"cannot read the credd token ({path}): {error}") from None


def request(method: str, path: str, body: Any = None, timeout: float = 60) -> Any:
    data = None if body is None else json.dumps(body).encode()
    headers = {"Authorization": f"Bearer {token()}"}
    if data is not None:
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(base_url() + path, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            payload = response.read()
    except urllib.error.HTTPError as error:
        try:
            message = json.loads(error.read()).get("error", error.reason)
        except (ValueError, AttributeError):
            message = error.reason
        raise CreddError(f"credd {path}: {message}") from None
    except (urllib.error.URLError, OSError) as error:
        raise CreddError(f"credd is unreachable at {base_url()}: {error}") from None
    return json.loads(payload) if payload else None


def get(path: str, timeout: float = 60) -> Any:
    return request("GET", path, timeout=timeout)


def post(path: str, body: Any, timeout: float = 10) -> Any:
    return request("POST", path, body, timeout=timeout)
