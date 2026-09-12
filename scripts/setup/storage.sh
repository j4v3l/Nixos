# shellcheck shell=bash
CI_LAYOUT=plain
CI_SWAP_GIB=0
CI_LUKS_PART=""
CI_SWAP_DEVICE=""
CI_CRYPT_NAME="aurora"
CI_VG=""
CI_LUKS_OPENED=0
CI_VG_CREATED=0
CI_PERSISTENT_SWAP_ACTIVE=0

ci_storage_plan() {
    local model form ram_kib minimum size_bytes
    model="$(printf '%s' "${HOST_SETTINGS:-}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("hardware",{}).get("model","generic"))')" || return 1
    form="$(printf '%s' "$HOST_SETTINGS" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hardware"]["formFactor"])')" || return 1
    CI_LAYOUT="${INSTALL_LAYOUT:-}"
    if [[ -z "$CI_LAYOUT" ]]; then
        CI_LAYOUT=plain
        [[ "$model" == yoga-* ]] && CI_LAYOUT=encrypted
    fi
    [[ "$CI_LAYOUT" == encrypted ]] || {
        [[ -z "${INSTALL_SWAP_GIB:-}" ]] || { error "--swap-gib requires --layout encrypted"; return 1; }
        return 0
    }
    for tool in cryptsetup pvcreate vgcreate vgchange vgs lvcreate mkswap swapon swapoff blockdev; do
        ci_need_cmd "$tool" || return 1
    done
    CI_VG="aurora_${HOST//-/_}"
    if [[ "$CI_DRY_RUN" -eq 0 ]]; then
        [[ ! -e "/dev/mapper/$CI_CRYPT_NAME" ]] || { error "Mapper $CI_CRYPT_NAME already exists; refusing to reuse it."; return 1; }
        if vgs "$CI_VG" >/dev/null 2>&1; then error "Volume group $CI_VG already exists; refusing to reuse it."; return 1; fi
    fi
    ram_kib="$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || true)"
    if [[ ! "$ram_kib" =~ ^[1-9][0-9]*$ ]]; then
        [[ "$CI_DRY_RUN" -eq 1 ]] || { error "Cannot determine RAM for swap sizing."; return 1; }
        ram_kib=8388608
        warning "Dry-run example uses 8 GiB RAM; a real install measures target RAM."
    fi
    minimum=$(((ram_kib + 1048575) / 1048576 + 2))
    CI_SWAP_GIB="${INSTALL_SWAP_GIB:-$minimum}"
    [[ "$CI_SWAP_GIB" =~ ^[1-9][0-9]{0,5}$ ]] || { error "Invalid swap size."; return 1; }
    ((CI_SWAP_GIB >= minimum)) || { error "Swap must be at least $minimum GiB for this machine."; return 1; }
    if [[ "$CI_DRY_RUN" -eq 0 ]]; then
        size_bytes="$(blockdev --getsize64 "$CI_DISK")" || return 1
        ((size_bytes >= (CI_SWAP_GIB + 34) * 1073741824)) || { error "Disk must hold EFI, $CI_SWAP_GIB GiB swap, and at least 32 GiB root."; return 1; }
    fi
    info "Layout: 1 GiB EFI, LUKS2 containing ext4 root and $CI_SWAP_GIB GiB persistent swap."
    [[ "$form" != laptop ]] || info "Lid on battery: suspend, then hibernate after 2 hours."
}

ci_read_passphrase() {
    [[ "$CI_LAYOUT" == encrypted && "$CI_DRY_RUN" -eq 0 ]] || return 0
    # Never trace secrets, including when the installer was started with bash -x.
    set +x
    local second
    export -n CI_PASSPHRASE 2>/dev/null || true
    IFS= read -r -s -p "LUKS passphrase (at least 8 characters): " CI_PASSPHRASE || return 1
    printf '\n'
    IFS= read -r -s -p "Confirm LUKS passphrase: " second || return 1
    printf '\n'
    if [[ ${#CI_PASSPHRASE} -lt 8 || "$CI_PASSPHRASE" != "$second" ]]; then
        unset CI_PASSPHRASE second
        error "Passphrases must match and contain at least 8 characters."
        return 1
    fi
    unset second
}

ci_encrypt() {
    [[ "$CI_LAYOUT" == encrypted ]] || return 0
    CI_LUKS_PART="$CI_ROOT_PART"
    if [[ "$CI_DRY_RUN" -eq 1 ]]; then
        info "Would create LUKS2, VG $CI_VG, root LV and $CI_SWAP_GIB GiB swap LV."
        return 0
    fi
    [[ -n "${CI_PASSPHRASE:-}" ]] || { error "No encryption passphrase collected; refusing to format."; return 1; }
    printf '%s' "$CI_PASSPHRASE" | cryptsetup luksFormat --type luks2 --batch-mode --key-file - "$CI_LUKS_PART" || return 1
    printf '%s' "$CI_PASSPHRASE" | cryptsetup open --key-file - "$CI_LUKS_PART" "$CI_CRYPT_NAME" || return 1
    CI_LUKS_OPENED=1
    unset CI_PASSPHRASE
    pvcreate "/dev/mapper/$CI_CRYPT_NAME" || return 1
    vgcreate "$CI_VG" "/dev/mapper/$CI_CRYPT_NAME" || return 1
    CI_VG_CREATED=1
    lvcreate --yes -L "${CI_SWAP_GIB}G" -n swap "$CI_VG" || return 1
    lvcreate --yes -l 100%FREE -n root "$CI_VG" || return 1
    CI_ROOT_PART="/dev/$CI_VG/root"
    CI_SWAP_DEVICE="/dev/$CI_VG/swap"
    mkswap "$CI_SWAP_DEVICE" || return 1
    swapon --priority 10 "$CI_SWAP_DEVICE" || return 1
    CI_PERSISTENT_SWAP_ACTIVE=1
}

ci_storage_settings() {
    [[ "$CI_DRY_RUN" -eq 0 ]] || return 0
    local luks="" swap=""
    if [[ "$CI_LAYOUT" == encrypted ]]; then
        luks="$(cryptsetup luksUUID "$CI_LUKS_PART")" || return 1
        swap="$(blkid -s UUID -o value "$CI_SWAP_DEVICE")" || return 1
        [[ -n "$luks" && -n "$swap" ]] || return 1
    fi
    HOST_SETTINGS="$(printf '%s' "$HOST_SETTINGS" | python3 -c '
import json,sys
s=json.load(sys.stdin)
s["storage"]={"layout":sys.argv[1], "luksUuid":sys.argv[2], "swapUuid":sys.argv[3], "swapGiB":int(sys.argv[4])}
s.setdefault("power",{})["hibernate"] = sys.argv[1] == "encrypted" and s["hardware"]["formFactor"] == "laptop"
print(json.dumps(s))' "$CI_LAYOUT" "$luks" "$swap" "$CI_SWAP_GIB")" || return 1
}

ci_storage_verify() {
    [[ "$CI_LAYOUT" == encrypted ]] || return 0
    local file="$CI_DEST/hosts/$HOST/hardware-configuration.nix" luks swap configured_luks configured_swap
    luks="$(cryptsetup luksUUID "$CI_LUKS_PART")" || return 1
    swap="$(blkid -s UUID -o value "$CI_SWAP_DEVICE")" || return 1
    [[ -n "$luks" && -n "$swap" ]] || { v_fail "Missing encrypted storage UUID"; return 1; }

    configured_luks="$(printf '%s' "$HOST_SETTINGS" | python3 -c \
        'import json,sys; print(json.load(sys.stdin)["storage"]["luksUuid"])')" || return 1
    configured_swap="$(printf '%s' "$HOST_SETTINGS" | python3 -c \
        'import json,sys; print(json.load(sys.stdin)["storage"]["swapUuid"])')" || return 1

    [[ "$configured_luks" == "$luks" ]] || { v_fail "Host settings LUKS UUID does not match target"; return 1; }
    [[ "$configured_swap" == "$swap" ]] || { v_fail "Host settings swap UUID does not match target"; return 1; }
    grep -Fq "$swap" "$file" || { v_fail "Generated hardware lacks persistent swap UUID"; return 1; }
    v_ok "Encrypted storage and persistent swap UUIDs match target."
}

ci_storage_cleanup() {
    unset CI_PASSPHRASE
    [[ "$CI_DRY_RUN" -eq 0 && "$CI_LUKS_OPENED" -eq 1 ]] || return 0
    if mountpoint -q "$CI_TARGET"; then
        umount -R "$CI_TARGET" || { error "Target still mounted; leaving its encrypted mapping open for recovery."; return 1; }
    fi
    if [[ "$CI_PERSISTENT_SWAP_ACTIVE" -eq 1 ]]; then
        swapoff "$CI_SWAP_DEVICE" || return 1
        CI_PERSISTENT_SWAP_ACTIVE=0
    fi
    if [[ "$CI_VG_CREATED" -eq 1 ]]; then
        vgchange -an "$CI_VG" || return 1
        CI_VG_CREATED=0
    fi
    cryptsetup close "$CI_CRYPT_NAME" || return 1
    CI_LUKS_OPENED=0
}

ci_exit_cleanup() {
    local status="$1"
    unset CI_PASSPHRASE
    if [[ "$status" -ne 0 ]]; then
        ci_teardown_swap || true
        ci_storage_cleanup || true
    fi
}
