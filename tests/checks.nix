{ inputs, mkHost }:
let
  pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
  lib = inputs.nixpkgs.lib;
  defaults = builtins.fromJSON (builtins.readFile ../templates/desktop/settings.json);
  fixture = { lib, ... }: {
    fileSystems."/" = { device = "/dev/vda"; fsType = "ext4"; };
    boot.loader.grub.enable = lib.mkForce false;
    boot.loader.systemd-boot.enable = true;
    fileSystems."/boot" = { device = "/dev/vdb"; fsType = "vfat"; };
  };
  variants = {
    intel = { cpu = "intel"; gpus = [ "intel" ]; };
    amd = { cpu = "amd"; gpus = [ "amd" ]; };
    nvidia = { cpu = "amd"; gpus = [ "nvidia" ]; };
    intel-nvidia = { formFactor = "laptop"; cpu = "intel"; gpus = [ "intel" "nvidia" ]; nvidia = { mode = "offload"; intelBusId = "PCI:0@0:2:0"; nvidiaBusId = "PCI:1@0:0:0"; }; };
    amd-nvidia = { formFactor = "laptop"; cpu = "amd"; gpus = [ "amd" "nvidia" ]; nvidia = { mode = "offload"; amdgpuBusId = "PCI:5@0:0:0"; nvidiaBusId = "PCI:1@0:0:0"; }; };
    intel-npu = { cpu = "intel"; gpus = [ "intel" ]; npu = "intel"; };
    amd-npu = { cpu = "amd"; gpus = [ "amd" ]; npu = "amd"; };
  };
  host = name: hardware: mkHost {
    inherit name;
    settings = lib.recursiveUpdate defaults { inherit hardware; };
    hostModule = fixture;
  };
  evaluated = lib.mapAttrs host variants;
  invalid = host "invalid-prime" { cpu = "intel"; gpus = [ "intel" "nvidia" ]; nvidia.mode = "offload"; };
  noFeatures = evaluated.intel.config;
  assertions = assert lib.any (a: !a.assertion) invalid.config.assertions;
    assert !noFeatures.services.ollama.enable;
    assert !noFeatures.virtualisation.libvirtd.enable;
    assert !noFeatures.services.openssh.enable;
    assert !noFeatures.hardware.nvidia.prime.offload.enable;
    assert noFeatures.networking.enableIPv6;
    assert evaluated.amd-nvidia.config.hardware.nvidia.prime.amdgpuBusId == "PCI:5@0:0:0";
    pkgs.runCommand "profile-assertions" { } "touch $out";
in
(lib.mapAttrs' (name: system: lib.nameValuePair "eval-${name}" (
  pkgs.runCommand "eval-${name}" { derivation = system.config.system.build.toplevel.drvPath; } ''
    printf '%s\n' "$derivation" > "$out"
  ''
)) evaluated) // {
  inherit assertions;
  desktop-system = evaluated.intel.config.system.build.toplevel;
  installer = pkgs.runCommand "installer-tests" { nativeBuildInputs = [ pkgs.python3 pkgs.bash pkgs.git ]; } ''
    cp -r ${../.} source
    chmod -R u+w source
    cd source
    python3 -m unittest discover -s tests -p 'test_*.py' -v
    touch "$out"
  '';
}
