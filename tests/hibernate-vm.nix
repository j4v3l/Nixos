{ pkgs }:
let
  # Public fixture key, used only inside this disposable test VM.
  key = pkgs.writeText "disposable-luks-key" "only-a-disposable-test-key";
  luksUuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";
  swapUuid = "11111111-2222-3333-4444-555555555555";
in
pkgs.testers.runNixOSTest {
  name = "encrypted-root-hibernate";
  nodes.machine =
    { lib, ... }:
    {
      imports = [
        ../modules/options.nix
        ../modules/power
      ];
      aurora.hardware.formFactor = "laptop";
      powerManagement.powerDownCommands = "systemctl --no-block stop backdoor.service";
      powerManagement.resumeCommands = "systemctl --no-block restart backdoor.service";
      virtualisation = {
        memorySize = 1024;
        emptyDiskImages = [ 8192 ];
        mountHostNixStore = true;
        useBootLoader = true;
        useEFIBoot = true;
      };
      boot.loader.systemd-boot.enable = true;
      boot.initrd.systemd.enable = true;
      environment.systemPackages = with pkgs; [
        cryptsetup
        lvm2
        gptfdisk
        dosfstools
        e2fsprogs
        python3
      ];
      environment.etc."encrypted-install-test.sh".source =
        pkgs.writeShellScript "encrypted-install-test" ''
          set -euo pipefail
          source ${../scripts/setup}/installation.sh
          source ${../scripts/setup}/hardware.sh
          section() { :; }; info() { :; }; success() { :; }; run_cmd() { :; }
          error() { echo "$*" >&2; }; warning() { echo "$*" >&2; }
          v_ok() { :; }; v_info() { :; }; v_fail() { echo "$*" >&2; V_FAILED=1; }
          need_cmd() { command -v "$1" >/dev/null; }; host_stage_files() { :; }
          HOST=disposable; CI_DISK=/dev/vdb; CI_ESP=/dev/vdb1; CI_ROOT_PART=/dev/vdb2
          CI_TARGET=/mnt/disposable; CI_DEST=$CI_TARGET/repo
          CI_MKFS_FAT=mkfs.fat; CI_PARTITIONER=sgdisk
          CI_LAYOUT=encrypted; CI_VG=aurora_test; CI_SWAP_GIB=2
          CI_PASSPHRASE=$(cat ${key})
          HOST_SETTINGS='{"hardware":{"formFactor":"laptop"}}'
          V_FAILED=0
          ci_partition
          cryptsetup() {
            local action="$1"
            shift
            if [[ "$action" == "luksFormat" ]]; then
              command cryptsetup "$action" --uuid ${luksUuid} "$@"
            else
              command cryptsetup "$action" "$@"
            fi
          }
          mkswap() {
            command mkswap -U ${swapUuid} "$@"
          }
          ci_format
          unset -f cryptsetup mkswap
          ci_storage_settings
          ci_mount
          ci_generate_hardware
          ci_verify_hardware
          [[ "$V_FAILED" -eq 0 ]]
          ci_storage_cleanup
        '';
      specialisation.encrypted.configuration = {
        aurora = {
          power.hibernate = true;
          storage = {
            layout = "encrypted";
            inherit luksUuid swapUuid;
            swapGiB = 2;
          };
        };
        boot.initrd.luks.devices = lib.mkVMOverride {
          aurora = {
            device = "/dev/disk/by-uuid/${luksUuid}";
            keyFile = "/fixture.key";
          };
        };
        boot.initrd.secrets."/fixture.key" = key;
        swapDevices = lib.mkOverride 0 [ { device = "/dev/disk/by-uuid/${swapUuid}"; } ];
        virtualisation.rootDevice = "/dev/aurora_test/root";
      };
    };
  testScript =
    { nodes, ... }:
    ''
      machine.wait_for_unit("multi-user.target")
      machine.succeed("timeout 180 bash /etc/encrypted-install-test.sh")
      machine.succeed("${nodes.machine.specialisation.encrypted.configuration.system.build.toplevel}/bin/switch-to-configuration boot")
      machine.succeed("entry=$(find /boot/loader/entries -maxdepth 1 -name '*-specialisation-encrypted.conf' -printf '%f\\n' | head -n1); test -n \"$entry\"; bootctl set-default \"$entry\"")
      machine.succeed("sync")
      machine.crash()
      machine.wait_for_unit("multi-user.target")
      machine.succeed("test \"$(stat -Lc '%t:%T' \"$(findmnt -n -o SOURCE /)\")\" = \"$(stat -Lc '%t:%T' /dev/aurora_test/root)\"")
      machine.succeed("swap_id=$(stat -Lc '%t:%T' /dev/aurora_test/swap); swapon --show=NAME --noheadings | while read -r device; do test \"$(stat -Lc '%t:%T' \"$device\")\" = \"$swap_id\" && exit 0; done")
      machine.succeed("mkdir /run/resume-test; mount -t ramfs ramfs /run/resume-test; echo restored > /run/resume-test/marker")
      machine.execute("systemctl hibernate >&2 &", check_return=False)
      machine.wait_for_shutdown()
      machine.start()
      machine.succeed("grep restored /run/resume-test/marker")
      machine.crash()
      machine.wait_for_unit("multi-user.target")
      machine.fail("test -e /run/resume-test/marker")
    '';
}
