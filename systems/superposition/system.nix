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
      "betterdisplay"
      "drawio"
    ];

    brews = [
      "openssl@3"
      "unixodbc" # some python binaries hardcode brew paths
    ];

  };

  environment.systemPackages = with pkgs; [
    kitty
    terminal-notifier
    colima
    docker-client
    unixodbc
  ];

  # Copied from NixOS
  environment.etc."odbcinst.ini".text = 
    let
      iniDescription = pkg: ''
        [${pkg.fancyName}]
        Description = ${pkg.meta.description}
        Driver = ${pkg}/${pkg.driver}
      '';     
    in with pkgs.unixodbcDrivers; lib.concatMapStringsSep "\n" iniDescription [ 
      msodbcsql18
    ];

  users.users."Adam.Roughton" = {
    home = "/Users/Adam.Roughton";
  };
  system.stateVersion = 6;
}
