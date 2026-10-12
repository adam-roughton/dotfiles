{ pkgs, lib, ... }:
let
  # One headless JDK shared by every JVM tool. Each tool otherwise wraps its own full
  # (GTK/X11) JDK, so the image would carry several JDKs.
  jdk = pkgs.jdk17_headless;
  docker = import ./docker.nix { inherit pkgs lib; };

  # Playwright MCP with Chromium only (the default browser set also ships
  # Firefox and WebKit). With the nixpkgs default browser (`chromium`, the
  # Chrome for Testing alias), Playwright runs the full Chromium build in
  # headless mode as well, so the headless shell is not needed either.
  playwright-mcp = pkgs.playwright-mcp.override {
    playwright-driver = pkgs.playwright-driver // {
      browsers = pkgs.playwright-driver.browsers-chromium;
    };
  };

  # nixpkgs' Playwright Chromium defaults to a fontconfig without any fonts, so
  # pages would render without text. Liberation is metric-compatible with
  # Arial, Times New Roman and Courier New, which keeps layouts realistic.
  browserFonts = pkgs.makeFontsConf {
    fontDirectories = with pkgs; [ dejavu_fonts liberation_ttf noto-fonts-color-emoji ];
  };

  # Copilot sandboxes intercept HTTPS with the microsandbox CA. Chromium ignores
  # SSL_CERT_FILE and the system bundle; it trusts its own root store plus the
  # user's NSS database, so add the CA there on every start (the CA may change
  # between sandboxes). stdout is the MCP protocol channel, so all setup output
  # goes to stderr. A failed import only breaks HTTPS sites, not the server.
  playwrightMcp = pkgs.writeShellApplication {
    name = "playwright-mcp";
    runtimeInputs = [ pkgs.nssTools ];
    runtimeEnv.FONTCONFIG_FILE = "${browserFonts}";
    text = ''
      ca=/.msb/tls/ca.pem
      nssdb_dir="$HOME/.pki/nssdb"
      nssdb="sql:$nssdb_dir"
      if [ -r "$ca" ]; then
        if ! {
          mkdir -p "$nssdb_dir" &&
            { [ -e "$nssdb_dir/cert9.db" ] || certutil -N -d "$nssdb" --empty-password; } &&
            { while certutil -D -d "$nssdb" -n microsandbox 2>/dev/null; do :; done; } &&
            certutil -A -d "$nssdb" -n microsandbox -t C,, -i "$ca"
        } >&2; then
          echo "playwright-mcp: cannot add $ca to $nssdb_dir; HTTPS pages will fail certificate checks" >&2
        fi
      fi
      exec ${lib.getExe playwright-mcp} "$@"
    '';
  };
in {
  imports = [
    ../../modules/agent-profiles
    ../../modules/shell
    ../../modules/vim
  ];

  home.username = "adamr";
  home.homeDirectory = "/home/adamr";
  home.stateVersion = "25.05";

  # Same zsh configuration as the workstations, without the workstation-only tools.
  dotfiles.shell.workstation = false;

  # vim-full defaults to a GTK3 GUI with X11/Wayland and Ruby support on Linux.
  dotfiles.vim.package = pkgs.vim-full.override {
    guiSupport = "none";
    waylandSupport = false;
    rubySupport = false;
  };

  # The image only receives packages and dotfiles; the Home Manager manual page is not
  # in the binary cache and would be built (with its doc toolchain) on every update.
  manual.manpages.enable = false;

  # Commit as the host user, but without host-only credentials: there is no GPG key in
  # the sandbox, and rewriting GitHub HTTPS URLs to SSH would break clones.
  programs.git = {
    signing.signByDefault = lib.mkForce false;
    settings.url = lib.mkForce { };
  };

  programs.java = {
    enable = true;
    package = jdk;
  };

  # Writes ~/.config/opencode/opencode.json. The selected agent profile
  # (OPENCODE_CONFIG) and code-agent's OPENCODE_CONFIG_CONTENT are merged on top.
  programs.opencode = {
    enable = true;
    settings = {
      # The microsandbox isolates the agent computer, so local paths outside
      # /workspace do not need an additional OpenCode approval prompt.
      permission.external_directory = "allow";
      mcp.playwright = {
        type = "local";
        command = [
          (lib.getExe playwrightMcp)
          "--headless"
          # Keep the browser profile in memory; each session starts clean.
          "--isolated"
          "--output-dir"
          "/tmp/playwright-mcp"
        ];
      };
    };
  };

  # Skills per agent type. Every profile is in the image; the launcher picks one
  # (code-agent: dotfiles.agentSandbox.agentProfile). See modules/agent-profiles.
  dotfiles.agentProfiles = {
    skills = {
      task-handover.source = ../../skills/task-handover;
      infra-triage.source = ../../skills/infra-triage;
      incident-report.source = ../../skills/incident-report;
    };
    # Skills every agent type gets.
    baseSkills = [ ];
    profiles = {
      code.skills = [ "task-handover" ];
      # infra-agent (modules/infra-agent): production triage through the
      # environment's broker. The VM has no other network access, so the
      # browser is disabled. INFRA_MCP_URL is set when the sandbox is created
      # and INFRA_MCP_TOKEN on every attach, from the incident's token mount.
      infra = {
        skills = [ "infra-triage" "incident-report" ];
        opencodeSettings = {
          instructions = [ "${./infra-agent.md}" ];
          mcp = {
            playwright.enabled = false;
            infra = {
              type = "remote";
              url = "{env:INFRA_MCP_URL}";
              headers.Authorization = "Bearer {env:INFRA_MCP_TOKEN}";
              # The broker uses incident bearer tokens, not OAuth.
              oauth = false;
              # Some broker upstreams (Azure MCP, DBHub) are slow to start.
              timeout = 60000;
              enabled = true;
            };
          };
          permission = {
            webfetch = "deny";
            websearch = "deny";
          };
        };
      };
    };
  };

  home.packages = with pkgs; [
    # agents (opencode comes from programs.opencode)
    pi-coding-agent

    # base userland (the image has no OS underneath Home Manager's packages)
    coreutils gnugrep gnused gawk diffutils patch
    gnutar gzip xz bzip2 less which

    # c
    gcc gnumake

    # python
    python3 uv

    # node
    nodejs

    # rust
    rustc cargo rustfmt

    # jvm / scala
    (gradle.override { java = jdk; })
    (sbt.override { jre = jdk; })
    (scala.override { jre = jdk; })

    # sh
    shellcheck

    # config / data
    jsonnet

    # database clients
    postgresql
    mariadb.client

    # No cloud or Kubernetes CLIs: infra access goes through the infra-agent
    # broker's MCP tools.
  ] ++ docker.packages;

  home.file."AGENTS.md".source = ./AGENTS.md;

  programs.zsh.enable = true;
  programs.bash.enable = true;
}
