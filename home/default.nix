{ vars, ... }:

{
  imports = [
    ./git
    ./zsh
    ./kitty
    ./tmux
    ./fastfetch
    ./ssh
    ./xdg
    ./neovim
    ./hyprland
    ./quickshell
    ./obsidian
    ./lock
    ./theme
  ];

  home.username = vars.username;
  home.homeDirectory = "/home/${vars.username}";

  home.stateVersion = "26.05";

  programs.home-manager.enable = true;
}
