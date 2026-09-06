{ config, lib, pkgs, ... }:
let
  backend = config.aurora.ai.backend;
  packages = { cpu = pkgs.ollama; cuda = pkgs.ollama-cuda; rocm = pkgs.ollama-rocm; vulkan = pkgs.ollama-vulkan; };
in {
  config = lib.mkIf config.aurora.features.ai {
    services.ollama = {
      enable = true;
      package = packages.${backend};
      host = "127.0.0.1";
    };
    assertions = [
      {
        assertion = backend != "cuda" || builtins.elem "nvidia" config.aurora.hardware.gpus;
        message = "The CUDA backend requires an NVIDIA GPU profile.";
      }
      {
        assertion = backend != "rocm" || builtins.elem "amd" config.aurora.hardware.gpus;
        message = "The ROCm backend requires an AMD GPU profile; verify that model's ROCm support.";
      }
    ];
  };
}
