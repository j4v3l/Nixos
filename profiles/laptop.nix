{ lib, ... }: {
  services.power-profiles-daemon.enable = true;
  services.upower.enable = true;
  powerManagement.enable = true;
  services.libinput.enable = lib.mkDefault true;
}
