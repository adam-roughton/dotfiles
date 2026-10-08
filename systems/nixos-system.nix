# Common wiring for the NixOS systems, called from systems/<name>/default.nix.
{ inputs, system, overlay, homeUser, homeModule, modules }:
let
  inherit (inputs) nixpkgs home-manager;
in
nixpkgs.lib.nixosSystem {
  inherit system;
  specialArgs = { inherit inputs; };
  modules = [
    home-manager.nixosModules.home-manager
    {
      nixpkgs.config.allowBroken = true;
      nixpkgs.config.allowUnfree = true;
      nixpkgs.overlays = [ (import overlay) ];
      # Placeholder root filesystem; a system's hardware.nix can override it
      # (rpi3 boots from NIXOS_SD).
      fileSystems."/" = nixpkgs.lib.mkDefault {
        device = "/dev/disk/by-label/NIXOS";
        fsType = "ext4";
      };
      home-manager.useGlobalPkgs = true;
      home-manager.useUserPackages = true;
      home-manager.extraSpecialArgs = { user = import ../user.nix; };
      home-manager.users.${homeUser}.imports = [ homeModule ];
    }
  ] ++ modules;
}
