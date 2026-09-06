{ aurora, lib, pkgs, ... }:
let
  sources = builtins.fromJSON (builtins.readFile ../../lib/wallpapers.json);
in {
  home.file = lib.mkIf aurora.features.wallpapers (lib.mapAttrs' (id: asset:
    lib.nameValuePair "Wallpapers/${asset.name}" {
      source = pkgs.fetchurl {
        inherit (asset) name url hash;
        # Some Wallhaven edges require the image page as the referrer.
        curlOptsList = [ "--referer" asset.source "--user-agent" "Mozilla/5.0" ];
      };
    }
  ) sources);
}
