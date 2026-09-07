{
  aurora,
  lib,
  pkgs,
  ...
}:

{
  programs.neovim = {
    enable = true;

    defaultEditor = true;
    viAlias = true;
    vimAlias = true;

    # Keep Neovim itself lightweight.
    withNodeJs = false;
    withPython3 = false;

    plugins = with pkgs.vimPlugins; [
      # Completion

      blink-cmp

      # LSP / Code intelligence

      nvim-lspconfig

      # Syntax / Treesitter

      (
        if aurora.features.development then
          nvim-treesitter.withAllGrammars
        else
          nvim-treesitter.withPlugins (p: [
            p.bash
            p.json
            p.lua
            p.nix
            p.markdown
            p.markdown_inline
            p.query
            p.vim
            p.vimdoc
            p.yaml
            p.toml
          ])
      )
      nvim-colorizer-lua

      # Search / Navigation

      telescope-nvim

      telescope-fzf-native-nvim

      plenary-nvim
      nvim-web-devicons

      # Git

      gitsigns-nvim

      # Formatting / Linting

      conform-nvim
      nvim-lint

      # UI

      which-key-nvim
      lualine-nvim
      snacks-nvim

      # File Manager
      nvim-tree-lua

      # Dashboard
      alpha-nvim
    ];

    # Tools available directly to Neovim.
    extraPackages = lib.optionals aurora.features.development (
      with pkgs;
      [

        # LSP

        # QML language server, formatter, and linter.
        qt6.qtdeclarative

        lua-language-server
        rust-analyzer
        typescript-language-server
        pyright
        clang-tools
        nixd
        bash-language-server
        vscode-langservers-extracted
        yaml-language-server
        marksman
        tailwindcss-language-server
        dockerfile-language-server
        taplo

        # Formatters

        stylua
        prettier
        ruff
        nixfmt
        shfmt
        eslint_d
        shellcheck
        rustfmt

        # C / C++ development

        gcc
        gdb
        cmake
        pkg-config

        # Git / VCS

        lazygit
      ]
    );
  };

  xdg.configFile."nvim" = {
    source = ./config;
    recursive = true;
  };
  xdg.configFile."nvim/lua/aurora/host.lua".text =
    "return " + lib.generators.toLua { } { development = aurora.features.development; };
}
