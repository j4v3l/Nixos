{ lib, ... }:
let
  inherit (lib) mkOption mkEnableOption types;
  string = default: mkOption { type = types.str; inherit default; };
  choice = values: default: mkOption { type = types.enum values; inherit default; };
in
{
  options.aurora = {
    identity = {
      username = string "nixos";
      hostname = string "nixos";
      fullName = string "";
      gitUser = string "";
      email = string "";
      timezone = string "UTC";
      locale = string "en_US.UTF-8";
    };
    hardware = {
      formFactor = choice [ "laptop" "desktop" ] "desktop";
      cpu = choice [ "intel" "amd" "other" ] "other";
      gpus = mkOption {
        type = types.listOf (types.enum [ "intel" "amd" "nvidia" ]);
        default = [ ];
      };
      intelMediaDriver = choice [ "modern" "legacy" ] "modern";
      graphics32Bit = mkOption { type = types.bool; default = true; };
      nvidia = {
        mode = choice [ "dedicated" "offload" ] "dedicated";
        open = mkOption { type = types.bool; default = true; };
        branch = string "stable";
        intelBusId = string "";
        amdgpuBusId = string "";
        nvidiaBusId = string "";
      };
      npu = choice [ "none" "intel" "amd" ] "none";
      amdNpu = {
        runtime = mkEnableOption "the experimental Ryzen AI 1.8 inference runtime";
        # Vendor archives can require a download agreement. Their hashes are host inputs.
        archives = mkOption {
          type = types.attrsOf (types.submodule {
            options = {
              name = mkOption { type = types.str; };
              hash = mkOption { type = types.str; };
            };
          });
          default = { };
          description = "Pinned vendor artifacts; see docs/hardware.md.";
        };
      };
      kernel = choice [ "stable" "latest" ] "stable";
      kreoRgb = mkEnableOption "the Kreo Hive keyboard";
    };
    features = {
      development = mkEnableOption "development tools";
      creator = mkEnableOption "creator applications";
      virtualisation = mkEnableOption "libvirt and virt-manager";
      ai = mkEnableOption "the local Ollama service";
      wallpapers = mkEnableOption "the two Crimson wallpaper assets";
    };
    ai.backend = choice [ "cpu" "cuda" "rocm" "vulkan" ] "cpu";
    ssh = {
      enable = mkEnableOption "the SSH server";
      passwordAuthentication = mkOption { type = types.bool; default = false; };
    };
    desktop.monitors = mkOption {
      type = types.listOf (types.submodule {
        options = {
          output = mkOption { type = types.str; };
          mode = string "preferred";
          position = string "auto";
          scale = mkOption { type = types.either types.int types.float; default = 1; };
          disabled = mkOption { type = types.bool; default = false; };
        };
      });
      default = [ ];
    };
  };
}
