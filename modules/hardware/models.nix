{ config, lib, ... }:
let
  hw = config.aurora.hardware;
  yoga = hw.model != "generic";
  vendor = if hw.model == "yoga-14akp10" then "amd" else "intel";
in
{
  services.fwupd.enable = lib.mkDefault (hw.formFactor == "laptop");
  services.thermald.enable = lib.mkDefault (hw.model == "yoga-14irl8");
  assertions = [
    {
      assertion = !yoga || (hw.formFactor == "laptop" && hw.cpu == vendor && hw.gpus == [ vendor ]);
      message = "Yoga presets require their matching CPU and integrated GPU, and the laptop profile.";
    }
    {
      assertion = hw.model != "yoga-14irl8" || hw.npu == "none";
      message = "Yoga 7 14IRL8 has no Intel NPU.";
    }
    {
      assertion = hw.formFactor != "vm" || (hw.npu == "none" && !config.aurora.power.hibernate);
      message = "The VM guest profile does not support physical NPUs or hibernation.";
    }
  ];
}
