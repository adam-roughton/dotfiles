{ pkgs, ... }:
{
  config = {
    home.packages = with pkgs; [
      zathura gimp dia 
    ];
  };
}
