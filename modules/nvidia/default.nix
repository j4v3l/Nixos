{ config, lib, ... }:
let
  hw = config.aurora.hardware;
  cfg = hw.nvidia;
  enabled = builtins.elem "nvidia" hw.gpus;
  offload = cfg.mode == "offload";
  busId = value: builtins.match "PCI:[0-9]+(@[0-9]+)?:[0-9]+:[0-9]+" value != null;
in {
  config = lib.mkIf enabled {
    services.xserver.videoDrivers = [ "nvidia" ];
    hardware.nvidia = {
      inherit (cfg) open branch;
      modesetting.enable = true;
      powerManagement.enable = true;
      prime = lib.mkIf offload {
        offload.enable = true;
        offload.enableOffloadCmd = true;
        inherit (cfg) intelBusId amdgpuBusId nvidiaBusId;
      };
    };
    assertions = [
      {
        assertion = !offload || (busId cfg.nvidiaBusId &&
          ((builtins.elem "intel" hw.gpus && busId cfg.intelBusId && cfg.amdgpuBusId == "") ||
           (builtins.elem "amd" hw.gpus && busId cfg.amdgpuBusId && cfg.intelBusId == "")));
        message = "NVIDIA offload requires its PCI bus ID and exactly one matching Intel or AMD GPU bus ID.";
      }
      {
        assertion = !(lib.hasPrefix "legacy_" cfg.branch) || !cfg.open;
        message = "Legacy NVIDIA branches require aurora.hardware.nvidia.open = false.";
      }
    ];
  };
}
