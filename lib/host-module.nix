{ inputs }:
{
  settings,
  hostModule,
  extraModules ? [ ],
}:
{
  imports = [
    inputs.stylix.nixosModules.stylix
    inputs.home-manager.nixosModules.home-manager
    ../modules
    (../profiles + "/${settings.hardware.formFactor}.nix")
    hostModule
    ({ config, ... }: {
      aurora = settings;
      nixpkgs.overlays = [
        inputs.apple-fonts.overlays.default
        (final: _: {
          zen-browser = inputs.zen-browser.packages.${final.stdenv.hostPlatform.system}.default;
        })
      ];
      home-manager = {
        useGlobalPkgs = true;
        useUserPackages = true;
        extraSpecialArgs = {
          aurora = config.aurora;
          vars = config.aurora.identity;
        };
        users.${config.aurora.identity.username} = import ../home;
      };
    })
  ]
  ++ extraModules;
}
