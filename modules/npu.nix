{
  config,
  lib,
  pkgs,
  ...
}:
let
  hw = config.aurora.hardware;
  intelPython = pkgs.python3.withPackages (ps: [
    ps.openvino
    ps.numpy
  ]);
  amd = pkgs.callPackage ../pkgs/amd-npu { archives = hw.amdNpu.archives; };
  check = pkgs.writeShellApplication {
    name = "aurora-npu-check";
    runtimeInputs = [
      pkgs.pciutils
      pkgs.kmod
    ];
    text =
      if hw.npu == "intel" then
        ''
          exec ${intelPython}/bin/python ${../scripts/npu-intel.py}
        ''
      else if hw.npu == "amd" && hw.amdNpu.runtime then
        ''
          exec ${amd.runtime}/bin/aurora-amd-npu "$@"
        ''
      else
        ''
          lspci -nn -d ::12 || true
          echo "SKIP: ${
            if hw.npu == "amd" then
              "AMD driver enabled; configure the optional Ryzen AI runtime for inference"
            else
              "no NPU profile selected"
          }" >&2
          exit 77
        '';
  };
in
{
  hardware.cpu.intel.npu.enable = hw.npu == "intel";
  boot.kernelModules =
    lib.optional (hw.npu == "intel") "intel_vpu" ++ lib.optional (hw.npu == "amd") "amdxdna";
  services.udev.extraRules = lib.mkIf (hw.npu != "none") ''
    SUBSYSTEM=="accel", KERNEL=="accel[0-9]*", GROUP="render", MODE="0660", TAG+="uaccess"
  '';
  users.users.${config.aurora.identity.username}.extraGroups = lib.optional (
    hw.npu != "none"
  ) "render";
  environment.systemPackages = [
    check
  ]
  ++ lib.optionals (hw.npu == "amd" && hw.amdNpu.runtime) [ amd.runtime ];
  hardware.firmware = lib.optionals (hw.npu == "amd" && hw.amdNpu.runtime) [ amd.firmware ];
  assertions = [
    {
      assertion = hw.npu != "intel" || hw.cpu == "intel";
      message = "An Intel NPU requires the Intel CPU profile.";
    }
    {
      assertion = hw.npu != "amd" || hw.cpu == "amd";
      message = "An AMD NPU requires the AMD CPU profile.";
    }
    {
      assertion = !hw.amdNpu.runtime || hw.npu == "amd";
      message = "The Ryzen AI runtime requires the AMD NPU profile.";
    }
  ];
}
