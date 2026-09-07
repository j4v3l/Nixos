#!/usr/bin/env bash
set -uo pipefail
if [[ "$(uname -s)" != Linux || -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
    echo "SKIP: runtime checks require an active NixOS Hyprland session." >&2
    exit 77
fi
failed=0
check() {
    printf '\nChecking: %s\n' "$*"
    "$@" || failed=1
}
errors="$(hyprctl configerrors)" || failed=1
printf '%s\n' "$errors"
[[ -z "$errors" || "$errors" == "ok" ]] || failed=1
check hyprctl monitors
check systemctl --user is-active quickshell.service hypridle.service
check vulkaninfo --summary
check vainfo
check loginctl show-session "${XDG_SESSION_ID:-self}" -p Type -p Active -p LockedHint
if command -v aurora-npu-check >/dev/null; then
    aurora-npu-check
    result=$?
    [[ "$result" -eq 0 || "$result" -eq 77 ]] || failed=1
fi
printf '\nManual checks: hotplug, mixed scaling, launcher placement, lock/unlock, suspend/resume, theme switching.\n'
exit "$failed"
