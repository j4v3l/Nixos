# Aurora NixOS

A NixOS 26.05 configuration for x86-64 laptops, desktops, and Proxmox guests, using Hyprland,
Quickshell, Home Manager, and Stylix. This fork keeps the desktop from
[subha279/NixOS](https://github.com/subha279/NixOS) and adds per-machine settings,
optional application bundles, screen locking, and the Crimson theme.

Hardware profiles are evaluated in CI. GPU acceleration, suspend, and NPU
inference need results from actual devices; see [testing](docs/testing.md).

## Install

Boot a NixOS installation ISO in UEFI mode, connect to the internet, then:

```bash
nix-shell -p git python3
git clone https://github.com/j4v3l/NixOS.git
cd NixOS
sudo ./setup.sh clean-install --host desktop --profile desktop
```

Use a distinct host name for each machine. Setup detects CPU, graphics, NPU,
and chassis information, shows the resulting settings, then asks you to review
identity, bundles, and NVIDIA choices. Review driver compatibility in
[hardware configuration](docs/hardware.md) before installing.

Clean installation erases the selected disk after confirmation. It creates a
1 GiB EFI partition and an ext4 root partition, generates the target's hardware
configuration, builds the system, installs GRUB, and prompts for a password.
Use `--layout encrypted` for LUKS2 with root and persistent swap LVs. Yoga
presets default to that layout. Dual boot is not configured. See
[Yoga power, hibernation, and Proxmox setup](docs/laptops-and-vms.md) for the
14AKP10/14IRL8 commands, storage requirements, and runtime validation.

Preview the workflow without writing files or changing disks:

```bash
./setup.sh clean-install --host desktop --profile desktop --dry-run
```

On an existing NixOS installation, configure from that machine instead:

```bash
./setup.sh configure --host desktop --profile desktop
```

This generates hardware against the running installation and offers a rebuild.
It does not repartition. The checked-in `laptop` host belongs to the original
machine: **do not install its disk UUIDs on another computer**. A desktop template
contains settings only and becomes buildable once setup generates its hardware.

## Configure

Each host has three files:

```text
hosts/<name>/settings.json                Identity, hardware, bundles, monitors
hosts/<name>/hardware-configuration.nix   Generated filesystems and device modules
hosts/<name>/default.nix                  Imports and local Nix overrides
```

JSON is imported as `config.aurora`; all options are declared in
[modules/options.nix](modules/options.nix). Nix evaluation uses these saved
values and never detects the evaluator's hardware. For example:

```json
{
  "hardware": { "formFactor": "desktop", "cpu": "amd", "gpus": ["amd"], "npu": "none" },
  "features": { "development": true, "creator": false, "virtualisation": false, "ai": false, "wallpapers": true },
  "desktop": { "monitors": [{ "output": "DP-1", "mode": "preferred", "position": "auto", "scale": 1.5 }] }
}
```

Merge those fields into the generated settings; retain `identity`. New hosts
start with optional bundles and SSH disabled. The migrated laptop retains its
existing identity, bundles, SSH access, and hardware file. Existing state
versions remain unchanged. [Migration notes](docs/migration.md) cover the changes.

| Bundle | Adds |
| --- | --- |
| `development` | Compilers, Zed, language servers, formatters, and automatic Neovim linting |
| `creator` | OBS, DaVinci Resolve, Blender, GIMP, LibreOffice, and media tools |
| `virtualisation` | libvirt and virt-manager |
| `ai` | Ollama with an explicitly selected backend |
| `wallpapers` | The two optional Wallhaven assets used for Crimson |

## Apply and maintain

```bash
./setup.sh check --host desktop
./setup.sh dry --host desktop
./setup.sh rebuild --host desktop
./setup.sh hardware --host desktop
./setup.sh generations --host desktop
./setup.sh rollback --host desktop
```

Setup remembers the selected host in `.setup-host`; `--host` overrides it.
Without either, it uses `laptop` for compatibility. Backups go to
`.setup-backups/<timestamp>/<host>/`. Rollback affects the installed system
generation, regardless of the selected host name. `./setup.sh help` lists all
commands.

New host files must be tracked for Git-based flakes. Setup stages just the
host's settings, imports, and generated hardware file. After manual creation,
run `git add hosts/<name>` before building.

Home Manager links configuration from the active Nix store generation. After
editing this repository, rebuild before reloading Hyprland or Quickshell.

## Desktop

Every connected screen gets a bar. Module clicks open a popup on that screen;
keyboard launchers open on the focused screen. Screens use their preferred mode
unless overridden per host. Internal laptop screens remain enabled by default.

| Shortcut | Action |
| --- | --- |
| `SUPER+T`, `SUPER+E`, `SUPER+B` | Terminal, files, browser |
| `SUPER+A` | Applications |
| `SUPER+C`, `SUPER+P` | Theme and wallpaper pickers |
| `SUPER+V`, `SUPER+I` | Clipboard and emoji pickers |
| `SUPER+L` | Lock |
| `SUPER+Z` | Zed, when the development bundle is enabled |

Hypridle locks after ten minutes and before suspend, then powers displays off
after eleven minutes. Automatic idle suspend is disabled; laptop lid policy is
configured separately. Battery, backlight, and Bluetooth controls appear only when available;
a desktop without a battery can still select power profiles.

## Themes

`lib/themes.nix` defines the shared palettes and fonts. Crimson adds charcoal
backgrounds, burgundy surfaces, warm pale text, and pink/red accents. Catppuccin
Mocha remains the default. A saved theme and wallpaper survive rebuilds.

```bash
aurora-theme crimson
```

Runtime switching updates Quickshell, Hyprland, Kitty, Neovim, tmux, Starship,
and the next lock screen. GTK and Qt use the configured default through Stylix:
change `global.activeTheme` in `lib/themes.nix`, rebuild, and restart toolkit
applications to apply that palette.

Enable `features.wallpapers`, rebuild, and use `SUPER+P` to choose either
[13pgxw](https://wallhaven.cc/w/13pgxw) or
[3q6m6y](https://wallhaven.cc/w/3q6m6y). Local images and managed symlinks in
`~/Wallpapers` are also discovered. See [wallpaper attribution and downloads](docs/wallpapers.md).

## Troubleshooting and development

See [hardware](docs/hardware.md), [testing and measurements](docs/testing.md),
and [migration](docs/migration.md). On Linux, the pinned tools and checks are:

```bash
nix develop -c bash scripts/check.sh --format
nix flake check --all-systems --no-build
```

The original desktop design and configuration are credited to
[subha279](https://github.com/subha279/NixOS). The upstream
[showcase](https://www.youtube.com/watch?v=J9286xiVBNk) depicts that version.
