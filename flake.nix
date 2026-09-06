{
  description = "Aurora NixOS desktop and laptop configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    stylix = {
      url = "github:danth/stylix/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    apple-fonts = {
      url = "github:Lyndeno/apple-fonts.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    zen-browser = {
      url = "github:youwen5/zen-browser-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };

  };

  outputs = inputs@{ nixpkgs, ... }:
    let
      mkHost = import ./lib/mk-host.nix { inherit inputs; };
      hosts = nixpkgs.lib.filterAttrs (name: kind:
        kind == "directory" && builtins.pathExists (./hosts + "/${name}/settings.json")
      ) (builtins.readDir ./hosts);
    in {
      nixosConfigurations = builtins.mapAttrs (name: _: mkHost {
        inherit name;
        settings = builtins.fromJSON (builtins.readFile (./hosts + "/${name}/settings.json"));
        hostModule = ./hosts + "/${name}";
      }) hosts;
      templates.desktop = {
        path = ./templates/desktop;
        description = "Desktop host settings; run setup.sh configure to detect hardware.";
      };
      formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixfmt;
      checks.x86_64-linux = import ./tests/checks.nix { inherit inputs mkHost; };
    };
}
