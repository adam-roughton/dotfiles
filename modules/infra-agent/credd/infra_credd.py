#!/usr/bin/env python3
"""infra-credd: host-side credential daemon for one infra-agent broker.

Serves short-lived credentials to the broker VM over a Unix socket (exposed to
the broker, and only the broker, as a microsandbox vsock route). Credentials are
minted lazily with the host's CLIs (aws, az, shell commands), cached until
shortly before they expire, and every mint is written to the audit log.

Endpoints (all require the broker token, see `authorized`):

  GET  /aws/<account>              AWS container-credentials format
  GET  /azure/token?resource=R     Azure App Service managed-identity format
  GET  /k8s/<cluster>              Kubernetes ExecCredential
  GET  /db/<source>                {"password": ...} for a database source
  POST /audit                      append one JSON audit record
  GET  /status                     cached credentials without secret values
  POST /revoke                     drop every cached credential
  GET  /healthz                    liveness (no token needed)

Standard library only: it runs on the host from the Nix store.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hmac
import json
import os
import socketserver
import subprocess
import sys
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler
from typing import Any, Callable

UTC = dt.timezone.utc
# Kubernetes' first-party AKS server application (audience for AKS AAD tokens).
AKS_SERVER_APP_ID = "6dae42f8-4368-4678-94ff-3960e28e3630"
MAX_AUDIT_BYTES = 64 * 1024


class CredentialError(Exception):
    """A credential could not be minted; the message is safe to return."""


def now() -> dt.datetime:
    return dt.datetime.now(UTC)


def rfc3339(moment: dt.datetime) -> str:
    return moment.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_time(value: Any) -> dt.datetime:
    """Parse the expiry formats the AWS and Azure CLIs emit."""
    if isinstance(value, (int, float)) or (isinstance(value, str) and value.isdigit()):
        return dt.datetime.fromtimestamp(int(value), UTC)
    if not isinstance(value, str) or not value:
        raise CredentialError("credential has no expiry")
    parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=UTC)
    return parsed.astimezone(UTC)


def normalize_resource(resource: str) -> str:
    """Azure clients ask for resources with or without a trailing slash or /.default."""
    resource = resource.strip()
    if resource.endswith("/.default"):
        resource = resource[: -len("/.default")]
    return resource.rstrip("/")


class Runner:
    """Runs host CLIs. Replaced in tests."""

    def __call__(self, argv: list[str] | str, env: dict[str, str] | None = None) -> str:
        shell = isinstance(argv, str)
        try:
            result = subprocess.run(
                argv,
                shell=shell,
                env=env,
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                timeout=120,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            raise CredentialError(f"cannot run {self.describe(argv)}: {error}") from None
        if result.returncode != 0:
            detail = result.stderr.strip().splitlines()[-1:] or ["no output"]
            raise CredentialError(f"{self.describe(argv)} failed: {detail[0][:300]}")
        return result.stdout

    @staticmethod
    def describe(argv: list[str] | str) -> str:
        return argv.split()[0] if isinstance(argv, str) else " ".join(argv[:3])


class Credd:
    def __init__(self, config: dict[str, Any], audit_path: str | None, run: Callable[..., str] | None = None):
        self.config = config
        self.environment = config.get("environment", "default")
        self.audit_path = audit_path
        self.run = run or Runner()
        self.margin = dt.timedelta(seconds=int(config.get("refreshMarginSeconds", 300)))
        self.cache: dict[tuple[str, str], tuple[dt.datetime, dict[str, Any], str]] = {}
        self.lock = threading.Lock()
        self.key_locks: dict[tuple[str, str], threading.Lock] = {}

    # -- cache -------------------------------------------------------------

    def cached(self, kind: str, key: str, mint: Callable[[], tuple[dt.datetime, dict[str, Any], str]]) -> dict[str, Any]:
        with self.lock:
            key_lock = self.key_locks.setdefault((kind, key), threading.Lock())
        # One mint per credential at a time; other credentials are not blocked.
        with key_lock:
            entry = self.cache.get((kind, key))
            if entry and entry[0] - self.margin > now():
                return entry[1]
            expires, value, principal = mint()
            if expires - self.margin <= now():
                raise CredentialError(f"{kind} credential for {key} expires too soon ({rfc3339(expires)})")
            self.cache[(kind, key)] = (expires, value, principal)
        self.audit({"source": "credd", "event": "mint", "kind": kind, "key": key,
                    "principal": principal, "expires": rfc3339(expires)})
        return value

    def status(self) -> list[dict[str, Any]]:
        with self.lock:
            entries = sorted(self.cache.items())
        return [{"kind": kind, "key": key, "principal": principal, "expires": rfc3339(expires),
                 "remainingSeconds": max(0, int((expires - now()).total_seconds()))}
                for (kind, key), (expires, _, principal) in entries]

    def revoke(self) -> int:
        with self.lock:
            count = len(self.cache)
            self.cache.clear()
        self.audit({"source": "credd", "event": "revoke", "count": count})
        return count

    def audit(self, record: dict[str, Any]) -> None:
        if not self.audit_path:
            return
        line = json.dumps({"ts": rfc3339(now()), "environment": self.environment, **record},
                          sort_keys=True, separators=(",", ":"))
        with self.lock, open(self.audit_path, "a", encoding="utf-8") as stream:
            stream.write(line + "\n")

    # -- AWS -----------------------------------------------------------------

    def aws_account(self, account: str) -> dict[str, Any]:
        accounts = self.config.get("aws", {}).get("accounts", {})
        if account not in accounts:
            raise CredentialError(f"unknown AWS account: {account}")
        return accounts[account]

    def mint_aws(self, account: str) -> tuple[dt.datetime, dict[str, Any], str]:
        settings = self.aws_account(account)
        profile = settings["sourceProfile"]
        role = settings.get("roleArn")
        if role:
            argv = ["aws", "sts", "assume-role", "--profile", profile, "--output", "json",
                    "--role-arn", role,
                    "--role-session-name", settings.get("sessionName") or f"infra-agent-{self.environment}",
                    "--duration-seconds", str(int(settings.get("durationSeconds", 3600)))]
            if settings.get("sourceIdentity"):
                argv += ["--source-identity", settings["sourceIdentity"]]
            if settings.get("sessionPolicy"):
                argv += ["--policy", json.dumps(settings["sessionPolicy"], separators=(",", ":"))]
            if settings.get("region"):
                argv += ["--region", settings["region"]]
            output = json.loads(self.run(argv))
            credentials = output["Credentials"]
            principal = output.get("AssumedRoleUser", {}).get("Arn", role)
        else:
            # Without a role the SSO session's own (permission-set) credentials are used.
            credentials = json.loads(self.run(["aws", "configure", "export-credentials",
                                               "--profile", profile, "--format", "process"]))
            principal = f"profile:{profile}"
        try:
            expires = parse_time(credentials["Expiration"])
            value = {"AccessKeyId": credentials["AccessKeyId"],
                     "SecretAccessKey": credentials["SecretAccessKey"],
                     "Token": credentials["SessionToken"],
                     "Expiration": rfc3339(expires)}
        except KeyError as error:
            raise CredentialError(f"AWS credentials for {account} are missing {error}; long-lived keys are refused") from None
        return expires, value, principal

    def aws(self, account: str) -> dict[str, Any]:
        try:
            return self.cached("aws", account, lambda: self.mint_aws(account))
        except CredentialError as error:
            profile = self.aws_account(account)["sourceProfile"]
            raise CredentialError(f"{error} (if the SSO session expired, run on the host: "
                                  f"aws sso login --profile {profile})") from None

    def aws_env(self, account: str) -> dict[str, str]:
        credentials = self.aws(account)
        env = {k: v for k, v in os.environ.items() if not k.startswith("AWS_")}
        env.update(AWS_ACCESS_KEY_ID=credentials["AccessKeyId"],
                   AWS_SECRET_ACCESS_KEY=credentials["SecretAccessKey"],
                   AWS_SESSION_TOKEN=credentials["Token"])
        return env

    # -- Azure ---------------------------------------------------------------

    def mint_azure(self, resource: str, tenant: str | None) -> tuple[dt.datetime, dict[str, Any], str]:
        argv = ["az", "account", "get-access-token", "--output", "json", "--resource", resource]
        if tenant:
            argv += ["--tenant", tenant]
        output = json.loads(self.run(argv))
        token = output.get("accessToken")
        if not token:
            raise CredentialError(f"az returned no token for {resource}")
        expires = parse_time(output.get("expires_on") or output.get("expiresOn"))
        principal = f"tenant:{output.get('tenant', tenant or '?')}"
        return expires, {"accessToken": token, "expires": expires}, principal

    def azure(self, resource: str) -> dict[str, Any]:
        azure = self.config.get("azure")
        if not azure:
            raise CredentialError("Azure is not configured for this environment")
        wanted = normalize_resource(resource)
        allowed = {normalize_resource(r) for r in azure.get("resources", [])}
        if wanted not in allowed:
            raise CredentialError(f"Azure token audience is not allowed: {resource}")
        tenant = azure.get("tenantId")
        try:
            token = self.cached("azure", wanted, lambda: self.mint_azure(wanted, tenant))
        except CredentialError as error:
            raise CredentialError(f"{error} (if the session expired, run on the host: az login"
                                  f"{' --tenant ' + tenant if tenant else ''})") from None
        return {"access_token": token["accessToken"],
                "expires_on": str(int(token["expires"].timestamp())),
                "resource": resource,
                "token_type": "Bearer"}

    # -- Kubernetes ----------------------------------------------------------

    def mint_k8s(self, cluster: str) -> tuple[dt.datetime, dict[str, Any], str]:
        settings = self.config.get("kubernetes", {}).get(cluster)
        if settings is None:
            raise CredentialError(f"unknown Kubernetes cluster: {cluster}")
        provider = settings["provider"]
        if provider == "eks":
            account = settings["account"]
            argv = ["aws", "eks", "get-token", "--output", "json",
                    "--cluster-name", settings["clusterName"], "--region", settings["region"]]
            credential = json.loads(self.run(argv, env=self.aws_env(account)))
            principal = f"aws:{account}"
        elif provider == "aks":
            azure = self.config.get("azure") or {}
            token = self.mint_azure(AKS_SERVER_APP_ID, settings.get("tenantId") or azure.get("tenantId"))
            expires, value, principal = token
            credential = {"status": {"token": value["accessToken"],
                                     "expirationTimestamp": rfc3339(expires)}}
        elif provider == "command":
            credential = json.loads(self.run(settings["command"]))
            principal = "command"
        else:
            raise CredentialError(f"unsupported Kubernetes provider: {provider}")
        status = credential.get("status") or {}
        if not status.get("token") or not status.get("expirationTimestamp"):
            raise CredentialError(f"Kubernetes credential for {cluster} needs a token and an expirationTimestamp")
        expires = parse_time(status["expirationTimestamp"])
        value = {"apiVersion": "client.authentication.k8s.io/v1beta1", "kind": "ExecCredential",
                 "status": {"token": status["token"], "expirationTimestamp": rfc3339(expires)}}
        return expires, value, principal

    def k8s(self, cluster: str) -> dict[str, Any]:
        return self.cached("k8s", cluster, lambda: self.mint_k8s(cluster))

    # -- databases -----------------------------------------------------------

    def db(self, source: str) -> dict[str, Any]:
        settings = self.config.get("databases", {}).get(source)
        if settings is None or not settings.get("passwordCommand"):
            raise CredentialError(f"no password command for database source: {source}")
        password = self.run(settings["passwordCommand"]).rstrip("\n")
        if not password or "\n" in password:
            raise CredentialError(f"password command for {source} must print exactly one line")
        self.audit({"source": "credd", "event": "mint", "kind": "db", "key": source, "principal": settings.get("user", "?")})
        return {"password": password}


def make_handler(credd: Credd, token: str) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        server_version = "infra-credd"
        protocol_version = "HTTP/1.1"

        def log_message(self, format: str, *args: Any) -> None:  # noqa: A002
            sys.stderr.write("infra-credd: " + (format % args) + "\n")

        def address_string(self) -> str:
            return "broker"

        def reply(self, status: int, body: Any) -> None:
            data = json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)

        def authorized(self) -> bool:
            # botocore sends AWS_CONTAINER_AUTHORIZATION_TOKEN verbatim; MSAL sends
            # X-IDENTITY-HEADER; the broker's own helpers use a Bearer token.
            offered = [self.headers.get("X-IDENTITY-HEADER", ""), self.headers.get("Authorization", "")]
            if offered[1].startswith("Bearer "):
                offered.append(offered[1][len("Bearer "):])
            return any(value and hmac.compare_digest(value, token) for value in offered)

        def route(self, method: str) -> None:
            url = urllib.parse.urlsplit(self.path)
            parts = [urllib.parse.unquote(p) for p in url.path.split("/") if p]
            query = urllib.parse.parse_qs(url.query)
            if method == "GET" and parts == ["healthz"]:
                return self.reply(200, {"ok": True})
            if not self.authorized():
                return self.reply(401, {"error": "unauthorized"})
            try:
                if method == "GET" and len(parts) == 2 and parts[0] == "aws":
                    return self.reply(200, credd.aws(parts[1]))
                if method == "GET" and parts in (["azure", "token"], ["msi", "token"]):
                    resource = (query.get("resource") or [""])[0]
                    if not resource:
                        return self.reply(400, {"error": "resource is required"})
                    return self.reply(200, credd.azure(resource))
                if method == "GET" and len(parts) == 2 and parts[0] == "k8s":
                    return self.reply(200, credd.k8s(parts[1]))
                if method == "GET" and len(parts) == 2 and parts[0] == "db":
                    return self.reply(200, credd.db(parts[1]))
                if method == "GET" and parts == ["status"]:
                    return self.reply(200, {"environment": credd.environment, "credentials": credd.status()})
                if method == "POST" and parts == ["revoke"]:
                    return self.reply(200, {"revoked": credd.revoke()})
                if method == "POST" and parts == ["audit"]:
                    length = int(self.headers.get("Content-Length") or 0)
                    if length <= 0 or length > MAX_AUDIT_BYTES:
                        return self.reply(413, {"error": "audit record too large or empty"})
                    record = json.loads(self.rfile.read(length))
                    if not isinstance(record, dict):
                        return self.reply(400, {"error": "audit record must be an object"})
                    record.pop("ts", None)
                    record["source"] = "broker"
                    credd.audit(record)
                    return self.reply(200, {"ok": True})
            except CredentialError as error:
                credd.audit({"source": "credd", "event": "error", "path": url.path, "error": str(error)})
                return self.reply(502, {"error": str(error)})
            except (ValueError, KeyError) as error:
                return self.reply(400, {"error": f"bad request: {error}"})
            return self.reply(404, {"error": "not found"})

        def do_GET(self) -> None:  # noqa: N802
            self.route("GET")

        def do_POST(self) -> None:  # noqa: N802
            self.route("POST")

    return Handler


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


def bind(path: str, credd: Credd, token: str) -> Server:
    """Listen on a socket only the owner can use, in a directory only the owner can enter."""
    if len(token) < 32:
        raise CredentialError("token must contain at least 32 characters")
    directory = os.path.dirname(os.path.abspath(path))
    if os.stat(directory).st_mode & 0o077:
        raise CredentialError(f"{directory} must not be accessible by group or others")
    if os.path.lexists(path):
        os.unlink(path)
    old_umask = os.umask(0o177)
    try:
        return Server(path, make_handler(credd, token))
    finally:
        os.umask(old_umask)


def serve(args: argparse.Namespace) -> int:
    with open(args.config, encoding="utf-8") as stream:
        config = json.load(stream)
    with open(args.token_file, encoding="utf-8") as stream:
        token = stream.read().strip()
    credd = Credd(config, args.audit_log)
    try:
        server = bind(args.socket, credd, token)
    except CredentialError as error:
        print(f"infra-credd: {error}", file=sys.stderr)
        return 1
    credd.audit({"source": "credd", "event": "start", "pid": os.getpid()})
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        credd.audit({"source": "credd", "event": "stop"})
        server.server_close()
        if os.path.lexists(args.socket):
            os.unlink(args.socket)
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="infra-credd", description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    serve_parser = sub.add_parser("serve", help="serve credentials on a Unix socket")
    serve_parser.add_argument("--config", required=True)
    serve_parser.add_argument("--socket", required=True)
    serve_parser.add_argument("--token-file", required=True)
    serve_parser.add_argument("--audit-log")
    args = parser.parse_args(argv)
    if args.command == "serve":
        return serve(args)
    return 2


if __name__ == "__main__":
    sys.exit(main())
