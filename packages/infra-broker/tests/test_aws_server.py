"""Tests for the read-only AWS MCP server (no network: botocore Stubber)."""

import json
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

import boto3  # noqa: E402
from botocore.stub import Stubber  # noqa: E402
from fastmcp.exceptions import ToolError  # noqa: E402

from infra_broker import aws_server  # noqa: E402

CONFIG = {
    "accounts": {"prod": {"regions": ["eu-west-1", "us-east-1"]}, "shared": {"regions": ["eu-west-1"]}},
    "services": ["ec2", "lambda", "ecs", "logs"],
}


class StubbedAws(aws_server.Aws):
    def __init__(self, config):
        super().__init__(config)
        self.stubs = {}
        self.requested = []

    def client(self, service, account, region):
        if service not in self.services:
            raise ToolError("service not enabled")
        name, settings = self.account(account)
        region = self.region(settings, region)
        self.requested.append((service, name, region))
        if service not in self.stubs:
            client = boto3.client(service, region_name=region, aws_access_key_id="a", aws_secret_access_key="b")
            self.stubs[service] = (client, Stubber(client))
            self.stubs[service][1].activate()
        return self.stubs[service][0]


class AwsTest(unittest.TestCase):
    def setUp(self):
        self.aws = StubbedAws(CONFIG)

    def stub(self, service):
        self.aws.client(service, None, None)
        self.aws.requested.clear()
        return self.aws.stubs[service][1]

    def test_read_operation(self):
        self.stub("ec2").add_response("describe_instances", {"Reservations": []}, {"MaxResults": 5})
        text = self.aws.read("ec2", "DescribeInstances", {"MaxResults": 5}, None, None, False, 10)
        self.assertEqual(json.loads(text), {"Reservations": []})
        self.assertEqual(self.aws.requested, [("ec2", "prod", "eu-west-1")])

    def test_snake_case_operation_and_account(self):
        self.stub("ec2").add_response("describe_vpcs", {"Vpcs": []}, {})
        self.aws.read("ec2", "describe_vpcs", None, "shared", "eu-west-1", False, 10)
        self.assertEqual(self.aws.requested, [("ec2", "shared", "eu-west-1")])

    def test_rejects_writes(self):
        for operation in ("TerminateInstances", "terminate_instances", "RunInstances"):
            with self.assertRaises(ToolError):
                self.aws.read("ec2", operation, {}, None, None, False, 10)

    def test_rejects_denied_reads(self):
        with self.assertRaises(ToolError) as caught:
            self.aws.read("lambda", "GetFunction", {"FunctionName": "x"}, None, None, False, 10)
        self.assertIn("denied", str(caught.exception))
        with self.assertRaises(ToolError):
            self.aws.read("ec2", "GetPasswordData", {"InstanceId": "i-1"}, None, None, False, 10)

    def test_rejects_unconfigured_service_account_and_region(self):
        with self.assertRaises(ToolError):
            self.aws.read("secretsmanager", "ListSecrets", {}, None, None, False, 10)
        with self.assertRaises(ToolError):
            self.aws.read("ec2", "DescribeVpcs", {}, "other", None, False, 10)
        with self.assertRaises(ToolError):
            self.aws.read("ec2", "DescribeVpcs", {}, "shared", "us-east-1", False, 10)

    def test_redacts_environment(self):
        self.stub("lambda").add_response("get_function_configuration", {
            "FunctionName": "api", "Environment": {"Variables": {"DB_URL": "postgres://u:p@h/db"}}},
            {"FunctionName": "api"})
        text = self.aws.read("lambda", "GetFunctionConfiguration", {"FunctionName": "api"}, None, None, False, 10)
        self.assertNotIn("postgres://", text)
        self.assertIn("DB_URL", text)

    def test_redact_helper(self):
        value = {"containerDefinitions": [{"name": "app", "environment": [{"name": "TOKEN", "value": "abc"}],
                                           "secrets": [{"name": "X", "valueFrom": "arn:secret"}]}],
                 "MasterUserPassword": "p", "Nested": {"apiKey": "k", "Count": 3}}
        redacted = aws_server.redact(value)
        self.assertEqual(redacted["containerDefinitions"][0]["environment"][0]["value"], aws_server.REDACTED)
        self.assertEqual(redacted["MasterUserPassword"], aws_server.REDACTED)
        self.assertEqual(redacted["Nested"], {"apiKey": aws_server.REDACTED, "Count": 3})
        self.assertEqual(redacted["containerDefinitions"][0]["secrets"][0]["valueFrom"], "arn:secret")

    def test_truncates(self):
        self.aws.max_bytes = 100
        self.stub("ec2").add_response("describe_vpcs", {"Vpcs": [{"VpcId": f"vpc-{i:08d}"} for i in range(50)]}, {})
        text = self.aws.read("ec2", "DescribeVpcs", {}, None, None, False, 10)
        self.assertIn("[truncated", text)

    def test_parse_time(self):
        default = aws_server.dt.datetime(2026, 1, 1, tzinfo=aws_server.dt.timezone.utc)
        self.assertEqual(aws_server.parse_time(None, default), default)
        self.assertEqual(aws_server.parse_time("1767225600", default), default)
        self.assertEqual(aws_server.parse_time("2026-01-01T00:00:00Z", default), default)
        self.assertLess(aws_server.parse_time("-2h", default), aws_server.dt.datetime.now(aws_server.dt.timezone.utc))


class ToolNamesTest(unittest.TestCase):
    def test_names_match_the_gateway_allowlist(self):
        # modules/infra-agent/environment.nix allows exactly these names for the aws source.
        import asyncio
        server = aws_server.create_server(aws_server.Aws(CONFIG))
        tools = asyncio.run(server.list_tools())
        self.assertEqual(sorted(tool.name for tool in tools), ["accounts", "logs_insights", "read", "whoami"])


class CreddCredentialsTest(unittest.TestCase):
    def test_session_reads_account_credentials_from_credd(self):
        import datetime as dt
        import threading
        from http.server import BaseHTTPRequestHandler, HTTPServer

        seen = []
        expiration = (dt.datetime.now(dt.timezone.utc) + dt.timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ")

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                seen.append((self.path, self.headers.get("Authorization")))
                body = json.dumps({"AccessKeyId": "ASIA" + self.path.rsplit("/", 1)[-1], "SecretAccessKey": "s",
                                   "Token": "t", "Expiration": expiration}).encode()
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass

        server = HTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        old = dict(os.environ)
        os.environ.update(INFRA_CREDD_URL=f"http://127.0.0.1:{server.server_port}", INFRA_CREDD_TOKEN="x" * 40)
        try:
            aws = aws_server.Aws(CONFIG)
            credentials = aws.session("shared").get_credentials().get_frozen_credentials()
        finally:
            os.environ.clear()
            os.environ.update(old)
            server.shutdown()
            server.server_close()
        self.assertEqual(credentials.access_key, "ASIAshared")
        self.assertEqual(seen, [("/aws/shared", "x" * 40)])


if __name__ == "__main__":
    unittest.main()
