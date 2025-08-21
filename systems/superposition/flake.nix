{
  description = "Home Manager for superposition";

  inputs = {
    self.submodules = true;
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    darwin = {
       url = "github:nix-darwin/nix-darwin";
       inputs.nixpkgs.follows = "nixpkgs";
    };
    home-manager = {
       url = "github:nix-community/home-manager";
       inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-homebrew.url = "github:zhaofengli/nix-homebrew";
    homebrew-core = {
      url = "github:homebrew/homebrew-core";
      flake = false;
    };
    homebrew-cask = {
      url = "github:homebrew/homebrew-cask";
      flake = false;
    };

  };

  outputs = inputs@{ 
    self, nixpkgs, home-manager, darwin, nix-homebrew, 
    homebrew-core, homebrew-cask, ... 
  }:
    let
      system = "aarch64-darwin";
      pkgs = (import nixpkgs {
        inherit system;
        config = {
          allowUnfree = true;
        };
        overlays = [
          (import ./overlay.nix)
        ];
      });
      extraSpecialArgs = {
         inherit system;
      };
    in {      
      homeConfigurations = {
        "Adam.Roughton" = home-manager.lib.homeManagerConfiguration {
            inherit pkgs extraSpecialArgs;
            modules = [ ./home.nix ];
        };
      };
      darwinConfigurations = {
         "superposition" = darwin.lib.darwinSystem {
            inherit system pkgs;
            modules = [
              ./system.nix
               home-manager.darwinModules.home-manager {
                  home-manager = {
                    inherit extraSpecialArgs;
                    useGlobalPkgs = true;
                    useUserPackages = true;
                    users."Adam.Roughton" = import ./home.nix;
                  };
               }
               nix-homebrew.darwinModules.nix-homebrew {
                  nix-homebrew = {
                    enable = true;
                    enableRosetta = true;
                    user = "Adam.Roughton";
                    taps = {
                      "homebrew/homebrew-core" = homebrew-core;
                      "homebrew/homebrew-cask" = homebrew-cask;
                    };
                    mutableTaps = false;
                  };
               }
               ({config, ...}: {
                 homebrew.taps = builtins.attrNames config.nix-homebrew.taps;
               })
            ];
         };
      };
  };
}
