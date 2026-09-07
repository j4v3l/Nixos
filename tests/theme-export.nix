{ lib }:
let
  module = import ../home/theme {
    lib = lib // {
      hm.dag.entryAfter = _: text: text;
    };
  };
in
{
  files = lib.mapAttrs (_: file: file.text) module.xdg.configFile;
  activation = module.home.activation.initializeAuroraTheme;
  switcher = module.home.file.".local/bin/aurora-theme".text;
}
