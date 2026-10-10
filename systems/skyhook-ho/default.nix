{ inputs }:
let
  system = "x86_64-linux";
in
inputs.home-manager.lib.homeManagerConfiguration {
  pkgs = import inputs.nixpkgs {
    inherit system;
    config.allowUnfree = true;
    config.cudaSupport = true;
  };
  modules = [ ./home.nix ];
  extraSpecialArgs = { inherit system inputs; };
}
