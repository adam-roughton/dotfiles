"""infra-broker-gateway: one authenticated, audited, read-only MCP endpoint.

Mounts every configured upstream MCP server (stdio child processes or remote
HTTP servers) under a namespace (`<server>_<tool>`) and adds:

* bearer-token authentication, one token per incident (files in a directory
  that the host CLI manages; the file name is the incident name),
* a deny-by-default tool allowlist per upstream, applied to tools/list and
  tools/call (tools added by upgraded servers stay hidden until listed),
* an audit record for every call, sent to infra-credd on the host before the
  call runs (fail closed) and after it completes,
* a response size cap.

The gateway never forwards the agent's Authorization header upstream.
"""

from __future__ import annotations

import argparse
import asyncio
import fnmatch
import hashlib
import hmac
import json
import logging
import os
import re
import sys
import time
from pathlib import Path
from typing import Any, Callable

import mcp.types as mt
from fastmcp import Client, FastMCP
from fastmcp.client.transports import StdioTransport, StreamableHttpTransport
from fastmcp.exceptions import ToolError
from fastmcp.server.auth import TokenVerifier
from fastmcp.server.auth.auth import AccessToken
from fastmcp.server.dependencies import get_access_token
from fastmcp.server.middleware import Middleware, MiddlewareContext
from fastmcp.server.middleware.response_limiting import ResponseLimitingMiddleware
from fastmcp.server.providers.proxy import FastMCPProxy
from starlette.requests import Request
from starlette.responses import JSONResponse

from . import credd_client

log = logging.getLogger("infra-broker-gateway")
SERVER_NAME = re.compile(r"^[a-z][a-z0-9]*$")
ENV_REFERENCE = re.compile(r"\{env:([A-Za-z_][A-Za-z0-9_]*)\}")
# Variables every stdio upstream inherits from the gateway (credentials
# endpoints, CA bundles, proxy-free networking). Server-specific env is added.
INHERITED_ENV = (
    "PATH", "HOME", "TMPDIR", "LANG", "TZ",
    "SSL_CERT_FILE", "SSL_CERT_DIR", "REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE", "NODE_EXTRA_CA_CERTS", "AWS_CA_BUNDLE",
    "AWS_CONTAINER_CREDENTIALS_FULL_URI", "AWS_CONTAINER_AUTHORIZATION_TOKEN", "AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE",
    "AWS_REGION", "AWS_DEFAULT_REGION", "AWS_EC2_METADATA_DISABLED", "AWS_SDK_LOAD_CONFIG",
    "IDENTITY_ENDPOINT", "IDENTITY_HEADER", "AZURE_TOKEN_CREDENTIALS",
    "INFRA_CREDD_URL", "INFRA_CREDD_TOKEN_FILE",
)


def expand_env(value: str, environ: dict[str, str] | None = None) -> str:
    environ = os.environ if environ is None else environ

    def replace(match: re.Match[str]) -> str:
        name = match.group(1)
        if name not in environ:
            raise ValueError(f"environment variable {name} is not set")
        return environ[name]

    return ENV_REFERENCE.sub(replace, value)


class ToolPolicy:
    """Deny-by-default allowlist over namespaced tool names."""

    def __init__(self, servers: dict[str, dict[str, Any]], deny: list[str]):
        self.servers = servers
        self.deny = deny

    def allowed(self, name: str) -> bool:
        server, separator, tool = name.partition("_")
        if not separator or server not in self.servers:
            return False
        if any(fnmatch.fnmatchcase(name, pattern) for pattern in self.deny):
            return False
        settings = self.servers[server]
        if any(fnmatch.fnmatchcase(tool, pattern) for pattern in settings.get("denyTools", [])):
            return False
        return any(fnmatch.fnmatchcase(tool, pattern) for pattern in settings.get("allowTools", []))


class IncidentTokens(TokenVerifier):
    """Bearer tokens are files in `directory`; the file name is the incident."""

    def __init__(self, directory: str):
        super().__init__()
        self.directory = Path(directory)

    def lookup(self, token: str) -> str | None:
        if len(token) < 32:
            return None
        try:
            entries = sorted(self.directory.iterdir())
        except OSError:
            return None
        match = None
        for entry in entries:
            if entry.name.startswith(".") or not entry.is_file():
                continue
            try:
                candidate = entry.read_text().strip()
            except OSError:
                continue
            # Compare against every token so timing does not reveal which matched.
            if candidate and hmac.compare_digest(candidate, token):
                match = entry.name
        return match

    async def verify_token(self, token: str) -> AccessToken | None:
        incident = await asyncio.to_thread(self.lookup, token)
        if incident is None:
            return None
        return AccessToken(token=token, client_id=incident, scopes=[], expires_at=None)


def current_incident() -> str:
    access = get_access_token()
    return access.client_id if access else "unauthenticated"


class PolicyMiddleware(Middleware):
    def __init__(self, policy: ToolPolicy):
        self.policy = policy

    async def on_list_tools(self, context: MiddlewareContext, call_next: Callable) -> Any:
        tools = await call_next(context)
        # Output schemas are dropped: truncated results cannot carry structured
        # content, and clients reject results that miss a declared schema.
        return [tool.model_copy(update={"output_schema": None}) for tool in tools if self.policy.allowed(tool.name)]

    async def on_call_tool(self, context: MiddlewareContext[mt.CallToolRequestParams], call_next: Callable) -> Any:
        if not self.policy.allowed(context.message.name):
            raise ToolError(f"tool {context.message.name} is not permitted by the infra broker policy")
        return await call_next(context)


def result_digest(result: Any) -> tuple[int, str]:
    """Size and SHA-256 of a tool result's text content (results are not logged)."""
    texts = []
    for block in getattr(result, "content", None) or []:
        text = getattr(block, "text", None)
        texts.append(text if text is not None else repr(block))
    data = "\n".join(texts).encode()
    return len(data), hashlib.sha256(data).hexdigest()


class AuditMiddleware(Middleware):
    def __init__(self, environment: str, send: Callable[[dict[str, Any]], None]):
        self.environment = environment
        self.send = send

    async def emit(self, record: dict[str, Any]) -> None:
        await asyncio.to_thread(self.send, {"environment": self.environment, **record})

    async def on_call_tool(self, context: MiddlewareContext[mt.CallToolRequestParams], call_next: Callable) -> Any:
        incident = current_incident()
        name = context.message.name
        arguments = context.message.arguments or {}
        try:
            await self.emit({"event": "call", "incident": incident, "tool": name, "arguments": arguments})
        except Exception as error:  # noqa: BLE001 - any audit failure blocks the call
            log.error("audit failed, refusing %s: %s", name, error)
            raise ToolError("the infra broker cannot write its audit log; the call was not made") from None
        started = time.monotonic()
        try:
            result = await call_next(context)
        except Exception as error:
            await self.best_effort({"event": "error", "incident": incident, "tool": name,
                                    "durationMs": int((time.monotonic() - started) * 1000), "error": str(error)[:500]})
            raise
        size, digest = result_digest(result)
        await self.best_effort({"event": "result", "incident": incident, "tool": name,
                                "durationMs": int((time.monotonic() - started) * 1000),
                                "isError": bool(getattr(result, "is_error", False)), "bytes": size, "sha256": digest})
        return result

    async def best_effort(self, record: dict[str, Any]) -> None:
        try:
            await self.emit(record)
        except Exception as error:  # noqa: BLE001
            log.warning("audit record dropped: %s", error)


def send_to_credd(record: dict[str, Any]) -> None:
    credd_client.post("/audit", record)


def upstream_client(name: str, settings: dict[str, Any], log_dir: str | None,
                    common_env: dict[str, str] | None = None) -> Client:
    if "url" in settings:
        headers = {key: expand_env(value) for key, value in settings.get("headers", {}).items()}
        transport = StreamableHttpTransport(expand_env(settings["url"]), headers=headers)
    else:
        env = {key: os.environ[key] for key in INHERITED_ENV if key in os.environ}
        env.update({key: expand_env(value) for key, value in (common_env or {}).items()})
        env.update({key: expand_env(value) for key, value in settings.get("env", {}).items()})
        log_file = Path(log_dir) / f"{name}.log" if log_dir else None
        transport = StdioTransport(settings["command"], settings.get("args", []), env=env,
                                   cwd=settings.get("cwd"), keep_alive=True, log_file=log_file)
    timeout = settings.get("timeoutSeconds", 120)
    return Client(transport, timeout=timeout, init_timeout=settings.get("initTimeoutSeconds", 60))


class Upstream:
    """One long-lived MCP session per upstream server.

    Stdio servers are started once and initialized once: some (the Go-based
    kubernetes-mcp-server) reject a second `initialize`, which per-request
    sessions would send. A dead session (crashed server) is replaced on the
    next request.
    """

    def __init__(self, name: str, client: Client):
        self.name = name
        self.client = client
        # Never pass the agent's incident token to an upstream server.
        if isinstance(client.transport, StreamableHttpTransport):
            client.transport.forward_incoming_headers = False
        self.lock = asyncio.Lock()
        self.held = False

    def alive(self) -> bool:
        if not self.client.is_connected():
            return False
        transport = self.client.transport
        if isinstance(transport, StdioTransport):
            # The client keeps its session object after the process exits.
            task = getattr(transport, "_connect_task", None)
            dead = getattr(transport, "_is_session_dead", lambda: False)
            return task is not None and not task.done() and not dead()
        return True

    async def get(self) -> Client:
        async with self.lock:
            if not self.held or not self.alive():
                if self.held:
                    log.warning("upstream %s disconnected; reconnecting", self.name)
                    self.held = False
                    try:
                        await self.client.__aexit__(None, None, None)
                    except Exception:  # noqa: BLE001 - already broken
                        pass
                await self.client.__aenter__()
                self.held = True
        return self.client

    async def close(self) -> None:
        async with self.lock:
            if self.held:
                self.held = False
                await self.client.__aexit__(None, None, None)
            await self.client.transport.close()


def proxy_for(upstream: Upstream) -> FastMCPProxy:
    return FastMCPProxy(client_factory=upstream.get, name=f"infra-{upstream.name}")


def build(config: dict[str, Any], send_audit: Callable[[dict[str, Any]], None] = send_to_credd,
          clients: dict[str, Client] | None = None) -> tuple[FastMCP, dict[str, Upstream]]:
    servers: dict[str, dict[str, Any]] = config.get("servers", {})
    for name in servers:
        if not SERVER_NAME.match(name):
            raise ValueError(f"invalid server name {name!r}: use lowercase letters and digits (no '_')")
    environment = config.get("environment", "default")
    instructions = config.get("instructions") or (
        f"Read-only tools for the '{environment}' environment. Tool names are <source>_<tool>. "
        "Every call is audited. Results may contain customer data: keep them inside this incident.")
    gateway = FastMCP(f"infra-{environment}", instructions=instructions,
                      auth=IncidentTokens(config["tokensDirectory"]))
    upstreams: dict[str, Upstream] = {}
    for name, settings in servers.items():
        client = (clients or {}).get(name) or upstream_client(name, settings, config.get("logDirectory"), config.get("env"))
        upstreams[name] = Upstream(name, client)
        gateway.mount(proxy_for(upstreams[name]), namespace=name)
    gateway.add_middleware(PolicyMiddleware(ToolPolicy(servers, config.get("denyTools", []))))
    gateway.add_middleware(AuditMiddleware(environment, send_audit))
    gateway.add_middleware(ResponseLimitingMiddleware(
        max_size=int(config.get("maxResponseBytes", 200_000)),
        truncation_suffix="\n\n[infra broker: response truncated; narrow the query (filters, time range, limit)]"))

    @gateway.custom_route("/healthz", methods=["GET"])
    async def healthz(_: Request) -> JSONResponse:
        return JSONResponse({"ok": True, "environment": environment, "servers": sorted(servers)})

    return gateway, upstreams


async def warm_up(upstreams: dict[str, Upstream]) -> None:
    """Start stdio servers and check remote ones so the agent's first tools/list is fast."""

    async def one(upstream: Upstream) -> None:
        try:
            client = await upstream.get()
            async with client:
                tools = await client.list_tools()
            log.info("upstream %s ready with %d tools", upstream.name, len(tools))
        except Exception as error:  # noqa: BLE001
            log.warning("upstream %s is not available yet: %s", upstream.name, error)

    await asyncio.gather(*(one(upstream) for upstream in upstreams.values()))


async def serve(config: dict[str, Any]) -> None:
    gateway, upstreams = build(config)
    listen = config.get("listen", {})
    asyncio.get_running_loop().create_task(warm_up(upstreams))
    await gateway.run_http_async(
        transport="http",
        host=listen.get("host", "0.0.0.0"),
        port=int(listen.get("port", 8080)),
        path="/mcp",
        show_banner=False,
        host_origin_protection=True,
        allowed_hosts=config.get("allowedHosts", ["host.microsandbox.internal", "localhost", "127.0.0.1"]),
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="infra-broker-gateway", description=__doc__.splitlines()[0])
    parser.add_argument("--config", required=True)
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.INFO, stream=sys.stderr, format="%(asctime)s %(name)s %(levelname)s %(message)s")
    with open(args.config, encoding="utf-8") as stream:
        config = json.load(stream)
    asyncio.run(serve(config))
    return 0


if __name__ == "__main__":
    sys.exit(main())
