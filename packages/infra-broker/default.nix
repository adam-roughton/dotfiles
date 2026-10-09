# Python tools that run inside the infra-agent broker VM: the MCP gateway, the
# read-only AWS MCP server and the credential helpers. See README "Infra Agent".
{ lib, python3Packages }:
python3Packages.buildPythonApplication {
  pname = "infra-broker";
  version = "0.1.0";
  pyproject = true;

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [ ./pyproject.toml ./src ./tests ];
  };

  build-system = [ python3Packages.setuptools ];
  dependencies = with python3Packages; [ boto3 fastmcp httpx ];

  pythonImportsCheck = [ "infra_broker.gateway" "infra_broker.aws_server" "infra_broker.credential" ];

  # The tests start the gateway on a loopback port and spawn stdio servers.
  checkPhase = ''
    runHook preCheck
    FASTMCP_CHECK_FOR_UPDATES=off python -m unittest discover -s tests -v
    runHook postCheck
  '';

  meta = {
    description = "Read-only MCP gateway and helpers for the infra-agent broker VM";
    license = lib.licenses.mit;
    mainProgram = "infra-broker-gateway";
  };
}
