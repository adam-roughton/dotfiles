# Common wiring for the NixOS systems, called from systems/<name>/default.nix.
#
# `hardwareConfiguration` is required and must be given explicitly:
#   - a path to the machine's generated hardware configuration (filesystems,
#     boot partition, initrd modules, swap). Evaluation fails with
#     instructions if the file does not exist yet.
#   - null for systems whose hardware is fully described by their own modules
#     (rpi3 uses the fixed SD card layout).
{ inputs, name, system, overlay, homeUser, homeModule, hardwareConfiguration, modules }:
let
  inherit (inputs) nixpkgs home-manager;
  hasHardwareConfiguration =
    hardwareConfiguration != null && builtins.pathExists hardwareConfiguration;
in
nixpkgs.lib.nixosSystem {
  inherit system;
  specialArgs = { inherit inputs; };
  modules = [
    home-manager.nixosModules.home-manager
    ({ config, lib, ... }: {
      options.dotfiles.requireHardwareConfiguration = lib.mkOption {
        type = lib.types.bool;
        default = hardwareConfiguration != null;
        internal = true;
        description = ''
          Whether evaluation fails when the machine's hardware configuration
          file is missing. Off for VM builds, which bring their own virtual
          hardware and filesystems.
        '';
      };

      config = {
        assertions = [{
          assertion = hasHardwareConfiguration || !config.dotfiles.requireHardwareConfiguration;
          message = ''
            ${name}: the hardware configuration is missing:
              ${toString hardwareConfiguration}
            Without it the system has no /boot or root filesystem and may not boot.
            Generate it on ${name} and add it to the repository (Nix ignores untracked files):
              nixos-generate-config --show-hardware-config > systems/${name}/hardware-configuration.nix
              git add systems/${name}/hardware-configuration.nix
          '';
        }];

        virtualisation.vmVariant.dotfiles.requireHardwareConfiguration = false;

        nixpkgs.config.allowBroken = true;
        nixpkgs.config.allowUnfree = true;
        nixpkgs.overlays = [ (import overlay) ];
        home-manager.useGlobalPkgs = true;
        home-manager.useUserPackages = true;
        home-manager.extraSpecialArgs = { user = import ../user.nix; };
        home-manager.users.${homeUser}.imports = [ homeModule ];
      };
    })
  ] ++ nixpkgs.lib.optional hasHardwareConfiguration hardwareConfiguration
    ++ modules;
}
