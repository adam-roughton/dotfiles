"""infra-broker-credential: credential helpers for MCP servers in the broker.

  k8s CLUSTER
      kubeconfig exec plugin: prints an ExecCredential minted by infra-credd.
  aws-process ACCOUNT
      AWS credential_process: prints the account's credentials from infra-credd
      (used by AWS config profiles, e.g. DBHub's aws_profile for RDS IAM auth).
  exec-with-db-passwords SOURCE=VAR... -- COMMAND [ARG...]
      Fetch database passwords from infra-credd into environment variables,
      then exec COMMAND (DBHub reads ${VAR} references from its TOML config).
  doctor [--config FILE]
      Check credd, credentials and network reachability from inside the broker.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import socket
import sys
import urllib.parse
from typing import Any

from . import credd_client

ENV_NAME = re.compile(r"^[A-Z_][A-Z0-9_]*$")


def k8s(cluster: str) -> int:
    credential = credd_client.get(f"/k8s/{urllib.parse.quote(cluster, safe='')}")
    json.dump(credential, sys.stdout)
    sys.stdout.write("\n")
    return 0


def aws_process(account: str) -> int:
    credentials = credd_client.get(f"/aws/{urllib.parse.quote(account, safe='')}")
    json.dump({"Version": 1, "AccessKeyId": credentials["AccessKeyId"],
               "SecretAccessKey": credentials["SecretAccessKey"], "SessionToken": credentials["Token"],
               "Expiration": credentials["Expiration"]}, sys.stdout)
    sys.stdout.write("\n")
    return 0


def exec_with_db_passwords(mappings: list[str], command: list[str]) -> int:
    if not command:
        raise SystemExit("exec-with-db-passwords: missing command after --")
    env = dict(os.environ)
    for mapping in mappings:
        source, _, variable = mapping.partition("=")
        if not source or not ENV_NAME.match(variable):
            raise SystemExit(f"exec-with-db-passwords: expected SOURCE=VARIABLE, got {mapping!r}")
        env[variable] = credd_client.get(f"/db/{urllib.parse.quote(source, safe='')}")["password"]
    os.execvpe(command[0], command, env)
    return 1  # unreachable


def tcp_check(host: str, port: int, timeout: float = 5) -> str:
    try:
        addresses = sorted({info[4][0] for info in socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)})
    except OSError as error:
        return f"DNS failed: {error}"
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return f"ok ({', '.join(addresses)})"
    except OSError as error:
        return f"connect failed ({', '.join(addresses)}): {error}"


def doctor(config_path: str) -> int:
    with open(config_path, encoding="utf-8") as stream:
        config: dict[str, Any] = json.load(stream)
    failures = 0

    def report(name: str, outcome: str, ok: bool) -> None:
        nonlocal failures
        failures += 0 if ok else 1
        print(f"{'ok  ' if ok else 'FAIL'} {name}: {outcome}")

    try:
        credd_client.get("/status", timeout=10)
        report("credd", "reachable", True)
    except credd_client.CreddError as error:
        report("credd", str(error), False)
        return 1
    for account in config.get("awsAccounts", []):
        try:
            credentials = credd_client.get(f"/aws/{account}")
            report(f"aws {account}", f"credentials until {credentials['Expiration']}", True)
        except credd_client.CreddError as error:
            report(f"aws {account}", str(error), False)
    for resource in config.get("azureResources", [])[:1]:
        try:
            credd_client.get(f"/msi/token?resource={urllib.parse.quote(resource, safe='')}")
            report("azure", f"token for {resource}", True)
        except credd_client.CreddError as error:
            report("azure", str(error), False)
    for cluster in config.get("kubernetesClusters", []):
        try:
            credential = credd_client.get(f"/k8s/{cluster}")
            report(f"k8s {cluster} credential", f"until {credential['status']['expirationTimestamp']}", True)
        except credd_client.CreddError as error:
            report(f"k8s {cluster} credential", str(error), False)
    for target in config.get("targets", []):
        outcome = tcp_check(target["host"], int(target["port"]))
        report(f"reach {target['name']} {target['host']}:{target['port']}", outcome, outcome.startswith("ok"))
    return 1 if failures else 0


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    if argv and argv[0] == "exec-with-db-passwords":
        rest = argv[1:]
        if "--" not in rest:
            raise SystemExit("exec-with-db-passwords: use SOURCE=VAR... -- COMMAND")
        split = rest.index("--")
        return exec_with_db_passwords(rest[:split], rest[split + 1:])
    parser = argparse.ArgumentParser(prog="infra-broker-credential", description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    k8s_parser = sub.add_parser("k8s")
    k8s_parser.add_argument("cluster")
    aws_parser = sub.add_parser("aws-process")
    aws_parser.add_argument("account")
    doctor_parser = sub.add_parser("doctor")
    doctor_parser.add_argument("--config", default="/etc/infra-broker/doctor.json")
    args = parser.parse_args(argv)
    try:
        if args.command == "k8s":
            return k8s(args.cluster)
        if args.command == "aws-process":
            return aws_process(args.account)
        return doctor(args.config)
    except credd_client.CreddError as error:
        print(f"infra-broker-credential: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
