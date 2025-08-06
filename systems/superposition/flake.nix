{
  description = "Home Manager for superposition";

  inputs = {
    self.submodules = true;
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    home-manager = {
       url = "github:nix-community/home-manager";
       inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = inputs@{ self, nixpkgs, flake-utils, home-manager, ... }:
    flake-utils.lib.eachDefaultSystem (system:
       let
         pkgs = import nixpkgs { 
            inherit system;
	    config = {
	      allowUnfree = true;
	      cudaSupport = true;
	    };
         };
       in {
         legacyPackages = {
            homeConfigurations = {
              "adamr" = home-manager.lib.homeManagerConfiguration {
                inherit pkgs;
                modules = [ ./home.nix ];
                extraSpecialArgs = {
                  inherit system;
                };
              };
            };
          };
       });
}
