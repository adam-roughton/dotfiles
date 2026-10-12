"""Startup control-flow tests with fake engines; no daemon or Nix required."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "agent-docker"
UTIL_LINUX = next(Path("/nix/store").glob("*util-linux-minimal*-bin/bin"), None)


class StartupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="agent-docker-", dir="/tmp")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        extra_path = f":{UTIL_LINUX}" if UTIL_LINUX else ""
        self.env = dict(os.environ, HOME=str(self.home), PATH=f"{self.bin}{extra_path}:{os.environ['PATH']}")
        self.env.pop("DOCKER_HOST", None)
        self.runtime = self.home / ".local/run/agent-docker"
        self.binary("docker", f'test -e "{self.root}/ready"')
        self.binary("tun", f'touch "{self.root}/tun-ready"')
        self.binary("binfmt", f'touch "{self.root}/binfmt-ready"')
        self.binary(
            "dockerd",
            f'test -e "{self.root}/tun-ready"; test -e "{self.root}/binfmt-ready"; '
            f'printf "%s\\n" "$@" >> "{self.root}/args"; touch "{self.root}/ready"',
        )
        ca = self.root / "ca.pem"
        ca.write_text("test CA\n")
        text = SCRIPT.read_text().replace("@docker@", str(self.bin / "docker"))
        text = text.replace("@dockerd@", str(self.bin / "dockerd"))
        text = text.replace("@cacert@", str(ca))
        text = text.replace("@tun@", str(self.bin / "tun"))
        text = text.replace("@binfmt@", str(self.bin / "binfmt"))
        self.script = self.root / "start"
        self.script.write_text("#!/bin/bash\nset -euo pipefail\n" + text)

    def binary(self, name, text):
        path = self.bin / name
        path.write_text("#!/bin/bash\nset -euo pipefail\n" + text + "\n")
        path.chmod(0o755)

    def run_start(self, *args):
        return subprocess.run(
            ["/bin/bash", str(self.script), *args], env=self.env,
            capture_output=True, text=True, timeout=10,
        )

    def test_starts_once_and_is_quiet(self):
        for _ in range(2):
            result = self.run_start()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "")
        args = (self.root / "args").read_text()
        self.assertEqual(args.count("--storage-driver=vfs"), 1)
        self.assertIn(f"--host=unix://{self.runtime}/docker.sock", args)
        self.assertEqual(self.runtime.stat().st_mode & 0o777, 0o700)

    def test_remote_host_does_not_start_daemon(self):
        self.env["DOCKER_HOST"] = "tcp://remote:2376"
        self.assertEqual(self.run_start().returncode, 0)
        self.assertFalse(self.runtime.exists())

    def test_concurrent_clients_share_one_startup(self):
        self.binary(
            "dockerd",
            f'sleep 1; printf "%s\\n" "$@" >> "{self.root}/args"; touch "{self.root}/ready"',
        )
        clients = [
            subprocess.Popen(["/bin/bash", str(self.script)], env=self.env,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            for _ in range(4)
        ]
        for client in clients:
            out, err = client.communicate(timeout=15)
            self.assertEqual(client.returncode, 0, err)
            self.assertEqual(out, "")
        self.assertEqual((self.root / "args").read_text().count("--storage-driver=vfs"), 1)

    def test_restart_discards_previous_boot_state(self):
        self.runtime.mkdir(parents=True)
        (self.runtime / "boot-id").write_text("previous-boot\n")
        (self.runtime / "launcher.pid").write_text(str(os.getpid()))
        (self.runtime / "rootlesskit").mkdir()
        (self.runtime / "rootlesskit/stale").touch()
        result = self.run_start()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.runtime / "rootlesskit/stale").exists())

    def test_restart_replaces_existing_ca_bundle(self):
        self.runtime.mkdir(parents=True)
        (self.runtime / "ca-bundle.crt").write_text("old CA\n")
        (self.runtime / "ca-bundle.crt").chmod(0o500)
        result = self.run_start()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.runtime / "ca-bundle.crt").read_text().startswith("test CA\n"))
        self.assertNotIn("old CA", (self.runtime / "ca-bundle.crt").read_text())
        self.assertEqual((self.runtime / "ca-bundle.crt").stat().st_mode & 0o777, 0o600)

    def test_failed_daemon_reports_log(self):
        self.binary("dockerd", "exit 1")
        result = self.run_start()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("daemon.log", result.stderr)

    def test_tun_failure_does_not_launch_daemon(self):
        self.binary("tun", 'printf "TUN access denied\\n" >&2; exit 1')
        result = self.run_start()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("TUN access denied", result.stderr)
        self.assertFalse((self.root / "args").exists())

    def test_binfmt_failure_warns_and_starts_daemon(self):
        self.binary("binfmt", 'printf "binfmt denied\\n" >&2; exit 1')
        self.binary(
            "dockerd",
            f'printf "%s\\n" "$@" >> "{self.root}/args"; touch "{self.root}/ready"',
        )
        result = self.run_start()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertIn("amd64 emulation unavailable", result.stderr)
        self.assertTrue((self.root / "args").exists())


if __name__ == "__main__":
    unittest.main()
