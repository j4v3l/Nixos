#!/usr/bin/env bash
set -euo pipefail
if [[ "$(uname -s)" != Linux || ! -e /run/current-system ]]; then
    echo "SKIP: run measurements on the target NixOS machine." >&2
    exit 77
fi
printf 'Date: %s\nKernel: %s\nGeneration: %s\n' "$(date -Is)" "$(uname -r)" "$(readlink /run/current-system)"
systemd-analyze time
free -h
zramctl
ps -C Hyprland,quickshell,qs,ollama -o pid,comm,%cpu,rss,etime || true
nix path-info --closure-size --human-readable /run/current-system
# Two samples avoid the initial cumulative CPU report.
systemd-cgtop --batch --iterations=2 --delay=1 --depth=2 || true

python3 "$(dirname "$0")/power.py" doctor || true
