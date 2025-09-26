{ pkgs, lib, ... }:
{
  # Let Determinate Nix handle the mgmt of nix.
  nix.enable = false;
  
  # Set primaryUser for nix-darwin
  system.primaryUser = "Adam.Roughton";

  environment.variables.HOMEBREW_NO_ANALYTICS = "1";
  homebrew = {
    enable = true;
    
    onActivation = {
      autoUpdate = true;
      cleanup = "zap";
      upgrade = true;
    };

    casks = [
      "microsoft-teams"
      "slack"
      "nikitabobko/aerospace/aerospace"
      "spotify"
      "1password"
      "obsidian"
    ];

  };

  environment.systemPackages = with pkgs; [
    kitty
    terminal-notifier
    colima
    docker-client
    unixODBC
  ];

  # Copied from NixOS
  environment.etc."odbcinst.ini".text = 
    let
      iniDescription = pkg: ''
        [${pkg.fancyName}]
        Description = ${pkg.meta.description}
        Driver = ${pkg}/${pkg.driver}
      '';     
    in with pkgs.unixODBCDrivers; lib.concatMapStringsSep "\n" iniDescription [ msodbcsql18 ];

  users.users."Adam.Roughton" = {
    home = "/Users/Adam.Roughton";
  };
  system.stateVersion = 6;
}
