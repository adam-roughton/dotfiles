"""Tests for infra-broker-credential against a fake credd."""

import json
import os
import subprocess
import sys
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer

SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src")
TOKEN = "c" * 40


class FakeCredd(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.headers.get("Authorization") != f"Bearer {TOKEN}":
            return self.respond(401, {"error": "unauthorized"})
        if self.path == "/k8s/payments":
            return self.respond(200, {"apiVersion": "client.authentication.k8s.io/v1beta1", "kind": "ExecCredential",
                                      "status": {"token": "tok", "expirationTimestamp": "2030-01-01T00:00:00Z"}})
        if self.path == "/aws/prod":
            return self.respond(200, {"AccessKeyId": "ASIA", "SecretAccessKey": "s", "Token": "t",
                                      "Expiration": "2030-01-01T00:00:00Z"})
        if self.path == "/db/orders":
            return self.respond(200, {"password": "hunter2"})
        return self.respond(502, {"error": "no such credential"})

    def respond(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


class CredentialTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = HTTPServer(("127.0.0.1", 0), FakeCredd)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def run_helper(self, *args, token=TOKEN):
        env = {**os.environ, "PYTHONPATH": SRC, "INFRA_CREDD_URL": f"http://127.0.0.1:{self.server.server_port}",
               "INFRA_CREDD_TOKEN": token}
        return subprocess.run([sys.executable, "-m", "infra_broker.credential", *args], env=env,
                              capture_output=True, text=True, timeout=60)

    def test_k8s_exec_credential(self):
        result = self.run_helper("k8s", "payments")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["status"]["token"], "tok")

    def test_k8s_failure_is_reported(self):
        result = self.run_helper("k8s", "unknown")
        self.assertEqual(result.returncode, 1)
        self.assertIn("no such credential", result.stderr)
        result = self.run_helper("k8s", "payments", token="wrong")
        self.assertEqual(result.returncode, 1)

    def test_aws_credential_process(self):
        result = self.run_helper("aws-process", "prod")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"Version": 1, "AccessKeyId": "ASIA", "SecretAccessKey": "s",
                                                     "SessionToken": "t", "Expiration": "2030-01-01T00:00:00Z"})

    def test_exec_with_db_passwords(self):
        result = self.run_helper("exec-with-db-passwords", "orders=INFRA_DB_ORDERS_PASSWORD", "--",
                                 sys.executable, "-c", "import os; print(os.environ['INFRA_DB_ORDERS_PASSWORD'])")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "hunter2")

    def test_exec_with_db_passwords_rejects_bad_mapping(self):
        result = self.run_helper("exec-with-db-passwords", "orders=lower", "--", "true")
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
