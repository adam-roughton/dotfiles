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
  };

  outputs = inputs@{ self, nixpkgs, home-manager, darwin, ... }:
    let
      system = "aarch64-darwin";
      pkgs = (import nixpkgs {
        inherit system;
        config = {
          allowUnfree = true;
        };
      });
      extraSpecialArgs = {
         inherit system;
      };
    in {      
      homeConfigurations = {
        "Adam.Roughton" = home-manager.lib.homeManagerConfiguration {
            # pkgs = nixpkgs.legacyPackages.${system};
            inherit pkgs extraSpecialArgs;
            modules = [ ./home.nix ];
        };
      };
      darwinConfigurations = {
         hostname = darwin.lib.darwinSystem {
            inherit system;
            modules = [
               home-manager.darwinModules.home-manager {
          	home-manager = {
          	  useGlobalPkgs = true;
          	  useUserPackages = true;
                  inherit extraSpecialArgs;
                  users."Adam.Roughton" = {
                    imports = [ ./home.nix ];
                  };
          	};
               }
            ];
         };
      };
  };
}
