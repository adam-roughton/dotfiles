{ pkgs, ... }: {
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
      "docker"
    ];
  };

  environment.systemPackages = with pkgs; [
    kitty
    terminal-notifier
  ];

  users.users."Adam.Roughton" = {
    home = "/Users/Adam.Roughton";
  };
  system.stateVersion = 6;
}
