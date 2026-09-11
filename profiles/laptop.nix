{ lib, ... }: {
  services.libinput.enable = lib.mkDefault true;
}
