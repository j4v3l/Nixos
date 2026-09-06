{ config, ... }:

let
  vars = config.aurora.identity;
in
{
  time.timeZone = vars.timezone;

  i18n.defaultLocale = vars.locale;

  console.keyMap = "us";

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];

    # Official Nix binary cache ONLY.
    substituters = [
      "https://cache.nixos.org/"
    ];

    require-sigs = true;

    http-connections = 25;

    connect-timeout = 10;
    stalled-download-timeout = 90;

    cores = 1;
    max-jobs = "auto";

  };

  nix.gc = {
    automatic = true;

    dates = "weekly";

    options = "--delete-older-than 30d";

    # Do not let a garbage collect fight a rebuild for I/O.
    randomizedDelaySec = "30min";
  };

  nix.optimise = {
    automatic = true;

    dates = [ "weekly" ];
  };

  nixpkgs.config.allowUnfree = true;

  system.stateVersion = "26.05";
}
