"""infra-aws-mcp: read-only AWS API access for the infra broker.

A small, auditable alternative to the awslabs servers (whose current releases pin
awscli and mcp versions that conflict with nixpkgs, and whose read-only mode
still allows reading secret values). Every call is checked against:

* the configured services (each maps to network rules on the broker),
* read-only operation prefixes (Describe/List/Get/...),
* a denylist of read operations that return secrets or signed URLs,

and responses have environment-variable values redacted. IAM on the role that
infra-credd assumes is the real boundary; these checks are defence in depth.

Credentials for each account come from infra-credd (container-credentials
protocol), so they refresh without restarting anything.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import sys
import time
from typing import Any

import boto3
import botocore.exceptions
import botocore.session
from botocore.config import Config
from botocore.credentials import ContainerProvider, CredentialResolver
from fastmcp import FastMCP
from fastmcp.exceptions import ToolError

from . import credd_client

READ_PREFIXES = ("Describe", "List", "Get", "Search", "Lookup", "BatchGet", "Filter")
# Read operations that return secret material, credentials or presigned URLs.
DEFAULT_DENY = (
    "secretsmanager:GetSecretValue", "secretsmanager:BatchGetSecretValue", "secretsmanager:GetRandomPassword",
    "ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath", "ssm:GetParameterHistory",
    "lambda:GetFunction", "ec2:GetPasswordData", "ec2:GetConsoleOutput", "ec2:GetConsoleScreenshot",
    "ec2:GetLaunchTemplateData", "ecr:GetAuthorizationToken", "ecr:GetDownloadUrlForLayer",
    "s3:GetObject", "s3:GetObjectTorrent", "sts:GetSessionToken", "sts:GetFederationToken",
    "rds:DownloadDBLogFilePortion", "cognito-idp:*", "cognito-identity:*", "kms:*", "iam:GetCredentialReport",
)
SECRET_KEY = re.compile(r"(password|passwd|secret|token|apikey|api_key|private_?key|credential)", re.IGNORECASE)
REDACTED = "[redacted by infra broker]"


def redact(value: Any, redact_environment: bool = True) -> Any:
    """Mask environment-variable values and secret-looking fields in API responses."""
    if isinstance(value, dict):
        result = {}
        for key, item in value.items():
            if redact_environment and key == "Variables" and isinstance(item, dict):
                result[key] = {name: REDACTED for name in item}
            elif (redact_environment and key.lower() == "environment" and isinstance(item, list)
                  and all(isinstance(e, dict) and "name" in e for e in item)):
                result[key] = [{**e, "value": REDACTED} if "value" in e else e for e in item]
            elif SECRET_KEY.search(key) and isinstance(item, str) and item:
                result[key] = REDACTED
            else:
                result[key] = redact(item, redact_environment)
        return result
    if isinstance(value, list):
        return [redact(item, redact_environment) for item in value]
    return value


def denied(service: str, operation: str, deny: list[str]) -> bool:
    for rule in deny:
        rule_service, _, rule_operation = rule.partition(":")
        if rule_service == service and rule_operation in ("*", operation):
            return True
    return False


def parse_time(value: str | int | float | None, default: dt.datetime) -> dt.datetime:
    if value is None or value == "":
        return default
    if isinstance(value, (int, float)) or (isinstance(value, str) and re.fullmatch(r"\d+", value)):
        return dt.datetime.fromtimestamp(int(value), dt.timezone.utc)
    match = re.fullmatch(r"-(\d+)([smhd])", str(value))
    if match:
        unit = {"s": "seconds", "m": "minutes", "h": "hours", "d": "days"}[match.group(2)]
        return dt.datetime.now(dt.timezone.utc) - dt.timedelta(**{unit: int(match.group(1))})
    parsed = dt.datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=dt.timezone.utc)


class Aws:
    def __init__(self, config: dict[str, Any]):
        self.config = config
        self.accounts: dict[str, dict[str, Any]] = config["accounts"]
        self.default_account = config.get("defaultAccount") or next(iter(self.accounts))
        self.services = set(config.get("services", []))
        self.deny = list(config.get("denyOperations", DEFAULT_DENY))
        self.max_bytes = int(config.get("maxResultBytes", 150_000))
        self.redact_environment = bool(config.get("redactEnvironment", True))
        self.sessions: dict[str, boto3.Session] = {}

    def account(self, name: str | None) -> tuple[str, dict[str, Any]]:
        name = name or self.default_account
        if name not in self.accounts:
            raise ToolError(f"unknown account {name!r}; configured accounts: {', '.join(sorted(self.accounts))}")
        return name, self.accounts[name]

    def region(self, settings: dict[str, Any], region: str | None) -> str:
        regions = settings.get("regions") or []
        region = region or (regions[0] if regions else None)
        if not region or region not in regions:
            raise ToolError(f"region {region!r} is not configured for this account; use one of: {', '.join(regions)}")
        return region

    def session(self, account: str) -> boto3.Session:
        if account not in self.sessions:
            core = botocore.session.Session()
            provider = ContainerProvider(environ={
                "AWS_CONTAINER_CREDENTIALS_FULL_URI": f"{credd_client.base_url()}/aws/{account}",
                "AWS_CONTAINER_AUTHORIZATION_TOKEN": credd_client.token(),
            })
            core.register_component("credential_provider", CredentialResolver(providers=[provider]))
            self.sessions[account] = boto3.Session(botocore_session=core)
        return self.sessions[account]

    def client(self, service: str, account: str | None, region: str | None) -> Any:
        if service not in self.services:
            raise ToolError(f"service {service!r} is not enabled; enabled services: {', '.join(sorted(self.services))}")
        name, settings = self.account(account)
        config = Config(retries={"max_attempts": 4, "mode": "standard"}, connect_timeout=10, read_timeout=60,
                        user_agent_extra="infra-agent-broker")
        return self.session(name).client(service, region_name=self.region(settings, region), config=config)

    def render(self, value: Any) -> str:
        text = json.dumps(redact(value, self.redact_environment), default=str, indent=1, sort_keys=True)
        if len(text) > self.max_bytes:
            text = text[: self.max_bytes] + "\n[truncated: narrow the request with filters or MaxResults]"
        return text

    def read(self, service: str, operation: str, parameters: dict[str, Any] | None, account: str | None,
             region: str | None, paginate: bool, max_items: int) -> str:
        client = self.client(service, account, region)
        api_names = {snake: api for snake, api in client.meta.method_to_api_mapping.items()}
        operation_name = api_names.get(operation, operation)
        if operation_name not in api_names.values():
            raise ToolError(f"{service} has no operation {operation!r}")
        if not operation_name.startswith(READ_PREFIXES):
            raise ToolError(f"{service}:{operation_name} is not a read operation; only {', '.join(READ_PREFIXES)} are allowed")
        if denied(service, operation_name, self.deny):
            raise ToolError(f"{service}:{operation_name} is denied by the broker policy (it can return secrets or signed URLs)")
        method = next(snake for snake, api in api_names.items() if api == operation_name)
        parameters = parameters or {}
        try:
            if paginate and client.can_paginate(method):
                paginator = client.get_paginator(method)
                result = paginator.paginate(**parameters, PaginationConfig={"MaxItems": max_items}).build_full_result()
            else:
                result = getattr(client, method)(**parameters)
        except client.exceptions.ClientError as error:
            raise ToolError(f"{service}:{operation_name} failed: {error}") from None
        except botocore.exceptions.ParamValidationError as error:
            raise ToolError(str(error)) from None
        if isinstance(result, dict):
            result.pop("ResponseMetadata", None)
        return self.render(result)


def create_server(aws: Aws) -> FastMCP:
    server = FastMCP("infra-aws", instructions=(
        "Read-only AWS API access. Call accounts first to see accounts, regions and services."))

    @server.tool
    def accounts() -> str:
        """List the configured AWS accounts, their regions and the enabled services."""
        return json.dumps({"defaultAccount": aws.default_account, "services": sorted(aws.services),
                           "accounts": {name: {"regions": s.get("regions", []), "description": s.get("description", "")}
                                        for name, s in aws.accounts.items()}}, indent=1)

    @server.tool
    def whoami(account: str | None = None) -> str:
        """Show the IAM identity the broker uses for an account (sts:GetCallerIdentity)."""
        name, settings = aws.account(account)
        client = aws.session(name).client("sts", region_name=aws.region(settings, None))
        identity = client.get_caller_identity()
        identity.pop("ResponseMetadata", None)
        return json.dumps(identity)

    @server.tool
    def read(service: str, operation: str, parameters: dict[str, Any] | None = None, account: str | None = None,
                 region: str | None = None, paginate: bool = False, max_items: int = 200) -> str:
        """Call a read-only AWS API operation.

        service: boto3 service name (e.g. ec2, ecs, eks, rds, elbv2, cloudwatch, logs).
        operation: API name (DescribeInstances) or boto3 method (describe_instances).
        parameters: API request parameters, e.g. {"Filters": [{"Name": "tag:app", "Values": ["api"]}]}.
        paginate: follow pagination tokens up to max_items results.
        """
        return aws.read(service, operation, parameters, account, region, paginate, max(1, min(max_items, 1000)))

    @server.tool
    def logs_insights(log_group_names: list[str], query: str, start: str = "-1h", end: str | None = None,
                          limit: int = 100, account: str | None = None, region: str | None = None) -> str:
        """Run a CloudWatch Logs Insights query and wait (up to 60s) for the results.

        start/end: ISO 8601 times, epoch seconds, or relative times like -15m, -2h, -1d (end defaults to now).
        """
        client = aws.client("logs", account, region)
        now = dt.datetime.now(dt.timezone.utc)
        query_id = client.start_query(
            logGroupNames=log_group_names, queryString=query, limit=max(1, min(limit, 10_000)),
            startTime=int(parse_time(start, now - dt.timedelta(hours=1)).timestamp()),
            endTime=int(parse_time(end, now).timestamp()))["queryId"]
        deadline = time.monotonic() + 60
        while True:
            response = client.get_query_results(queryId=query_id)
            if response["status"] in ("Complete", "Failed", "Cancelled", "Timeout", "Unknown"):
                break
            if time.monotonic() > deadline:
                return aws.render({"status": response["status"], "queryId": query_id,
                                   "note": "still running; call read with service logs, operation GetQueryResults and this queryId"})
            time.sleep(1)
        rows = [{field["field"]: field["value"] for field in row} for row in response.get("results", [])]
        return aws.render({"status": response["status"], "statistics": response.get("statistics"), "results": rows})

    return server


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="infra-aws-mcp", description=__doc__.splitlines()[0])
    parser.add_argument("--config", required=True)
    args = parser.parse_args(argv)
    with open(args.config, encoding="utf-8") as stream:
        config = json.load(stream)
    os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
    create_server(Aws(config)).run(show_banner=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
