{ config, lib, pkgs, ... }:

let
  vars = config.aurora.identity;
in
{
  users.users.${vars.username} = {
    isNormalUser = true;

    shell = pkgs.zsh;

    extraGroups = [
      "wheel"
      "networkmanager"
    ];
  };

  programs.zsh.enable = true;

  security.sudo.enable = true;
}
