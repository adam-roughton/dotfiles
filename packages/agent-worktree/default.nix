{ writeShellApplication, git, jq, _1password-cli, sandbox-runtime, pi-coding-agent }:

writeShellApplication {
  name = "agent-worktree";
  runtimeInputs = [ git jq _1password-cli sandbox-runtime pi-coding-agent ];
  text = builtins.readFile ./agent-worktree.sh;
}
