{ config, lib, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [

    # Browser

    zen-browser

    # File Manager

    shared-mime-info
    ffmpegthumbnailer

    # Archives

    p7zip
    unar

    # Archive Manager
    file-roller

    # Audio

    pavucontrol

    # Theming

    nwg-look
    qt6Packages.qt6ct
    kdePackages.qtstyleplugin-kvantum

    # Network

    networkmanagerapplet

    # Screenshots

    grim
    slurp
    swappy

    # Image Viewer / Basic Editor

    kdePackages.gwenview
    imagemagick

    # Authentication

    kdePackages.polkit-kde-agent-1

    # Wallpaper

    awww

    # Launcher

    # Notifications

    libnotify

    # Desktop Utilities

    xdg-utils

  ] ++ lib.optionals config.aurora.features.creator (with pkgs; [
    (obs-studio.override { cudaSupport = builtins.elem "nvidia" config.aurora.hardware.gpus; })
    ffmpeg vlc libreoffice-fresh gimp blender
  ]);
}
