"""A stand-in upstream MCP server for gateway tests (stdio)."""

import json
import os

from fastmcp import FastMCP

server = FastMCP("fake-upstream")


@server.tool
def pods_list(namespace: str = "default") -> str:
    """List pods."""
    return json.dumps({"namespace": namespace, "pods": ["api-1", "api-2"]})


@server.tool
def pods_delete(name: str) -> str:
    """Delete a pod (must never be reachable through the gateway)."""
    marker = os.environ.get("FAKE_UPSTREAM_MARKER")
    if marker:
        with open(marker, "w") as stream:
            stream.write(name)
    return "deleted"


@server.tool
def big() -> str:
    """Return a large result."""
    return "x" * 50_000


@server.tool
def pid() -> str:
    """Report the server's process ID."""
    return str(os.getpid())


@server.tool
def crash() -> str:
    """Exit the server process abruptly."""
    os._exit(1)


@server.tool
def env(name: str) -> str:
    """Report an environment variable."""
    return os.environ.get(name, "<unset>")


if __name__ == "__main__":
    server.run()
