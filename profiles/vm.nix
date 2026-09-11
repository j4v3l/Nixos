{ config, lib, ... }: {
  hardware.cpu.intel.updateMicrocode = lib.mkForce false;
  hardware.cpu.amd.updateMicrocode = lib.mkForce false;
  services.qemuGuest.enable = true;
  boot.initrd.availableKernelModules = [
    "virtio_pci"
    "virtio_scsi"
    "virtio_blk"
    "virtio_net"
    "virtio_gpu"
  ];
  boot.kernelParams = [
    "console=tty0"
    "console=ttyS0,115200"
  ];
  environment.sessionVariables = lib.mkIf (config.aurora.vm.graphics == "software") {
    LIBGL_ALWAYS_SOFTWARE = "1";
    GALLIUM_DRIVER = "llvmpipe";
  };
}
