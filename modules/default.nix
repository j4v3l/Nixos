{
  config,
  lib,
  pkgs,
  ...
}:
{
  imports = [
    ./options.nix
    ./core
    ./boot
    ./networking
    ./users
    ./packages
    ./fonts
    ./audio
    ./bluetooth
    ./polkit
    ./graphics
    ./xdg
    ./notifications
    ./hyprland
    ./desktop
    ./session
    ./monitoring
    ./nvidia
    ./hardware/models.nix
    ./power
    ./stylix
    ./development
    ./ai
    ./creator
    ./virtualisation
    ./hardware/kreo-rgb
    ./npu.nix
  ];
  networking.hostName = config.aurora.identity.hostname;
  boot.kernelPackages = lib.mkIf (
    config.aurora.hardware.kernel == "latest"
  ) pkgs.linuxPackages_latest;
  hardware.kreoRgb = {
    enable = config.aurora.hardware.kreoRgb;
    followTheme = true;
  };
  assertions = [
    {
      assertion = builtins.match "[a-z_][a-z0-9_-]*" config.aurora.identity.username != null;
      message = "aurora.identity.username must be a Linux account name.";
    }
    {
      assertion = builtins.match "[A-Za-z0-9][A-Za-z0-9.-]*" config.aurora.identity.hostname != null;
      message = "aurora.identity.hostname must be a valid hostname.";
    }
  ];
}
