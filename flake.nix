{
  description = "Adam Roughton's systems and home configurations";

  inputs = {
    # Include the `private` submodule in the flake source; without this the
    # private per-system configuration is silently skipped.
    self.submodules = true;

    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-hardware = {
      url = "github:NixOS/nixos-hardware/master";
      # Only its modules are used; don't fetch a second nixpkgs for it.
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    darwin = {
      url = "github:nix-darwin/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Homebrew taps for superposition. Inputs are fetched lazily, so building
    # other systems does not download them.
    nix-homebrew.url = "github:zhaofengli/nix-homebrew";
    homebrew-core = {
      url = "github:Homebrew/homebrew-core";
      flake = false;
    };
    homebrew-cask = {
      url = "github:Homebrew/homebrew-cask";
      flake = false;
    };
    homebrew-aerospace = {
      url = "github:nikitabobko/homebrew-tap";
      flake = false;
    };
    homebrew-microsandbox = {
      url = "github:superradcompany/homebrew-tap";
      flake = false;
    };
  };

  # Each system is defined in systems/<name>/default.nix, which receives the
  # flake inputs. There is a single lock file for all of them.
  outputs = inputs@{ nixpkgs, ... }: {
    nixosConfigurations = {
      spacemonkey = import ./systems/spacemonkey { inherit inputs; };
      skyhook = import ./systems/skyhook { inherit inputs; };
      rpi3 = import ./systems/rpi3 { inherit inputs; };
    };

    darwinConfigurations.superposition = import ./systems/superposition { inherit inputs; };

    homeConfigurations."adamr@skyhook-ho" = import ./systems/skyhook-ho { inherit inputs; };

    packages = nixpkgs.lib.genAttrs [ "aarch64-linux" "x86_64-linux" ] (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in {
        agent-image = import ./systems/agent-computer { inherit inputs system; };
        # infra-agent broker VM image and the packages it contains.
        infra-broker-image = import ./systems/infra-broker { inherit inputs system; };
        infra-broker = pkgs.callPackage ./packages/infra-broker { };
        dbhub = pkgs.callPackage ./packages/dbhub { };
        kubernetes-mcp-server = pkgs.callPackage ./packages/kubernetes-mcp-server { };
        azure-mcp = pkgs.callPackage ./packages/azure-mcp { };
        # infra-agent built from an example configuration (a check and a reference).
        infra-agent-example = import ./modules/infra-agent/tests/example.nix { inherit inputs system; };
      });
  };
}
