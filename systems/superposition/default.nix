{ inputs }:
let
  inherit (inputs) darwin home-manager nix-homebrew;
  system = "aarch64-darwin";
in
darwin.lib.darwinSystem {
  inherit system;
  specialArgs = { inherit inputs; };
  modules = [
    ./system.nix
    home-manager.darwinModules.home-manager
    nix-homebrew.darwinModules.nix-homebrew
    ({ config, ... }: {
      nixpkgs.config.allowUnfree = true;
      nixpkgs.overlays = [ (import ./overlay.nix) ];
      home-manager.useGlobalPkgs = true;
      home-manager.useUserPackages = true;
      home-manager.extraSpecialArgs = { inherit system inputs; };
      home-manager.users."Adam.Roughton" = ./home.nix;
      nix-homebrew = {
        enable = true;
        enableRosetta = true;
        user = "Adam.Roughton";
        taps = {
          "homebrew/homebrew-core" = inputs.homebrew-core;
          "homebrew/homebrew-cask" = inputs.homebrew-cask;
          "nikitabobko/homebrew-aerospace" = inputs.homebrew-aerospace;
          "superradcompany/homebrew-microsandbox" = inputs.homebrew-microsandbox;
        };
        mutableTaps = false;
        trust = {
          taps = [ "superradcompany/microsandbox" ];
        };
      };
      homebrew.taps = builtins.attrNames config.nix-homebrew.taps;
    })
  ];
}
