# Yoga laptops and Proxmox guests

## Install each Yoga separately

These presets target Yoga 7 2-in-1 **14AKP10** (AMD) and Yoga 7 **14IRL8**
(Intel). The second model is not 14IRL6. The AMD preset uses Radeon graphics;
the Intel preset uses Iris Xe and has no Intel NPU. Detection reads DMI, CPU,
PCI devices and RAM, and saves the inventory in host JSON. Exact wireless,
panel, and firmware variants still need testing on each machine.

From an x86-64 NixOS ISO booted in UEFI mode:

```bash
nix-shell -p git python3 cryptsetup lvm2 gptfdisk dosfstools e2fsprogs util-linux
# Run the command for the machine being installed:
sudo ./setup.sh clean-install --host yoga-amd --profile laptop --model yoga-14akp10 --layout encrypted
sudo ./setup.sh clean-install --host yoga-intel --profile laptop --model yoga-14irl8 --layout encrypted
```

Add `--dry-run` to review without writing files, collecting a passphrase, or
changing storage. The model is normally detected automatically; `--model` makes
that selection explicit and rejects a conflicting CPU/GPU. Optional bundles
and SSH start disabled. The supplied templates contain no disk UUIDs. Setup
creates the named host and hardware file on the target; these host names are
not buildable configurations until that step completes.

Fresh Yoga installations default to encryption. `--layout plain` explicitly
selects the old unencrypted layout and disables Aurora hibernation. `configure`
on a running installation never encrypts or repartitions it. Moving an existing
plain installation to this layout requires a backup and fresh install.

## Storage and resume

The encrypted installer creates a 1 GiB FAT EFI partition and a LUKS2 container.
Inside the container, LVM holds ext4 root and persistent swap. Swap is rounded-up
RAM plus 2 GiB; `--swap-gib 34` can choose a larger size. Preflight requires
another 32 GiB for root plus EFI/metadata allowance. It refuses an existing
`aurora` mapper or a colliding `aurora_<host>` volume group.

The passphrase is collected before erasure and supplied through stdin to
cryptsetup. It is not stored in the repository, command arguments, or logs.
The EFI partition remains unencrypted. No TPM unlock or Secure Boot enrollment
is configured. Expect a LUKS passphrase prompt during boot and resume.

Generated `storage.luksUuid` and `storage.swapUuid` identify this machine's
container and persistent swap; never copy them to another machine. The initrd
unlocks LUKS and activates LVM before resume and root mounting. Zram remains
available with higher swap priority. Do not enable random-key encrypted swap
for hibernation or manually recreate its UUID without updating the host.

On installation failure, cleanup only closes mappings and volume groups this
run created. If an unmount fails, storage is left open for recovery instead of
being forcibly removed. The error does not restore erased data. A successfully
installed target stays mounted until reboot.

## Power policy

Power-profiles-daemon remains the profile manager. Balanced is its initial
profile; manual selections are retained. No TLP, automatic CPU boost disabling,
forced ASPM, forced S3, or automatic display refresh-rate reduction is added.
Keep `hardware.kernel: "stable"` first; `"latest"` is an explicit troubleshooting
choice, not a promise of better compatibility. Keep a working boot generation.

Laptop Wi-Fi power saving is enabled. If it causes disconnects, set
`power.wifiPowerSave: false` in that host's JSON. These optional fields can be
merged into existing settings:

```json
"power": {
  "acProfile": "balanced",
  "batteryProfile": "power-saver",
  "chargeConservation": "unchanged",
  "hibernateDelay": "2h"
}
```

Both source-profile fields default to `"unchanged"`. When configured, a single
service responds to power-supply events. A manual profile selection lasts until
the next AC/battery transition. Charge conservation also defaults to unchanged,
so firmware settings are preserved and full charging remains available. Opt in
with `"enabled"`; use `"disabled"` to turn it off explicitly. The helper uses
Lenovo's supported `charge_types` interface, falling back to `conservation_mode`.
It disables exposed rapid charging before conservation. The limit is defined
by firmware; it is not a user-selected 80% threshold. Unsupported hardware is
reported, not given fake controls. For a one-time change:

```bash
sudo aurora-power conservation enabled
sudo aurora-power conservation disabled
```

Locking occurs after ten minutes; displays power off after eleven and restore
on activity. Idle suspend remains disabled. On a hibernation-enabled laptop,
battery lid closure suspends then hibernates after two hours; AC lid closure
suspends; docked lid closure is ignored. Automatic hibernation while on AC is
disabled. Sleep honors inhibitors and locks the session first.

UPower warns at 20%, marks the battery critical at 10%, and acts at 5%. The
configured action is hibernation for hosts with persistent resume storage,
otherwise power-off. UPower uses its supported power-off fallback when logind
cannot hibernate. This is not a guarantee of recovery from a firmware failure
or a battery that shuts down without reporting its level.

## Diagnose and verify on the laptops

```bash
sudo aurora-power doctor
fwupdmgr get-devices
fwupdmgr get-updates
# Apply firmware only after reviewing the offered update:
fwupdmgr update
```

Doctor is read-only and reports CPU driver/EPP, platform profile, firmware,
lockdown, swap/resume configuration, battery energy, RTC wake capability, sleep
logs, and available suspend residency counters. Exit 1 means a hibernation
prerequisite is missing; exit 77 means the environment is unavailable. These
results are capability checks, not proof that suspend or resume works.

Kernel lockdown can prevent hibernation. Encrypting swap does not bypass this
restriction, and Aurora does not weaken lockdown. Resolve the machine's boot
policy before relying on hibernation. A system with unsupported hibernation
should use `power.hibernate: false` while being diagnosed. Do not force `deep`
when the firmware only provides s2idle.

After saving work, test `systemctl suspend`, then `systemctl hibernate`, and
finally `systemctl suspend-then-hibernate`. Verify the same running session
returns after hibernation. Repeat at least three times on battery and AC,
with and without a dock. Check Wi-Fi, Bluetooth, speakers, microphone, keyboard,
touchpad, touchscreen, pen, and display scaling after every cycle. Test lid
behavior and overnight battery drain separately. Suspend-then-hibernate also
requires working firmware/RTC wake support.

Measure matched workloads and brightness, with no charging during the interval:

```bash
aurora-power snapshot > before.json
# Run the workload, or perform a controlled sleep interval.
aurora-power snapshot > after.json
aurora-power compare before.json after.json
```

The comparison uses battery energy in Wh and wall-clock elapsed time. It does
not infer an improvement from CPU utilization or configuration settings. Missing
energy counters are reported as skipped. Endpoints cannot detect intermediate
charging; control and record that condition yourself.

## Proxmox desktop guest

Create an x86-64 VM with Q35, OVMF (EFI), VirtIO SCSI storage, VirtIO network,
and VirtIO GPU display. Start with 4 vCPUs, 8 GiB RAM and a 64 GiB disk. Enable
the QEMU Guest Agent option in Proxmox. GPU passthrough and nested virtualisation
are separate configurations, not prerequisites.

Boot the NixOS ISO, then run:

```bash
sudo ./setup.sh clean-install --host vm --profile vm
# Or, on an already installed NixOS guest:
./setup.sh configure --host vm --profile vm
```

The guest gets the existing Hyprland/Quickshell desktop and QEMU guest-agent.
Log in at the graphical console; tty1 starts Hyprland. Serial/other TTY consoles
remain available for recovery. New guests do not enable password SSH.

`vm.graphics` defaults to `"software"`, using Mesa llvmpipe for a VirtIO display
without host 3D acceleration. Choose `"accelerated"` only after configuring a
compatible accelerated virtual GPU. Software rendering consumes guest CPU and
will not match native GPU performance. The rendering environment is guest-only.
SPICE clipboard support under Wayland is not assumed.

Guest profiles disable physical CPU microcode updates, firmware management,
laptop power profiles, NPU setup, and hibernation. `features.virtualisation`
means hosting other VMs and remains off unless explicitly selected. Guest
storage defaults to plain ext4; `--layout encrypted` is supported but does not
enable guest hibernation.

## Evidence and limitations

Linux CI evaluates hardware and power assertions, builds Yoga/VM systems, tests
both partitioners, and exercises encrypted root boot plus persistent swap
resume inside a disposable QEMU VM. Its public fixture key is confined to the
test and is never used by installation. A separate graphical guest test checks
Hyprland and Quickshell startup. Neither test certifies a Proxmox deployment or
Lenovo firmware, battery life, or real device resume.

Physical results for both Yoga models, their GPU/NPU acceleration, touchscreen,
pen and suspend/resume remain **unavailable / skipped** until recorded on the
actual devices. AMD inference remains optional and experimental.

References: [Lenovo 14AKP10](https://psref.lenovo.com/syspool/Sys/PDF/Yoga/Yoga_7_2_in_1_14AKP10/Yoga_7_2_in_1_14AKP10_Spec.pdf),
[Lenovo 14IRL8](https://psref.lenovo.com/syspool/Sys/PDF/Yoga/Yoga_7_14IRL8/Yoga_7_14IRL8_Spec.pdf),
[Linux sleep states](https://docs.kernel.org/admin-guide/pm/sleep-states.html),
[kernel lockdown](https://man7.org/linux/man-pages/man7/kernel_lockdown.7.html),
[Lenovo kernel driver](https://github.com/torvalds/linux/blob/v6.18/drivers/platform/x86/lenovo/ideapad-laptop.c).
