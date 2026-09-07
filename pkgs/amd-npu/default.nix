{
  lib,
  pkgs,
  archives,
}:
let
  # This is one vendor release set, not independently upgradable components.
  names = {
    xrtBase = "xrt_202620.2.25.37_24.04-amd64-base.deb";
    xrtDev = "xrt_202620.2.25.37_24.04-amd64-base-dev.deb";
    xrtNpu = "xrt_202620.2.25.37_24.04-amd64-npu.deb";
    xdna = "xrt_plugin.2.25.260102.56.release_24.04-amd64-amdxdna.deb";
    ryzenAi = "ryzen_ai-1.8.0.tgz";
  };
  boost174 = pkgs.runCommand "ryzen-ai-boost-1.74" { nativeBuildInputs = [ pkgs.dpkg ]; } (
    lib.concatStringsSep "\n" (
      lib.mapAttrsToList
        (
          component: hash:
          let
            archive = pkgs.fetchurl {
              url = "https://archive.ubuntu.com/ubuntu/pool/universe/b/boost1.74/libboost-${component}1.74.0_1.74.0+ds1-23.1ubuntu3_amd64.deb";
              inherit hash;
            };
          in
          "dpkg-deb --extract ${archive} \"$out\""
        )
        {
          filesystem = "sha256-uJku44ptDyTb7pQX5YDHQOEAV8iEpeokWtz2l8wkbAg=";
          system = "sha256-99Yx5/EP3sBK3XwItOdB6JFqP1eS0QRC1/cRGcM7NDI=";
        }
    )
  );
  source =
    key:
    assert lib.assertMsg (
      archives ? ${key}
    ) "AMD runtime requires aurora.hardware.amdNpu.archives.${key}; see docs/hardware.md.";
    assert lib.assertMsg (
      archives.${key}.name == names.${key}
    ) "AMD runtime archive ${key} must be ${names.${key}}.";
    pkgs.requireFile {
      name = names.${key};
      sha256 = archives.${key}.hash;
      message = "Obtain ${names.${key}} from AMD Ryzen AI Software 1.8, then add it with nix-store --add-fixed sha256. See docs/hardware.md.";
    };
  vendor =
    pkgs.runCommand "ryzen-ai-1.8-vendor-files"
      {
        nativeBuildInputs = [
          pkgs.dpkg
          pkgs.gnutar
          pkgs.gzip
          pkgs.unzip
        ];
      }
      ''
        mkdir -p "$out" "$out/opt/ryzen-ai"
        ${lib.concatMapStringsSep "\n" (key: "dpkg-deb --extract ${source key} \"$out\"") [
          "xrtBase"
          "xrtDev"
          "xrtNpu"
          "xdna"
        ]}
        tar -xf ${source "ryzenAi"} -C "$out/opt/ryzen-ai"
        # Install packaged wheels without executing the vendor installer or downloading dependencies.
        mkdir -p "$out/opt/ryzen-ai/python"
        while IFS= read -r -d "" wheel; do
          case "$wheel" in
            *cp312*linux*x86_64.whl|*py3-none-any.whl|*py2.py3-none-any.whl)
              unzip -oq "$wheel" -d "$out/opt/ryzen-ai/python" ;;
          esac
        done < <(find "$out/opt/ryzen-ai" -name '*.whl' -print0)
        test -e "$out/opt/xilinx/xrt/setup.sh"
        test -n "$(find "$out/opt/ryzen-ai" -name quicktest.py -print -quit)"
        test -d "$out/opt/ryzen-ai/python/onnxruntime"
      '';
  launcher = pkgs.writeShellScript "aurora-amd-npu" ''
    set -euo pipefail
    if [[ -z "$(lspci -n -d 1022:17f0)" ]]; then
      echo "SKIP: Ryzen AI 1.8 inference is configured for STX/KRK (1022:17f0)." >&2
      exit 77
    fi
    source /opt/xilinx/xrt/setup.sh
    runtime_lib="$(find /opt/ryzen-ai -type d -path '*/onnxruntime/lib' -print -quit)"
    if [[ -z "$runtime_lib" ]]; then
      echo "Ryzen AI archive is missing onnxruntime/lib" >&2
      exit 1
    fi
    export RYZEN_AI_INSTALLATION_PATH="''${runtime_lib%/onnxruntime/lib}"
    export PYTHONPATH="/opt/ryzen-ai/python:''${PYTHONPATH:-}"
    # Resolve bundled shared libraries without adding vendor libraries to the host's global environment.
    vendor_libs="$(find /opt/ryzen-ai /opt/aurora-vendor /opt/aurora-boost -type f -name '*.so*' -printf '%h\n' | sort -u | paste -sd :)"
    export LD_LIBRARY_PATH="$vendor_libs:''${LD_LIBRARY_PATH:-}"
    xrt-smi examine
    if [[ "''${1:-}" == "--diagnostics" ]]; then
      exec xrt-smi validate
    fi
    work="$(mktemp -d)"
    trap 'rm -rf "$work"' EXIT
    quicktest="$(find /opt/ryzen-ai -name quicktest.py -print -quit)"
    cp -r "$(dirname "$quicktest")/." "$work/"
    chmod -R u+w "$work"
    cd "$work"
    python3 quicktest.py | tee "$work/result.log"
    grep -q 'STX/KRK' "$work/result.log"
    grep -q 'Test Finished' "$work/result.log"
  '';
in
{
  inherit vendor names;
  firmware = pkgs.runCommand "amd-npu-firmware-1.8" { } ''
    mkdir -p "$out/lib/firmware"
    for dir in ${vendor}/lib/firmware ${vendor}/usr/lib/firmware; do
      if [ -d "$dir" ]; then cp -r "$dir/." "$out/lib/firmware/"; fi
    done
    test -n "$(find "$out/lib/firmware" -type f -print -quit)"
  '';
  runtime = pkgs.buildFHSEnv {
    name = "aurora-amd-npu";
    targetPkgs = p: [
      p.bash
      p.coreutils
      p.findutils
      p.gnugrep
      p.gnutar
      p.pciutils
      p.stdenv.cc.cc.lib
      p.zlib
      p.openssl
      p.udev
      p.libdrm
      p.util-linux
      p.protobuf
      p.libxml2
      p.ncurses
      p.numactl
      (p.python312.withPackages (ps: [
        ps.numpy
        ps.pyyaml
        ps.protobuf
        ps.packaging
        ps.pillow
        ps.tqdm
        ps.onnx
      ]))
    ];
    extraBwrapArgs = [
      "--ro-bind"
      "${vendor}/opt/xilinx"
      "/opt/xilinx"
      "--ro-bind"
      "${vendor}/opt/ryzen-ai"
      "/opt/ryzen-ai"
      "--ro-bind"
      "${vendor}"
      "/opt/aurora-vendor"
      "--ro-bind"
      "${boost174}"
      "/opt/aurora-boost"
    ];
    runScript = launcher;
    meta = {
      description = "Experimental Ryzen AI 1.8 STX/KRK validation environment";
      platforms = [ "x86_64-linux" ];
      license = lib.licenses.unfree;
    };
  };
}
