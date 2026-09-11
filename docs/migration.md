# Migration

The existing `#laptop` output remains available. Its identity now lives in
`hosts/laptop/settings.json`; `lib/variables.nix` is a compatibility view for
older personal modules. System and Home Manager state versions, disk UUIDs,
filesystems, and the existing laptop's application selections are preserved.
Setup does not rename or remove an existing user's home directory.

Review these intentional changes before switching an existing installation:

- Monitors default to preferred mode. The laptop panel is enabled again; add
  explicit monitor overrides if you want the previous external-only layout.
- NVIDIA settings are scoped to the host. PRIME needs valid decimal bus IDs;
  dedicated mode does not. Forced NVIDIA environment variables are removed.
- SSH remains enabled with the laptop's previous password setting. New hosts
  leave SSH disabled; edit `ssh.enable` and add your authorized keys explicitly.
- NetworkManager uses the network's DNS settings, and IPv6 is enabled. Put any
  deliberate local network policy in the host module.
- Hypridle locks after ten minutes and before suspend. `SUPER+L` locks manually.
- The keyboard-specific Kreo RGB module remains enabled for the laptop. New
  hosts leave it off; access uses the active session instead of granting all
  users access to input devices.
- tmux reads generated Aurora colors. Its Tokyo Night theme plugin is removed;
  existing non-theme TPM plugins and keybindings remain.
- The terminal and emoji font names now match their installed packages.

For a different machine, create a new host rather than editing the original
hardware file. On the target NixOS machine:

```bash
./setup.sh configure --host workstation --profile desktop
```

Review the generated JSON and diff before accepting the offered switch. Setup
backs up the previous host files first. A failed hardware-generation command
leaves the previous hardware file intact; settings already applied remain
available for review and can be restored from the backup.

`setup.sh hardware --host workstation` refreshes filesystem/device configuration
only. `setup.sh detect` prints current hardware suggestions; hardware options
remain your saved choices until you change them. Clean installation redetects
hardware before displaying the settings review.

For recovery, select an older generation in GRUB or run
`sudo nixos-rebuild switch --rollback`. Do not raise `stateVersion` as part of a
routine package upgrade.


## Yoga and VM profiles

The `laptop` host and its disk settings remain unchanged. Configure independent
`yoga-amd`, `yoga-intel`, or `vm` hosts on their target machines. Existing installs
are never repartitioned by configure/rebuild. Encryption requires an explicit
fresh installation; do not copy fixture UUIDs or test keys into a real host.
Laptop Wi-Fi power saving and idle display-off are now enabled; set
`power.wifiPowerSave: false` if the wireless device regresses. Charge conservation
and automatic AC/battery profile selection remain opt-in. Existing hosts without
persistent resume storage retain power-off as their critical battery action.
