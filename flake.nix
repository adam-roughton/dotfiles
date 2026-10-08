{
  description = "Adam Roughton's systems and home configurations";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    darwin = {
      url = "github:nix-darwin/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };

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
  };

  outputs = inputs@{ self, nixpkgs, nixos-hardware, home-manager, darwin
    , nix-homebrew, homebrew-core, homebrew-cask, homebrew-aerospace, ... }:
    let
      repo = builtins.path { path = ./.; name = "dotfiles"; };
      linuxSystem = system: name: extraModules:
        nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = { inherit inputs; };
          modules = [
            home-manager.nixosModules.home-manager
            {
              nixpkgs.config.allowBroken = true;
              nixpkgs.config.allowUnfree = true;
              nixpkgs.overlays = [ (import ./systems/${name}/overlay.nix) ];
              fileSystems."/" = {
                device = "/dev/disk/by-label/NIXOS";
                fsType = "ext4";
              };
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.extraSpecialArgs = { user = import ./user.nix; };
            }
          ] ++ extraModules;
        };
    in {
      nixosConfigurations = {
        spacemonkey = linuxSystem "x86_64-linux" "spacemonkey" [
          ./systems/spacemonkey/system.nix
          ./systems/spacemonkey/hardware.nix
          { home-manager.users.adamr.imports = [ "${repo}/systems/spacemonkey/home.nix" ]; }
        ];
        skyhook = linuxSystem "x86_64-linux" "skyhook" [
          ./systems/skyhook/system.nix
          ./systems/skyhook/hardware.nix
          { home-manager.users.adamr.imports = [ "${repo}/systems/skyhook/home.nix" ]; }
        ];
        rpi3 = linuxSystem "aarch64-linux" "rpi3" [
          ./systems/rpi3/system.nix
          ./systems/rpi3/hardware.nix
          { home-manager.users.adam.imports = [ "${repo}/systems/rpi3/home.nix" ]; }
        ];
      };

      darwinConfigurations.superposition = darwin.lib.darwinSystem {
        system = "aarch64-darwin";
        specialArgs = { inherit inputs; };
        modules = [
          ./systems/superposition/system.nix
          home-manager.darwinModules.home-manager
          nix-homebrew.darwinModules.nix-homebrew
          ({ config, ... }: {
            nixpkgs.config.allowUnfree = true;
            nixpkgs.overlays = [ (import ./systems/superposition/overlay.nix) ];
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.extraSpecialArgs = { system = "aarch64-darwin"; };
            home-manager.users."Adam.Roughton" = ./systems/superposition/home.nix;
            nix-homebrew = {
              enable = true;
              enableRosetta = true;
              user = "Adam.Roughton";
              taps = {
                "homebrew/homebrew-core" = homebrew-core;
                "homebrew/homebrew-cask" = homebrew-cask;
                "nikitabobko/homebrew-aerospace" = homebrew-aerospace;
              };
              mutableTaps = false;
            };
            homebrew.taps = builtins.attrNames config.nix-homebrew.taps;
          })
        ];
      };

      homeConfigurations = {
        "adamr@skyhook-ho" = home-manager.lib.homeManagerConfiguration {
          pkgs = import nixpkgs {
            system = "x86_64-linux";
            config.allowUnfree = true;
            config.cudaSupport = true;
          };
          modules = [ ./systems/skyhook-ho/home.nix ];
          extraSpecialArgs = { system = "x86_64-linux"; };
        };
      };

      packages = nixpkgs.lib.genAttrs [ "aarch64-linux" "x86_64-linux" ] (system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };
          home = home-manager.lib.homeManagerConfiguration {
            inherit pkgs;
            modules = [ ./systems/agent-computer/home.nix ];
          };
          contents = pkgs.buildEnv {
            name = "dotfiles-agent-image-contents";
            paths = [ pkgs.bashInteractive pkgs.zsh ] ++ home.config.home.packages;
            pathsToLink = [ "/bin" "/sbin" "/lib" "/share" ];
          };
        in {
          agent-image = pkgs.dockerTools.buildLayeredImage {
            name = "dotfiles-agent";
            tag = "latest";
            # `msb load` reads the archive as a plain tar and does not
            # decompress it, so the default gzip output cannot be loaded.
            compressor = "none";
            contents = [ contents ];
            extraCommands = ''
              mkdir -p root workspace
              cp ${./systems/agent-computer/AGENTS.md} AGENTS.md
              cp ${./systems/agent-computer/AGENTS.md} root/AGENTS.md
            '';
            config = {
              Cmd = [ "${pkgs.zsh}/bin/zsh" ];
              Env = [
                "HOME=/root"
                "PATH=/bin:/sbin"
                "SHELL=${pkgs.zsh}/bin/zsh"
                "USER=root"
              ];
              WorkingDir = "/workspace";
            };
          };
        });
    };
}
