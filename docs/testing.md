# Testing and measurements

## Automated checks

The Linux development shell supplies the tools used by CI:

```bash
nix develop -c bash scripts/check.sh --format
nix flake check --all-systems --no-build --no-write-lock-file
nix build --no-link -L .#checks.x86_64-linux.desktop-system
nix build --no-link -L .#checks.x86_64-linux.amd-system
nix build --no-link -L .#checks.x86_64-linux.installer-vm
```

The workflow runs Nix formatting, ShellCheck, Nix/Lua/QML syntax checks,
installer fixtures, and shell behavior tests. Evaluation covers Intel and AMD
integrated graphics, dedicated NVIDIA, both NVIDIA PRIME combinations, Intel
NPU, AMD NPU (driver and experimental runtime), and explicit Intel/NVIDIA legacy driver choices. Invalid PRIME,
CPU/NPU mismatch, and legacy/open-module combinations must be rejected. New
host fixtures disable optional bundles and SSH.

The AMD runtime evaluation fixture uses synthetic hashes solely to evaluate
the derivation. It never builds or claims to validate vendor payloads; real
hosts must supply the actual archive hashes.

The VM check partitions only its disposable second disk, tests both sgdisk
and parted, formats and mounts it, generates hardware configuration, and checks
UUIDs against the actual partitions. It does not perform a complete installed
system boot or exercise UEFI NVRAM cleanup. Do not run disk-destructive tests
on a workstation to validate this installer.

Local validation on the development Mac has passed the hardware evaluation
matrix, Nix formatting, ShellCheck, Lua/Nix parsing, 21 installer/host/theme
tests, and JavaScript behavior tests. An earlier QML syntax pass succeeded;
the final local pass skipped QML because the Qt tool was no longer available.
CI repeats QML parsing; neither check validates Quickshell runtime imports.
Linux system builds and the disposable VM test are defined in CI but
have not been run here. No physical GPU/NPU or live Wayland result is recorded.

## Runtime acceptance

From the target Hyprland session:

```bash
./scripts/runtime-check.sh
```

This checks configuration errors, running services, Vulkan/VA-API enumeration,
and the selected NPU check. An unavailable NPU returns 77 (skipped). It does
not lock or suspend the machine automatically.

Record the host, PCI IDs, kernel, driver version, flake lock revision, command
output, and result for each manual check:

| Check | Expected behavior |
| --- | --- |
| Single laptop panel | Panel stays enabled; no external monitor is required |
| Two displays, mixed scale | One bar on each display; readable size and correct popup bounds |
| Click network/audio/calendar on either bar | Popup stays on the clicked display |
| Open each keyboard launcher | Launcher uses the currently focused display |
| Unplug a display with a popup open | Popup closes; remaining bar continues working |
| No battery/backlight/Bluetooth | Missing controls and their separators disappear |
| Desktop power profile | Power picker works without a battery |
| Audio starts, pauses, bar expands, display disconnects | One Cava process while needed, none while unused |
| Copy notification with `$(...)`, backticks, quotes, newlines | Clipboard contains the literal text; no command executes |
| `SUPER+L`, idle ten minutes, suspend/resume | Lock appears, unlock works, resume is protected |
| Switch every theme, then rebuild and log in | Selection persists; no configuration errors |
| Crimson in Kitty, Neovim, tmux, Quickshell, Hyprland, Hyprlock | Shared palette remains readable |
| Change configured default and activate | Fresh theme initializes correctly; GTK/Qt update after activation and app restart |
| GPU workload and NPU inference | Actual requested device executes the workload; enumeration is insufficient |

Never mark suspend, acceleration, or inference tested based on Nix evaluation.
Record unavailable hardware as skipped and failures with their logs.

## Performance

The changes reduce wallpaper transitions from 180 to 60 FPS and idle backlight
polling from 400 ms to two seconds. Interaction still polls quickly. Cava is
shared by all bars and stops when unused. New hosts avoid optional application
closures. Nix allows multiple builds but gives each one core by default,
avoiding unrestricted nested parallelism. zram and power-profiles-daemon remain.

No speedup or memory reduction has been measured on target hardware. Compare
before and after on the same host, power profile, displays, brightness, and
applications, after a few idle minutes:

```bash
mkdir -p reports
./scripts/measure.sh > reports/before.txt
# Rebuild, reboot, restore the same workload and wait for idle.
./scripts/measure.sh > reports/after.txt
```

The report includes boot time, memory, zram, desktop process CPU/RSS, system
closure size, and cgroup CPU samples. Repeat idle CPU sampling over a longer
interval if background activity changes the result. Package closure size is
disk usage, not resident memory.

## Troubleshooting

- `hyprctl configerrors`: Lua/configuration errors. First rebuild, then reload;
  reloading alone does not install edits from this checkout.
- `journalctl --user -u quickshell -b`: QML errors and shell startup failures.
- `journalctl --user -u hypridle -b`: lock and idle integration.
- `journalctl -k -b`: graphics/NPU driver and firmware failures.
- `vulkaninfo --summary`, `vainfo`: driver enumeration and video capabilities.
- An unknown flake host usually means new files have not been staged in Git.
- HTTP 403 for a wallpaper: use the original-file import described in
  [wallpapers](wallpapers.md).
- Failed installation: leave the target mounted, inspect the reported failing
  step and generated hardware, and retry deliberately. A dry run cannot prove
  an image boots; use a disposable VM and retain a known working generation.
