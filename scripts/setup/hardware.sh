# shellcheck shell=bash
get_var() {
    python3 "$ROOT/scripts/host-config.py" get --root "$ROOT" --host "$HOST" --key "identity.$1"
}

# installation.sh also calls this with --redetect.
# shellcheck disable=SC2120
host_collect_settings() {
    need_cmd python3
    local -a args=(prepare --root "$ROOT" --host "$HOST" --interactive)
    [[ -n "$PROFILE" ]] && args+=(--profile "$PROFILE")
    [[ -n "${MODEL:-}" ]] && args+=(--model "$MODEL")
    HOST_SETTINGS="$(python3 "$ROOT/scripts/host-config.py" "${args[@]}" "$@")" || return 1
}

host_stage_files() {
    local repo="$1"
    if [[ -d "$repo/.git" ]]; then
        git -C "$repo" -c safe.directory="$repo" add -- \
            "hosts/$HOST/settings.json" "hosts/$HOST/default.nix" "hosts/$HOST/hardware-configuration.nix"
    fi
}

backup_config() {
    local backup
    backup="$ROOT/.setup-backups/$(date +%Y%m%d-%H%M%S)/$HOST"
    mkdir -p "$backup"
    [[ ! -d "$ROOT/hosts/$HOST" ]] || cp -a "$ROOT/hosts/$HOST/." "$backup/"
    success "Backup: $backup"
}

write_hardware_config() {
    local target_root="$1" dest="$2" temporary
    mkdir -p "$(dirname "$dest")"
    temporary="$(mktemp "${dest}.XXXXXX")"
    if [[ -n "$target_root" ]]; then
        nixos-generate-config --root "$target_root" --show-hardware-config >"$temporary" || { rm -f "$temporary"; return 1; }
    else
        # Keep the temporary file owned by the user; only detection needs root.
        # shellcheck disable=SC2024
        sudo nixos-generate-config --show-hardware-config >"$temporary" || { rm -f "$temporary"; return 1; }
    fi
    [[ -s "$temporary" ]] || { rm -f "$temporary"; return 1; }
    mv "$temporary" "$dest"
}

refresh_hardware() {
    need_cmd nixos-generate-config
    if ci_is_live_installer; then
        die "Use clean-install from a live ISO so hardware is generated against the mounted target."
    fi
    if [[ "$SETUP_DRY_RUN" -eq 1 ]]; then
        info "Would regenerate hosts/$HOST/hardware-configuration.nix"
        return
    fi
    [[ -f "$ROOT/hosts/$HOST/settings.json" ]] || die "Configure host $HOST first."
    backup_config
    write_hardware_config "" "$ROOT/hosts/$HOST/hardware-configuration.nix"
    host_stage_files "$ROOT"
}

install_flow() {
    if ci_is_live_installer; then
        clean_install
        return
    fi
    [[ -z "${INSTALL_LAYOUT:-}${INSTALL_SWAP_GIB:-}" ]] || die "Storage flags require clean-install from an installer ISO."
    host_collect_settings || return 1
    if [[ "$SETUP_DRY_RUN" -eq 1 ]]; then
        info "Would write settings and generate hardware for $HOST. Nothing changed."
        return
    fi
    need_cmd nixos-generate-config
    need_cmd git
    confirm "Apply these settings to $HOST?" || return
    backup_config
    printf '%s' "$HOST_SETTINGS" | python3 "$ROOT/scripts/host-config.py" apply --root "$ROOT" --host "$HOST"
    write_hardware_config "" "$ROOT/hosts/$HOST/hardware-configuration.nix"
    host_stage_files "$ROOT"
    printf '%s\n' "$HOST" > "$ROOT/.setup-host"
    flake_check
    dry_build
    if confirm "Switch to $HOST now?"; then
        rebuild
        local username
        username="$(get_var username)"
        if id "$username" >/dev/null 2>&1; then
            sudo passwd "$username"
        fi
    fi
}
