{ inputs, pkgs }:
pkgs.testers.runNixOSTest {
  name = "proxmox-desktop-guest";
  node.pkgsReadOnly = false;
  nodes.machine = { lib, ... }: {
    boot.consoleLogLevel = lib.mkForce 7;
    imports = [
      (import ../lib/host-module.nix { inherit inputs; } {
        settings = builtins.fromJSON (builtins.readFile ../templates/vm/settings.json);
        hostModule = { };
      })
    ];
    virtualisation = {
      memorySize = 4096;
      cores = 2;
      qemu.options = [
        "-vga none"
        "-device virtio-vga"
      ];
    };
    services.getty.autologinUser = "nixos";
  };
  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.wait_until_succeeds("pgrep -u nixos -x Hyprland")
    machine.wait_until_succeeds("su - nixos -c 'XDG_RUNTIME_DIR=/run/user/1000 hyprctl -i 0 monitors -j' | grep -q '\"name\"'")
    machine.wait_until_succeeds("pgrep -u nixos -x qs")
    errors = machine.succeed("su - nixos -c 'XDG_RUNTIME_DIR=/run/user/1000 hyprctl -i 0 configerrors'")
    assert not errors.strip(), errors
    machine.succeed("su - nixos -c 'XDG_RUNTIME_DIR=/run/user/1000 systemctl --user is-active quickshell.service'")
    machine.screenshot("desktop-guest")
  '';
}
