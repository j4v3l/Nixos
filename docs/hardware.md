# Hardware configuration

Settings live under `hardware` in each host's JSON. Detection reads Linux CPU,
PCI, and chassis information during setup. Saved settings are independent of
the machine evaluating the flake. Inspect `lspci -nn` and `./setup.sh detect`
when detection is incomplete; review choices before installing.

## CPU, graphics, and kernel

| Setting | Values / behavior |
| --- | --- |
| `formFactor` | `laptop` or `desktop` |
| `cpu` | `intel`, `amd`, or `other`; selects applicable microcode and KVM module |
| `gpus` | Any applicable combination of `intel`, `amd`, `nvidia` |
| `intelMediaDriver` | `modern` (default, intel-media-driver) or explicit `legacy` (intel-vaapi-driver) |
| `graphics32Bit` | Defaults to `true` for 32-bit graphics consumers |
| `kernel` | `stable` (NixOS 26.05 default) or explicit `latest` |
| `npu` | `none`, `intel`, or `amd`; independent of Ollama |

Firmware, Mesa, Vulkan utilities, and Intel VA-API packages follow these
choices. AMD acceleration uses Mesa. An option being enabled does not establish
that a particular codec, compute workload, or GPU generation works.

Keep the default kernel first. For hardware needing a different kernel package
or NVIDIA package, add a Nix override in `hosts/<name>/default.nix`, preserving
its generated hardware import:

```nix
{ lib, pkgs, ... }: {
  imports = [ ./hardware-configuration.nix ];
  boot.kernelPackages = lib.mkForce pkgs.linuxPackages_latest;
}
```

## NVIDIA

Dedicated graphics:

```json
"hardware": {
  "formFactor": "desktop",
  "cpu": "amd",
  "gpus": ["nvidia"],
  "nvidia": { "mode": "dedicated", "open": true, "branch": "stable" }
}
```

PRIME offload on an Intel/NVIDIA laptop:

```json
"hardware": {
  "formFactor": "laptop",
  "cpu": "intel",
  "gpus": ["intel", "nvidia"],
  "nvidia": {
    "mode": "offload", "open": true, "branch": "stable",
    "intelBusId": "PCI:0@0:2:0", "nvidiaBusId": "PCI:1@0:0:0"
  }
}
```

Those bus IDs are examples. Use the actual detected IDs. For an AMD/NVIDIA
hybrid, use `amdgpuBusId` and omit `intelBusId`. PCI IDs in Nix are decimal,
including the optional domain after `@`; `lspci` prints hexadecimal. Setup
converts them. PRIME requires the NVIDIA ID and exactly one matching integrated
GPU ID; dedicated mode requires neither. `nvidia-offload <command>` is installed
only for offload hosts.

Open kernel modules require a supported GPU generation (Turing or newer);
older devices need closed modules and an explicitly supported legacy branch.
For Maxwell, Pascal, or Volta, `open: false` and `branch: "legacy_580"` are
available at this lock. Much older branches may not build against current
kernels. Check the pinned NixOS NVIDIA module and NVIDIA's supported-products
list before choosing a driver. Detection intentionally does not guess a GPU
generation from its vendor ID.

## Intel NPU

Set `cpu: "intel"` and `npu: "intel"`. The native
[NixOS Intel NPU module](https://github.com/NixOS/nixpkgs/blob/5dfba6236110080a54247d6460bc2ff5dda939cc/nixos/modules/hardware/cpu/intel-npu.nix)
provides the driver, firmware, and Level Zero integration. Aurora adds
`intel_vpu`, accelerator-device permissions, and a check:

```bash
ls -l /dev/accel/
aurora-npu-check
```

The check builds a deterministic convolution, explicitly compiles it for
`NPU`, checks the reported execution device, and compares its output with a
CPU reference. It returns 77 when OpenVINO has no NPU device; that is a skipped
test, not a pass. Firmware/BIOS settings and kernel support still matter.

## AMD NPU: experimental

`cpu: "amd"` and `npu: "amd"` enable the kernel's `amdxdna` driver and device
permissions. This alone is driver-level enablement. Older Phoenix/Hawk Point
(PCI `1022:1502`) devices are documented at that level until inference is
verified; they are not treated as Ryzen AI 1.8 inference targets.

The optional runtime targets STX/KRK (`1022:17f0`), following
[AMD's Linux release](https://ryzenai.docs.amd.com/en/latest/linux.html). Its
release set is fixed together:

| JSON archive key | Required original filename |
| --- | --- |
| `xrtBase` | `xrt_202620.2.25.37_24.04-amd64-base.deb` |
| `xrtDev` | `xrt_202620.2.25.37_24.04-amd64-base-dev.deb` |
| `xrtNpu` | `xrt_202620.2.25.37_24.04-amd64-npu.deb` |
| `xdna` | `xrt_plugin.2.25.260102.56.release_24.04-amd64-amdxdna.deb` |
| `ryzenAi` | `ryzen_ai-1.8.0.tgz` |

Obtain those files from AMD after accepting any required agreement. For each:

```bash
nix hash file ./ryzen_ai-1.8.0.tgz
nix-store --add-fixed sha256 ./ryzen_ai-1.8.0.tgz
```

Add each original filename and its actual SRI hash to the host JSON, under
`hardware.amdNpu.archives`, and set `hardware.amdNpu.runtime` to `true`:

```text
amdNpu:
  runtime: true
  archives:
    <archive key>: { name: <exact filename above>, hash: <nix hash file output> }
```

The package uses `requireFile`, so neither gated downloads nor fabricated
hashes are hidden in the build. Nix verifies the locally imported bytes. It
extracts matched XRT/XDNA userspace and firmware, installs bundled Python 3.12
wheels without running the vendor installer, and uses an isolated FHS
environment with pinned Boost 1.74 libraries. It keeps the NixOS kernel module;
the vendor's Ubuntu DKMS package is not installed onto NixOS.

After rebuilding:

```bash
aurora-amd-npu --diagnostics
aurora-npu-check
```

The first runs XRT diagnostics; the second invokes AMD's shipped CNN
`quicktest.py` in a writable temporary directory. Check for the expected STX/KRK
selection and successful test output. Driver enumeration alone is not inference.

**Not hardware tested:** the gated archive layout, bundled Python dependencies,
and compatibility between this release and NixOS's kernel need verification.
Build checks reject missing required payloads. Treat this integration as
experimental until both its package build and CNN test pass on the target.
Do not upgrade individual vendor archives independently.

## Ollama

Enable `features.ai`, then select `ai.backend` explicitly:

| Backend | Requirement |
| --- | --- |
| `cpu` | CPU execution; default for new hosts |
| `cuda` | NVIDIA GPU supported by the packaged CUDA/Ollama release |
| `rocm` | AMD GPU supported by the packaged ROCm/Ollama release |
| `vulkan` | Compatible Vulkan driver and Ollama workload |

CUDA without an NVIDIA profile and ROCm without an AMD profile are rejected.
These checks catch configuration mistakes; they do not certify individual GPU
models. Consult [Ollama's hardware documentation](https://docs.ollama.com/gpu)
and confirm actual execution with `ollama ps` while a model is running. Ollama
listens on localhost. NPU enablement does not change its backend.
