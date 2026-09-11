{ inputs }:
{
  name,
  settings,
  hostModule,
  extraModules ? [ ],
}:
inputs.nixpkgs.lib.nixosSystem {
  system = "x86_64-linux";
  modules = [
    (import ./host-module.nix { inherit inputs; } { inherit settings hostModule extraModules; })
  ];
}
