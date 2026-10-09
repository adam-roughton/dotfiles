"""Tests for infra-credd. Run: python3 -m unittest discover -s modules/infra-agent/tests -p 'test_*.py'"""

import datetime as dt
import http.client
import json
import os
import socket
import sys
import tempfile
import threading
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "credd"))
import infra_credd  # noqa: E402

UTC = dt.timezone.utc
TOKEN = "t" * 40


def later(minutes):
    return (dt.datetime.now(UTC) + dt.timedelta(minutes=minutes)).strftime("%Y-%m-%dT%H:%M:%SZ")


class FakeRunner:
    def __init__(self):
        self.calls = []
        self.responses = {}

    def __call__(self, argv, env=None):
        self.calls.append((argv, env))
        key = argv if isinstance(argv, str) else " ".join(argv[:3])
        response = self.responses[key]
        if isinstance(response, Exception):
            raise response
        return response(argv, env) if callable(response) else response


CONFIG = {
    "environment": "prod",
    "refreshMarginSeconds": 300,
    "aws": {"accounts": {
        "main": {"sourceProfile": "sso-prod", "roleArn": "arn:aws:iam::1:role/infra-agent-readonly",
                 "sourceIdentity": "adamr-infra-agent", "durationSeconds": 3600,
                 "sessionPolicy": {"Version": "2012-10-17", "Statement": []}},
        "sso": {"sourceProfile": "sso-only"},
    }},
    "azure": {"tenantId": "tenant-1", "resources": ["https://management.azure.com/", "https://api.loganalytics.io"]},
    "kubernetes": {
        "payments": {"provider": "eks", "account": "main", "clusterName": "payments", "region": "eu-west-1"},
        "orders": {"provider": "aks"},
    },
    "databases": {"orders": {"passwordCommand": "pass show db/orders", "user": "infra_agent_ro"}},
}


def assume_role_output(minutes=60):
    return json.dumps({"Credentials": {"AccessKeyId": "ASIA1", "SecretAccessKey": "secret", "SessionToken": "session",
                                       "Expiration": later(minutes)},
                       "AssumedRoleUser": {"Arn": "arn:aws:sts::1:assumed-role/infra-agent-readonly/x"}})


class CreddTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.audit = os.path.join(self.dir.name, "audit.jsonl")
        self.run = FakeRunner()
        self.credd = infra_credd.Credd(CONFIG, self.audit, run=self.run)

    def tearDown(self):
        self.dir.cleanup()

    def audit_records(self):
        with open(self.audit) as stream:
            return [json.loads(line) for line in stream]

    def test_aws_assume_role_and_cache(self):
        self.run.responses["aws sts assume-role"] = assume_role_output()
        first = self.credd.aws("main")
        second = self.credd.aws("main")
        self.assertEqual(first, second)
        self.assertEqual(len(self.run.calls), 1)
        self.assertEqual(set(first), {"AccessKeyId", "SecretAccessKey", "Token", "Expiration"})
        self.assertTrue(first["Expiration"].endswith("Z"))
        argv = self.run.calls[0][0]
        self.assertIn("--source-identity", argv)
        self.assertIn("adamr-infra-agent", argv)
        self.assertEqual(json.loads(argv[argv.index("--policy") + 1]), CONFIG["aws"]["accounts"]["main"]["sessionPolicy"])
        record = self.audit_records()[0]
        self.assertEqual(record["kind"], "aws")
        self.assertNotIn("secret", json.dumps(record))

    def test_aws_refreshes_near_expiry(self):
        self.run.responses["aws sts assume-role"] = assume_role_output(10)
        self.credd.aws("main")
        self.credd.aws("main")
        self.assertEqual(len(self.run.calls), 1)
        # Inside the 5-minute refresh margin, the next request mints again.
        expires, value, principal = self.credd.cache[("aws", "main")]
        self.credd.cache[("aws", "main")] = (dt.datetime.now(UTC) + dt.timedelta(minutes=2), value, principal)
        self.credd.aws("main")
        self.assertEqual(len(self.run.calls), 2)

    def test_aws_refuses_short_lived_mint(self):
        self.run.responses["aws sts assume-role"] = assume_role_output(1)
        with self.assertRaises(infra_credd.CredentialError):
            self.credd.aws("main")

    def test_aws_without_role_uses_sso_export(self):
        self.run.responses["aws configure export-credentials"] = json.dumps(
            {"Version": 1, "AccessKeyId": "ASIA2", "SecretAccessKey": "s", "SessionToken": "t", "Expiration": later(60)})
        self.assertEqual(self.credd.aws("sso")["AccessKeyId"], "ASIA2")

    def test_aws_refuses_long_lived_keys(self):
        self.run.responses["aws configure export-credentials"] = json.dumps(
            {"Version": 1, "AccessKeyId": "AKIA", "SecretAccessKey": "s"})
        with self.assertRaises(infra_credd.CredentialError):
            self.credd.aws("sso")

    def test_expired_session_hint(self):
        self.run.responses["aws sts assume-role"] = infra_credd.CredentialError("aws sts assume-role failed: Token has expired")
        with self.assertRaises(infra_credd.CredentialError) as caught:
            self.credd.aws("main")
        self.assertIn("aws sso login --profile sso-prod", str(caught.exception))
        self.run.responses["az account get-access-token"] = infra_credd.CredentialError("az failed")
        with self.assertRaises(infra_credd.CredentialError) as caught:
            self.credd.azure("https://management.azure.com/")
        self.assertIn("az login --tenant tenant-1", str(caught.exception))

    def test_unknown_account(self):
        with self.assertRaises(infra_credd.CredentialError):
            self.credd.aws("other")

    def test_azure_allowlisted_resource(self):
        expires = int((dt.datetime.now(UTC) + dt.timedelta(hours=1)).timestamp())
        self.run.responses["az account get-access-token"] = json.dumps(
            {"accessToken": "aad", "expires_on": expires, "tenant": "tenant-1"})
        token = self.credd.azure("https://management.azure.com")
        self.assertEqual(token["access_token"], "aad")
        self.assertEqual(token["expires_on"], str(expires))
        self.assertEqual(token["token_type"], "Bearer")
        # Trailing slash and /.default variants share the cache entry.
        self.credd.azure("https://management.azure.com/.default")
        self.assertEqual(len(self.run.calls), 1)
        self.assertIn("--tenant", self.run.calls[0][0])

    def test_azure_refuses_other_audiences(self):
        with self.assertRaises(infra_credd.CredentialError):
            self.credd.azure("https://vault.azure.net")
        self.assertEqual(self.run.calls, [])

    def test_eks_uses_minted_role(self):
        self.run.responses["aws sts assume-role"] = assume_role_output()
        self.run.responses["aws eks get-token"] = json.dumps(
            {"kind": "ExecCredential", "status": {"token": "k8s-aws-v1.x", "expirationTimestamp": later(14)}})
        credential = self.credd.k8s("payments")
        self.assertEqual(credential["status"]["token"], "k8s-aws-v1.x")
        self.assertEqual(credential["apiVersion"], "client.authentication.k8s.io/v1beta1")
        env = self.run.calls[1][1]
        self.assertEqual(env["AWS_ACCESS_KEY_ID"], "ASIA1")
        self.assertEqual(env["AWS_SESSION_TOKEN"], "session")
        self.assertNotIn("AWS_PROFILE", env)

    def test_aks_token(self):
        expires = int((dt.datetime.now(UTC) + dt.timedelta(hours=1)).timestamp())
        self.run.responses["az account get-access-token"] = json.dumps({"accessToken": "aks", "expires_on": expires})
        credential = self.credd.k8s("orders")
        self.assertEqual(credential["status"]["token"], "aks")
        self.assertIn(infra_credd.AKS_SERVER_APP_ID, self.run.calls[0][0])

    def test_db_password(self):
        self.run.responses["pass show db/orders"] = "hunter2\n"
        self.assertEqual(self.credd.db("orders"), {"password": "hunter2"})
        self.run.responses["pass show db/orders"] = "a\nb\n"
        with self.assertRaises(infra_credd.CredentialError):
            self.credd.db("orders")

    def test_revoke_and_status(self):
        self.run.responses["aws sts assume-role"] = assume_role_output()
        self.credd.aws("main")
        status = self.credd.status()
        self.assertEqual(status[0]["kind"], "aws")
        self.assertNotIn("secret", json.dumps(status))
        self.assertEqual(self.credd.revoke(), 1)
        self.credd.aws("main")
        self.assertEqual(len(self.run.calls), 2)


class UnixHTTPConnection(http.client.HTTPConnection):
    def __init__(self, path):
        super().__init__("localhost")
        self.path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(self.path)


class ServerTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.socket = os.path.join(self.dir.name, "credd.sock")
        self.audit = os.path.join(self.dir.name, "audit.jsonl")
        self.run = FakeRunner()
        self.run.responses["aws sts assume-role"] = assume_role_output()
        expires = int((dt.datetime.now(UTC) + dt.timedelta(hours=1)).timestamp())
        self.run.responses["az account get-access-token"] = json.dumps({"accessToken": "aad", "expires_on": expires})
        os.chmod(self.dir.name, 0o700)
        credd = infra_credd.Credd(CONFIG, self.audit, run=self.run)
        self.server = infra_credd.bind(self.socket, credd, TOKEN)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.dir.cleanup()

    def request(self, method, path, headers=None, body=None):
        connection = UnixHTTPConnection(self.socket)
        connection.request(method, path, body=body, headers=headers or {})
        response = connection.getresponse()
        data = response.read()
        connection.close()
        return response.status, json.loads(data) if data else None

    def test_requires_token(self):
        self.assertEqual(self.request("GET", "/aws/main")[0], 401)
        self.assertEqual(self.request("GET", "/aws/main", {"Authorization": "wrong"})[0], 401)
        self.assertEqual(self.request("GET", "/healthz")[0], 200)

    def test_aws_container_format(self):
        # botocore sends AWS_CONTAINER_AUTHORIZATION_TOKEN without a Bearer prefix.
        status, body = self.request("GET", "/aws/main", {"Authorization": TOKEN})
        self.assertEqual(status, 200)
        self.assertEqual(body["AccessKeyId"], "ASIA1")

    def test_azure_msi_format(self):
        status, body = self.request("GET", "/msi/token?resource=https%3A%2F%2Fmanagement.azure.com%2F&api-version=2019-08-01",
                                    {"X-IDENTITY-HEADER": TOKEN})
        self.assertEqual(status, 200)
        self.assertEqual(body["access_token"], "aad")
        self.assertIsInstance(body["expires_on"], str)
        status, body = self.request("GET", "/msi/token?resource=https%3A%2F%2Fvault.azure.net", {"X-IDENTITY-HEADER": TOKEN})
        self.assertEqual(status, 502)

    def test_audit_from_broker(self):
        record = json.dumps({"event": "tool", "tool": "k8s_pods_list", "ts": "forged", "source": "forged"})
        status, _ = self.request("POST", "/audit", {"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"}, record)
        self.assertEqual(status, 200)
        with open(self.audit) as stream:
            last = json.loads(stream.readlines()[-1])
        self.assertEqual(last["source"], "broker")
        self.assertNotEqual(last["ts"], "forged")
        self.assertEqual(last["tool"], "k8s_pods_list")

    def test_socket_permissions(self):
        self.assertEqual(os.stat(self.socket).st_mode & 0o077, 0)

    def test_refuses_shared_directory(self):
        shared = os.path.join(self.dir.name, "shared")
        os.mkdir(shared, 0o755)
        os.chmod(shared, 0o755)
        credd = infra_credd.Credd(CONFIG, None, run=self.run)
        with self.assertRaises(infra_credd.CredentialError):
            infra_credd.bind(os.path.join(shared, "credd.sock"), credd, TOKEN)
        with self.assertRaises(infra_credd.CredentialError):
            infra_credd.bind(os.path.join(self.dir.name, "short.sock"), credd, "short")


if __name__ == "__main__":
    unittest.main()
