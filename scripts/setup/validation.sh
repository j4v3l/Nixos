validator_run() {
    "$ROOT/scripts/check.sh"
    flake_check
    nix eval --no-write-lock-file --raw "$ROOT#nixosConfigurations.$HOST.config.system.build.toplevel.drvPath"
    printf '\n'
    if [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]] && command -v hyprctl >/dev/null; then
        hyprctl configerrors
    else
        info "Wayland runtime checks skipped: no active Hyprland session."
    fi
}
