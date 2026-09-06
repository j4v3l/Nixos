{ config, lib, pkgs, ... }:
{
  programs.hyprlock.enable = true;
  xdg.configFile."hypr/hyprlock.conf".text = ''
    source = ${config.home.homeDirectory}/.config/aurora/active-hyprlock.conf
    general {
      hide_cursor = true
    }
    background {
      monitor =
      color = $background
    }
    input-field {
      monitor =
      size = 300, 56
      position = 0, -80
      halign = center
      valign = center
      outline_thickness = 2
      inner_color = $surface
      outer_color = $accent
      font_color = $text
      check_color = $accent
      fail_color = $error
      rounding = 12
      placeholder_text = Password
    }
  '';
  services.hypridle = {
    enable = true;
    settings = {
      general = {
        lock_cmd = "pidof hyprlock || ${lib.getExe pkgs.hyprlock}";
        before_sleep_cmd = "${pkgs.systemd}/bin/loginctl lock-session";
        after_sleep_cmd = "${pkgs.hyprland}/bin/hyprctl dispatch dpms on";
        inhibit_sleep = 3;
      };
      listener = [ {
        timeout = 600;
        on-timeout = "${pkgs.systemd}/bin/loginctl lock-session";
      } ];
    };
  };
}
