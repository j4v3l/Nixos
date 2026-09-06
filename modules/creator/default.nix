{ config, lib, pkgs, ... }:

{
  config = lib.mkIf config.aurora.features.creator {
  environment.systemPackages = with pkgs; [
    davinci-resolve
  ];
  };
}
