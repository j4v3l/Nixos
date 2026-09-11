{
  config,
  lib,
  pkgs,
  ...
}:
let
  hw = config.aurora.hardware;
  physical = hw.formFactor != "vm";
  intel = builtins.elem "intel" hw.gpus;
  media = if hw.intelMediaDriver == "legacy" then "intel-vaapi-driver" else "intel-media-driver";
in
{
  hardware.enableRedistributableFirmware = lib.mkDefault physical;
  hardware.cpu.intel.updateMicrocode = lib.mkDefault (physical && hw.cpu == "intel");
  hardware.cpu.amd.updateMicrocode = lib.mkDefault (physical && hw.cpu == "amd");
  boot.kernelModules =
    lib.optional (physical && hw.cpu == "intel") "kvm-intel"
    ++ lib.optional (physical && hw.cpu == "amd") "kvm-amd";
  hardware.graphics = {
    enable = true;
    enable32Bit = hw.graphics32Bit;
    extraPackages = lib.optional intel pkgs.${media};
    extraPackages32 = lib.optionals (intel && hw.graphics32Bit) [ pkgs.pkgsi686Linux.${media} ];
  };
  environment.systemPackages = [
    pkgs.vulkan-tools
    pkgs.libva-utils
  ];
}
