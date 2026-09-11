{ pkgs }:
pkgs.testers.runNixOSTest {
  name = "installer-disk";
  nodes.machine = { pkgs, ... }: {
    virtualisation.emptyDiskImages = [ 4096 ];
    environment.systemPackages = with pkgs; [
      gptfdisk
      parted
      dosfstools
      e2fsprogs
    ];
    environment.etc."installer-test.sh".source = pkgs.writeShellScript "installer-test" ''
      set -euo pipefail
      source ${../scripts/setup}/installation.sh
      source ${../scripts/setup/hardware.sh}
      section() { :; }; info() { :; }; success() { :; }; run_cmd() { :; }
      error() { echo "$*" >&2; }; warning() { echo "$*" >&2; }
      v_ok() { :; }; v_info() { :; }; v_fail() { echo "$*" >&2; V_FAILED=1; }
      need_cmd() { command -v "$1" >/dev/null; }
      host_stage_files() { :; }
      HOST=disposable
      CI_DISK=/dev/vdb
      CI_ESP=/dev/vdb1
      CI_ROOT_PART=/dev/vdb2
      CI_TARGET=/mnt/test-install
      CI_DEST=$CI_TARGET/repo
      CI_MKFS_FAT=mkfs.fat
      CI_PARTITIONER="$1"
      V_FAILED=0
      # These functions only see the VM's disposable second disk.
      ci_partition
      ci_format
      ci_mount
      ci_generate_hardware
      ci_verify_hardware
      [[ "$V_FAILED" -eq 0 ]]
      cp "$CI_DEST/hosts/$HOST/hardware-configuration.nix" /tmp/generated-hardware.nix
      umount "$CI_TARGET/boot"
      umount "$CI_TARGET"
    '';
  };
  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")
    for partitioner in ["sgdisk", "parted"]:
        machine.succeed(f"bash /etc/installer-test.sh {partitioner}")
        machine.succeed("test $(blkid -s TYPE -o value /dev/vdb1) = vfat")
        machine.succeed("test $(blkid -s TYPE -o value /dev/vdb2) = ext4")
        machine.succeed("grep -F $(blkid -s UUID -o value /dev/vdb2) /tmp/generated-hardware.nix")
  '';
}
