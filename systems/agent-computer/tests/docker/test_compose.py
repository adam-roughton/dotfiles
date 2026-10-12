"""Run in a rebuilt microsandbox; needs Docker Hub access, pytest-docker >=3.2."""

import os
from pathlib import Path
import subprocess
import urllib.request

import pytest
from pytest_docker.plugin import get_docker_services


@pytest.mark.parametrize("command", ["docker compose", "docker-compose"])
def test_compose_infrastructure(command, docker_ip):
    project = f"agent-smoke-{os.getpid()}-{command.replace(' ', '-')}"
    compose_file = str(Path(__file__).with_name("docker-compose.yml"))
    with get_docker_services(
        command, compose_file, project, ["up --build --wait"], ["down -v"]
    ) as services:
        port = services.port_for("web", 8080)
        with urllib.request.urlopen(f"http://{docker_ip}:{port}", timeout=10) as response:
            assert response.read() == b"agent-compose-ok\n"

    for resource in ("container", "volume"):
        remaining = subprocess.check_output(
            ["docker", resource, "ls", "-q", "--filter", f"label=com.docker.compose.project={project}"],
            text=True,
        )
        assert not remaining.strip(), f"Compose leaked {resource}: {remaining}"


def test_amd64_build_and_run():
    """linux/amd64 builds and containers run natively or under QEMU."""
    tag = f"agent-smoke-amd64:{os.getpid()}"
    context = str(Path(__file__).parent)
    subprocess.run(
        ["docker", "build", "--quiet", "--platform", "linux/amd64", "--tag", tag, context],
        check=True, stdout=subprocess.DEVNULL,
    )
    try:
        machine = subprocess.check_output(
            ["docker", "run", "--rm", "--platform", "linux/amd64", tag,
             "python", "-c", "import platform; print(platform.machine())"],
            text=True,
        )
        assert machine.strip() == "x86_64"
    finally:
        subprocess.run(["docker", "image", "rm", tag], check=False, stdout=subprocess.DEVNULL)
