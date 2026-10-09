"""Gateway tests: run with python3 -m unittest discover -s packages/infra-broker/tests"""

import asyncio
import json
import logging
import os
import socket
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

from fastmcp import Client  # noqa: E402
from fastmcp.client.transports import StreamableHttpTransport  # noqa: E402
from fastmcp.exceptions import ToolError  # noqa: E402

from infra_broker import gateway  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
# Cancelling the test server makes uvicorn log the lifespan's CancelledError.
logging.getLogger("uvicorn.error").setLevel(logging.CRITICAL)
TOKEN = "a" * 48


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class PolicyTest(unittest.TestCase):
    def test_deny_by_default(self):
        policy = gateway.ToolPolicy({"k8s": {"allowTools": ["pods_*"], "denyTools": ["pods_delete"]},
                                     "db": {"allowTools": ["execute_sql_*"]}},
                                    deny=["*secret*"])
        self.assertTrue(policy.allowed("k8s_pods_list"))
        self.assertFalse(policy.allowed("k8s_pods_delete"))
        self.assertFalse(policy.allowed("k8s_nodes_list"))
        self.assertFalse(policy.allowed("k8s_pods_secret"))
        self.assertFalse(policy.allowed("other_pods_list"))
        self.assertFalse(policy.allowed("pods"))
        self.assertTrue(policy.allowed("db_execute_sql_orders"))

    def test_expand_env(self):
        self.assertEqual(gateway.expand_env("Bearer {env:X}", {"X": "$MSB_X"}), "Bearer $MSB_X")
        with self.assertRaises(ValueError):
            gateway.expand_env("{env:MISSING}", {})

    def test_server_names(self):
        with self.assertRaises(ValueError):
            gateway.build({"tokensDirectory": "/nonexistent", "servers": {"bad_name": {"command": "true"}}})

    def test_stdio_environment(self):
        os.environ["INFRA_TEST_SECRET_PLACEHOLDER"] = "$MSB_X"
        os.environ["UNRELATED_HOST_VARIABLE"] = "leak"
        try:
            client = gateway.upstream_client(
                "db", {"command": "dbhub", "env": {"A": "{env:INFRA_TEST_SECRET_PLACEHOLDER}"}}, None,
                {"KUBECONFIG": "/etc/infra-broker/kubeconfig.json"})
        finally:
            del os.environ["INFRA_TEST_SECRET_PLACEHOLDER"]
            del os.environ["UNRELATED_HOST_VARIABLE"]
        env = client.transport.env
        self.assertEqual(env["A"], "$MSB_X")
        self.assertEqual(env["KUBECONFIG"], "/etc/infra-broker/kubeconfig.json")
        self.assertNotIn("UNRELATED_HOST_VARIABLE", env)

    def test_remote_headers(self):
        os.environ["INFRA_DD_API_KEY"] = "$MSB_INFRA_DD_API_KEY"
        try:
            client = gateway.upstream_client(
                "datadog", {"url": "https://mcp.datadoghq.eu/v1/mcp", "headers": {"DD_API_KEY": "{env:INFRA_DD_API_KEY}"}}, None)
        finally:
            del os.environ["INFRA_DD_API_KEY"]
        self.assertEqual(client.transport.headers["DD_API_KEY"], "$MSB_INFRA_DD_API_KEY")
        gateway.Upstream("datadog", client)
        self.assertFalse(client.transport.forward_incoming_headers)


class GatewayTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.tokens = os.path.join(self.dir.name, "tokens")
        os.mkdir(self.tokens)
        with open(os.path.join(self.tokens, "inc_123"), "w") as stream:
            stream.write(TOKEN + "\n")
        self.marker = os.path.join(self.dir.name, "deleted")
        self.audit = []
        self.port = free_port()
        self.config = {
            "environment": "test",
            "tokensDirectory": self.tokens,
            "maxResponseBytes": 10_000,
            "denyTools": ["*_env"],
            "env": {"FAKE_COMMON": "common"},
            "listen": {"host": "127.0.0.1", "port": self.port},
            "servers": {"fake": {"command": sys.executable, "args": [os.path.join(HERE, "fake_upstream.py")],
                                 # Upstreams only inherit an allowlist of variables; the
                                 # fake server needs this interpreter's module path.
                                 "env": {"FAKE_UPSTREAM_MARKER": self.marker, "PYTHONPATH": os.pathsep.join(sys.path)},
                                 "allowTools": ["pods_list", "big", "env", "pid", "crash"]}},
        }

    def tearDown(self):
        self.dir.cleanup()

    def run_with_gateway(self, body, send_audit=None):
        async def scenario():
            app, upstreams = gateway.build(self.config, send_audit=send_audit or self.audit.append)
            task = asyncio.create_task(app.run_http_async(
                transport="http", host="127.0.0.1", port=self.port, path="/mcp", show_banner=False,
                host_origin_protection=True, allowed_hosts=["127.0.0.1"]))
            try:
                for _ in range(100):
                    try:
                        _, writer = await asyncio.open_connection("127.0.0.1", self.port)
                        writer.close()
                        break
                    except OSError:
                        await asyncio.sleep(0.05)
                return await body(f"http://127.0.0.1:{self.port}/mcp")
            finally:
                task.cancel()
                for upstream in upstreams.values():
                    await upstream.close()

        return asyncio.run(scenario())

    @staticmethod
    def client(url, token=TOKEN):
        return Client(StreamableHttpTransport(url, headers={"Authorization": f"Bearer {token}"}))

    def test_lists_only_allowed_tools(self):
        async def body(url):
            async with self.client(url) as client:
                return sorted(tool.name for tool in await client.list_tools())

        self.assertEqual(self.run_with_gateway(body), ["fake_big", "fake_crash", "fake_pid", "fake_pods_list"])

    def test_blocks_disallowed_calls(self):
        async def body(url):
            async with self.client(url) as client:
                with self.assertRaises(ToolError):
                    await client.call_tool("fake_pods_delete", {"name": "api-1"})
                with self.assertRaises(ToolError):
                    await client.call_tool("fake_env", {"name": "PATH"})

        self.run_with_gateway(body)
        self.assertFalse(os.path.exists(self.marker))
        self.assertEqual(self.audit, [])

    def test_audits_calls(self):
        async def body(url):
            async with self.client(url) as client:
                result = await client.call_tool("fake_pods_list", {"namespace": "payments"})
                return json.loads(result.content[0].text)

        self.assertEqual(self.run_with_gateway(body)["namespace"], "payments")
        self.assertEqual([r["event"] for r in self.audit], ["call", "result"])
        call, result = self.audit
        self.assertEqual(call["incident"], "inc_123")
        self.assertEqual(call["tool"], "fake_pods_list")
        self.assertEqual(call["arguments"], {"namespace": "payments"})
        self.assertEqual(call["environment"], "test")
        self.assertEqual(len(result["sha256"]), 64)
        self.assertNotIn("api-1", json.dumps(self.audit))

    def test_one_upstream_process_and_recovery(self):
        async def body(url):
            pids = []
            for _ in range(3):
                async with self.client(url) as client:
                    pids.append((await client.call_tool("fake_pid", {})).content[0].text)
            async with self.client(url) as client:
                with self.assertRaises(Exception):
                    await client.call_tool("fake_crash", {})
            await asyncio.sleep(0.5)
            async with self.client(url) as client:
                pids.append((await client.call_tool("fake_pid", {})).content[0].text)
            return pids

        pids = self.run_with_gateway(body)
        self.assertEqual(len(set(pids[:3])), 1, pids)
        self.assertNotEqual(pids[3], pids[0])

    def test_audit_failure_blocks_call(self):
        def failing(record):
            raise OSError("credd down")

        async def body(url):
            async with self.client(url) as client:
                with self.assertRaises(ToolError):
                    await client.call_tool("fake_pods_list", {})

        self.run_with_gateway(body, send_audit=failing)

    def test_truncates_large_results(self):
        async def body(url):
            async with self.client(url) as client:
                result = await client.call_tool("fake_big", {})
                return result.content[0].text

        text = self.run_with_gateway(body)
        self.assertLess(len(text), 11_000)
        self.assertIn("truncated", text)

    def test_rejects_unknown_tokens(self):
        async def body(url):
            for token in ("b" * 48, "short"):
                with self.assertRaises(Exception):
                    async with self.client(url, token) as client:
                        await client.list_tools()

        self.run_with_gateway(body)

    def test_revoked_token(self):
        async def body(url):
            async with self.client(url) as client:
                await client.list_tools()
            os.unlink(os.path.join(self.tokens, "inc_123"))
            with self.assertRaises(Exception):
                async with self.client(url) as client:
                    await client.list_tools()

        self.run_with_gateway(body)


if __name__ == "__main__":
    unittest.main()
