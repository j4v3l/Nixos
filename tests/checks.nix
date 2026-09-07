{ inputs, mkHost }:
let
  pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
  lib = inputs.nixpkgs.lib;
  defaults = builtins.fromJSON (builtins.readFile ../templates/desktop/settings.json);
  # Evaluation-only fixture: no vendor payload is downloaded or built with these hashes.
  amdArchives = lib.mapAttrs (_: name: {
    inherit name;
    hash = lib.fakeHash;
  }) (pkgs.callPackage ../pkgs/amd-npu { archives = { }; }).names;
  fixture = { lib, ... }: {
    fileSystems."/" = {
      device = "/dev/vda";
      fsType = "ext4";
    };
    boot.loader.grub.enable = lib.mkForce false;
    boot.loader.systemd-boot.enable = true;
    fileSystems."/boot" = {
      device = "/dev/vdb";
      fsType = "vfat";
    };
  };
  variants = {
    intel = {
      cpu = "intel";
      gpus = [ "intel" ];
    };
    amd = {
      cpu = "amd";
      gpus = [ "amd" ];
    };
    nvidia = {
      cpu = "amd";
      gpus = [ "nvidia" ];
    };
    intel-nvidia = {
      formFactor = "laptop";
      cpu = "intel";
      gpus = [
        "intel"
        "nvidia"
      ];
      nvidia = {
        mode = "offload";
        intelBusId = "PCI:0@0:2:0";
        nvidiaBusId = "PCI:1@0:0:0";
      };
    };
    amd-nvidia = {
      formFactor = "laptop";
      cpu = "amd";
      gpus = [
        "amd"
        "nvidia"
      ];
      nvidia = {
        mode = "offload";
        amdgpuBusId = "PCI:5@0:0:0";
        nvidiaBusId = "PCI:1@0:0:0";
      };
    };
    intel-npu = {
      cpu = "intel";
      gpus = [ "intel" ];
      npu = "intel";
    };
    amd-npu = {
      cpu = "amd";
      gpus = [ "amd" ];
      npu = "amd";
    };
    amd-npu-runtime = {
      cpu = "amd";
      gpus = [ "amd" ];
      npu = "amd";
      amdNpu = {
        runtime = true;
        archives = amdArchives;
      };
    };
    intel-legacy = {
      cpu = "intel";
      gpus = [ "intel" ];
      intelMediaDriver = "legacy";
    };
    nvidia-legacy = {
      cpu = "intel";
      gpus = [ "nvidia" ];
      nvidia = {
        open = false;
        branch = "legacy_580";
      };
    };
  };
  host =
    name: hardware:
    mkHost {
      inherit name;
      settings = lib.recursiveUpdate defaults { inherit hardware; };
      hostModule = fixture;
    };
  evaluated = lib.mapAttrs host variants;
  rejected = [
    {
      cpu = "intel";
      gpus = [
        "intel"
        "nvidia"
      ];
      nvidia.mode = "offload";
    }
    {
      cpu = "intel";
      npu = "amd";
    }
    {
      cpu = "amd";
      npu = "intel";
    }
    {
      gpus = [ "nvidia" ];
      nvidia = {
        open = true;
        branch = "legacy_580";
      };
    }
  ];
  noFeatures = evaluated.intel.config;
  backendHost =
    backend: hardware:
    mkHost {
      name = "compute-${backend}";
      settings = lib.recursiveUpdate defaults {
        inherit hardware;
        features.ai = true;
        ai = { inherit backend; };
      };
      hostModule = fixture;
    };
  assertions =
    assert lib.all (
      hardware: lib.any (a: !a.assertion) (host "invalid" hardware).config.assertions
    ) rejected;
    assert !noFeatures.services.ollama.enable;
    assert !noFeatures.virtualisation.libvirtd.enable;
    assert !noFeatures.services.openssh.enable;
    assert !noFeatures.hardware.nvidia.prime.offload.enable;
    assert noFeatures.networking.enableIPv6;
    assert noFeatures.home-manager.users.nixos.programs.neovim.extraPackages == [ ];
    assert !(lib.any (p: (p.pname or "") == "zed-editor") noFeatures.environment.systemPackages);
    assert lib.any (a: !a.assertion) (backendHost "cuda" variants.intel).config.assertions;
    assert lib.any (a: !a.assertion) (backendHost "rocm" variants.intel).config.assertions;
    assert (backendHost "cpu" variants.intel).config.services.ollama.package.pname == "ollama";
    assert lib.hasInfix "using Vulkan"
      (backendHost "vulkan" variants.amd).config.services.ollama.package.meta.description;
    assert lib.hasInfix "using ROCm"
      (backendHost "rocm" variants.amd).config.services.ollama.package.meta.description;
    assert lib.hasInfix "using CUDA"
      (backendHost "cuda" variants.nvidia).config.services.ollama.package.meta.description;
    assert evaluated.amd-nvidia.config.hardware.nvidia.prime.amdgpuBusId == "PCI:5@0:0:0";
    pkgs.runCommand "profile-assertions" { } "touch $out";
in
(lib.mapAttrs' (
  name: system:
  lib.nameValuePair "eval-${name}" (
    pkgs.runCommand "eval-${name}"
      { derivation = builtins.unsafeDiscardStringContext system.config.system.build.toplevel.drvPath; }
      ''
        printf '%s\n' "$derivation" > "$out"
      ''
  )
) evaluated)
// {
  inherit assertions;
  desktop-system = evaluated.intel.config.system.build.toplevel;
  amd-system = evaluated.amd.config.system.build.toplevel;
  installer-vm = import ./installer-vm.nix { inherit pkgs; };
  installer =
    pkgs.runCommand "installer-tests"
      {
        nativeBuildInputs = [
          pkgs.python3
          pkgs.bash
          pkgs.git
        ];
      }
      ''
        cp -r ${../.} source
        chmod -R u+w source
        cd source
        python3 -m unittest discover -s tests -p 'test_*.py' -v
        touch "$out"
      '';
}
