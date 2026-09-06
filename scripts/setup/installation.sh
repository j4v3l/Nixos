CI_TARGET="/mnt"
CI_ESP_LABEL="EFI"
CI_ROOT_LABEL="nixos"
CI_ESP_SGDISK_SIZE="+1G"
CI_REPO_URL="https://github.com/j4v3l/NixOS.git"
CI_DRY_RUN=0

CI_DISK=""
CI_ESP=""
CI_ROOT_PART=""
CI_USER=""
CI_DEST=""

# Resolved by ci_preflight, because these tools are not named the same way in
# every environment and the ISO does not guarantee one particular partitioner.
CI_PARTITIONER=""
CI_MKFS_FAT=""

# Set while install-time swap is active, so it can be torn down on any exit.
CI_SWAPFILE=""

# Absolute path to the installed system closure built in the target store.
CI_SYSTEM_PATH=""

# The ISO does not necessarily enable flakes, and this repository only turns
# them on for the system it installs.
CI_NIX_FLAGS=(--extra-experimental-features "nix-command flakes")

# A dry run must be reviewable on any machine, including one with no
# partitioning or installation tools at all, so a missing tool is reported
# rather than fatal.
ci_need_cmd() {
    if [[ "$CI_DRY_RUN" -eq 1 ]]; then
        command -v "$1" >/dev/null 2>&1 ||
            warning "absent here, required for a real run: $1"
        return 0
    fi
    need_cmd "$1"
}

ci_run() {
    if [[ "$CI_DRY_RUN" -eq 1 ]]; then
        printf '  %b%s%b %b[dry-run]%b %s\n' \
            "$MAGENTA" "$ICON_ARROW" "$RESET" "$DIM" "$RESET" "$*"
        return 0
    fi
    run_cmd "$*"
    "$@"
}

# Everything this needs, checked in one pass before anything is touched.
#
# Discovering a missing mkfs after the partition table has already been
# written is the worst possible moment to find out, so the whole toolchain is
# resolved up front. Where a tool has more than one common name, or where two
# different tools would do, the alternative is accepted rather than demanded,
# so a stock installer ISO needs nothing installed.
# Can we reach the binary cache?
#
# Checked explicitly because the alternative is discovering it as a wall of nix
# download errors after the disk has already been repartitioned.
ci_check_network() {
    local ok=0

    if command -v curl >/dev/null 2>&1; then
        curl -fsS --max-time 12 -o /dev/null https://cache.nixos.org/nix-cache-info 2>/dev/null && ok=1
    elif command -v ping >/dev/null 2>&1; then
        ping -c1 -W3 cache.nixos.org >/dev/null 2>&1 && ok=1
    else
        v_info "neither curl nor ping available; connectivity not tested"
        return 0
    fi

    if [[ "$ok" -eq 1 ]]; then
        v_ok "cache.nixos.org reachable"
        return 0
    fi

    v_fail "cannot reach cache.nixos.org"
    warning "This install downloads almost everything; it cannot run offline."
    info "Wired is usually automatic. If not:  sudo dhcpcd"
    info "Wi-Fi, easiest:  nmcli device wifi connect <SSID> password <password>"
    info "Wi-Fi, fallback: sudo systemctl start wpa_supplicant"
    info "                 then wpa_cli -i <iface>"
    return 1
}

ci_preflight() {
    section "Preflight"

    local -a missing=()
    local c

    for c in python3 git lsblk findmnt blkid wipefs mount umount mountpoint awk sed grep chown stat; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done

    for c in nix nixos-generate-config nixos-install nixos-enter; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done

    # Either partitioner is fine.
    if command -v sgdisk >/dev/null 2>&1; then
        CI_PARTITIONER="sgdisk"
    elif command -v parted >/dev/null 2>&1; then
        CI_PARTITIONER="parted"
    else
        missing+=("sgdisk or parted")
    fi

    # dosfstools has used both names.
    if command -v mkfs.fat >/dev/null 2>&1; then
        CI_MKFS_FAT="mkfs.fat"
    elif command -v mkfs.vfat >/dev/null 2>&1; then
        CI_MKFS_FAT="mkfs.vfat"
    else
        missing+=("mkfs.fat or mkfs.vfat")
    fi

    command -v mkfs.ext4 >/dev/null 2>&1 || missing+=("mkfs.ext4")

    if [[ "${#missing[@]}" -gt 0 ]]; then
        for c in "${missing[@]}"; do error "missing: $c"; done
        echo
        error "Required installation tools are missing."
        info "If one really is absent, borrow it without installing anything:"
        info "  nix-shell -p python3 git gptfdisk dosfstools e2fsprogs efibootmgr util-linux"

        if [[ "$CI_DRY_RUN" -eq 1 ]]; then
            CI_PARTITIONER="${CI_PARTITIONER:-sgdisk}"
            CI_MKFS_FAT="${CI_MKFS_FAT:-mkfs.fat}"
            warning "Dry run continues so the plan can still be reviewed."
            return 0
        fi
        return 1
    fi

    v_ok "partitioner: $CI_PARTITIONER"
    v_ok "fat filesystem tool: $CI_MKFS_FAT"

    # Advisory here. ci_handle_stale_efi treats a missing efibootmgr as a
    # verification failure, which is where it actually matters.
    if command -v efibootmgr >/dev/null 2>&1; then
        v_ok "efibootmgr present"
    else
        v_info "efibootmgr absent; stale UEFI entries could not be cleaned"
    fi

    if command -v git >/dev/null 2>&1; then
        v_ok "git present"
    else
        v_info "git absent; the repository must already be on disk"
    fi

    # Reported rather than gated. The writable half of the ISO's /nix/store is a
    # tmpfs in RAM, so this number is what the build has to fit in until swap is
    # added on the target after mounting.
    local ram_kb
    ram_kb="$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || printf 0)"
    if [[ "$ram_kb" -gt 0 ]]; then
        v_info "RAM $((ram_kb / 1024 / 1024)) GiB; the ISO store is RAM-backed until swap is added"
    fi

    if ! ci_check_network; then
        [[ "$CI_DRY_RUN" -eq 1 ]] && {
            warning "Dry run continues anyway."
            return 0
        }
        return 1
    fi

    success "Toolchain complete; nothing needs installing."
}

# Is this the NixOS installation ISO?
#
# This used to accept any overlay, tmpfs or squashfs root, which was wrong: a
# container has an overlay root too, so `install` inside one would have decided
# it was in an installer and offered to partition a disk. Testing caught it.
#
# Now it looks only for markers the ISO actually brings with it.
# VARIANT_ID=installer is set by the installation-CD module itself and is the
# most direct evidence; /iso and the read-only store are its own mounts.
ci_is_live_installer() {
    grep -qsE '^VARIANT_ID="?installer"?' /etc/os-release && return 0
    [[ -d /iso ]] && return 0
    findmnt -no TARGET /nix/.ro-store >/dev/null 2>&1 && return 0
    return 1
}

ci_require_live() {
    command -v nixos-install >/dev/null 2>&1 ||
        die "nixos-install not found. Run this from the NixOS installer ISO."

    ci_is_live_installer && return 0

    error "This is not the NixOS installer environment."
    error "No VARIANT_ID=installer, no /iso, no read-only store mount."
    die "Refusing to partition a disk from anything but the installer ISO."
}

ci_disk_desc() {
    lsblk -dnpo SIZE,MODEL,TRAN "$1" 2>/dev/null |
        sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//' || true
}

# nvme0n1 -> nvme0n1p1, sda -> sda1
ci_part_path() {
    if [[ "$1" =~ [0-9]$ ]]; then printf '%sp%s\n' "$1" "$2"; else printf '%s%s\n' "$1" "$2"; fi
}

# Disks the live environment itself came from. Never candidates.
ci_installer_disks() {
    local src pk
    {
        findmnt -no SOURCE /iso 2>/dev/null || true
        findmnt -no SOURCE /nix/.ro-store 2>/dev/null || true
        lsblk -rno NAME,FSTYPE,LABEL 2>/dev/null |
            awk '$2=="iso9660" || $3 ~ /^NIXOS_ISO/ {print "/dev/"$1}' || true
    } | while read -r src; do
        [[ "$src" == /dev/* ]] || continue
        pk="$(lsblk -no PKNAME "$src" 2>/dev/null | head -n1)"
        if [[ -n "$pk" ]]; then printf '/dev/%s\n' "$pk"; else printf '%s\n' "$src"; fi
    done | sort -u
}

ci_candidate_disks() {
    local protected dev rm
    protected=" $(ci_installer_disks | tr '\n' ' ') "

    lsblk -dprno NAME,TYPE,RM 2>/dev/null |
        awk '$2=="disk"{print $1" "$3}' |
        while read -r dev rm; do
            case "$protected" in *" $dev "*) continue ;; esac
            printf '%s %s\n' "$dev" "$rm"
        done
}

# Every probe here is advisory and must never abort the run under set -e.
# Failing to describe the disks is reported, then handled by
# ci_select_target_disk, which is the function allowed to refuse.
ci_show_disks() {
    section "Block devices"

    if ! lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS,MODEL,TRAN 2>/dev/null &&
        ! lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT,MODEL,TRAN 2>/dev/null &&
        ! lsblk 2>/dev/null; then
        warning "lsblk could not enumerate block devices here."
    fi

    echo
    local dev
    while read -r dev; do
        [[ -n "$dev" ]] && info "installer media, protected: $dev  $(ci_disk_desc "$dev")"
    done < <(ci_installer_disks || true)
}

ci_select_target_disk() {
    need_cmd lsblk

    local -a fixed=() removable=()
    local dev rm

    while read -r dev rm; do
        [[ -n "$dev" ]] || continue
        if [[ "$rm" == "1" ]]; then removable+=("$dev"); else fixed+=("$dev"); fi
    done < <(ci_candidate_disks || true)

    local d
    for d in ${removable[@]+"${removable[@]}"}; do
        warning "Ignoring removable disk: $d  $(ci_disk_desc "$d")"
    done

    if [[ "${#fixed[@]}" -eq 0 ]]; then
        error "No fixed disk found that is not the installer media."
        error "Refusing to guess a target."
        return 1
    fi

    if [[ "${#fixed[@]}" -eq 1 ]]; then
        CI_DISK="${fixed[0]}"
        info "Target disk: $CI_DISK  $(ci_disk_desc "$CI_DISK")"
    else
        section "Multiple candidate disks"
        local i=1
        for d in "${fixed[@]}"; do
            printf '   %b%2s%b  %s  %s\n' "$CYAN" "$i" "$RESET" "$d" "$(ci_disk_desc "$d")"
            i=$((i + 1))
        done
        echo
        local pick
        read -r -p "  Select target disk number: " pick
        [[ "$pick" =~ ^[0-9]+$ ]] || {
            error "Not a number."
            return 1
        }
        ((pick >= 1 && pick <= ${#fixed[@]})) || {
            error "Out of range."
            return 1
        }
        CI_DISK="${fixed[$((pick - 1))]}"
    fi

    if [[ ! -b "$CI_DISK" ]]; then
        if [[ "$CI_DRY_RUN" -eq 1 ]]; then
            warning "$CI_DISK is not a block device here; continuing because this is a dry run."
        else
            error "Not a block device: $CI_DISK"
            return 1
        fi
    fi

    CI_ESP="$(ci_part_path "$CI_DISK" 1)"
    CI_ROOT_PART="$(ci_part_path "$CI_DISK" 2)"
}

ci_confirm_destroy() {
    echo
    hr
    warning "EVERY PARTITION ON $CI_DISK WILL BE ERASED."
    echo
    printf '  Disk   : %s  %s\n' "$CI_DISK" "$(ci_disk_desc "$CI_DISK")"
    printf '  Layout : %-18s 1 GiB     fat32  label=%-6s -> %s/boot\n' \
        "$CI_ESP" "$CI_ESP_LABEL" "$CI_TARGET"
    printf '           %-18s remainder ext4   label=%-6s -> %s\n' \
        "$CI_ROOT_PART" "$CI_ROOT_LABEL" "$CI_TARGET"
    hr
    echo

    local answer
    read -r -p "  Type the disk path to confirm ($CI_DISK): " answer
    [[ "$answer" == "$CI_DISK" ]] || {
        warning "Did not match. Aborted."
        return 1
    }

    read -r -p "  Type ERASE to proceed: " answer
    [[ "$answer" == "ERASE" ]] || {
        warning "Aborted."
        return 1
    }
}

ci_release_target() {
    section "Releasing target"

    info "Disabling any active swap on the target."

    while read -r swap_path; do
        [[ -n "$swap_path" ]] || continue

        if [[ "$swap_path" == "$CI_TARGET"/* ]]; then
            info "Disabling swap: $swap_path"
            swapoff "$swap_path" || {
                error "Could not disable target swap: $swap_path"
                return 1
            }
        fi
    done < <(swapon --show=NAME --noheadings 2>/dev/null || true)

    local attempt
    for attempt in 1 2 3; do
        if ! mountpoint -q "$CI_TARGET" 2>/dev/null; then
            break
        fi

        info "Unmounting target tree (attempt $attempt/3)."

        if umount -R "$CI_TARGET"; then
            break
        fi

        sleep 1
    done

    if mountpoint -q "$CI_TARGET" 2>/dev/null; then
        error "Could not fully unmount $CI_TARGET."
        warning "Refusing to repartition a mounted target."
        findmnt -R "$CI_TARGET" || true
        return 1
    fi

    local p
    while read -r p; do
        [[ -n "$p" && "$p" != "$CI_DISK" ]] || continue

        if findmnt -no TARGET --source "$p" >/dev/null 2>&1; then
            if ! umount -R "$p"; then
                error "Could not unmount target partition: $p"
                return 1
            fi
        fi

        if [[ "$(lsblk -no FSTYPE "$p" 2>/dev/null)" == "swap" ]]; then
            if swapon --show=NAME --noheadings 2>/dev/null | grep -Fxq "$p"; then
                if ! swapoff "$p"; then
                    error "Could not disable target swap: $p"
                    return 1
                fi
            fi
        fi
    done < <(lsblk -lnpo NAME "$CI_DISK" 2>/dev/null || true)

    if findmnt -R "$CI_TARGET" >/dev/null 2>&1; then
        error "Target is still mounted after release."
        findmnt -R "$CI_TARGET" || true
        return 1
    fi

    success "Target released."
}

ci_wait_for_part() {
    [[ "$CI_DRY_RUN" -eq 1 ]] && return 0

    local p="$1"
    local i=0

    while [[ ! -b "$p" ]]; do
        i=$((i + 1))

        if ((i > 60)); then
            error "Partition never appeared: $p"
            return 1
        fi

        sleep 0.1
        udevadm settle >/dev/null 2>&1 || true
    done
}

ci_partition() {
    section "Partitioning $CI_DISK"

    ci_run wipefs -a "$CI_DISK"

    # Both branches produce the same result: a 1 MiB-aligned 1 GiB EF00 ESP,
    # then the remainder as Linux filesystem.
    if [[ "$CI_PARTITIONER" == "parted" ]]; then
        ci_run parted -s "$CI_DISK" mklabel gpt
        ci_run parted -s "$CI_DISK" mkpart "$CI_ESP_LABEL" fat32 1MiB 1025MiB
        ci_run parted -s "$CI_DISK" set 1 esp on
        ci_run parted -s "$CI_DISK" mkpart "$CI_ROOT_LABEL" ext4 1025MiB 100%
    else
        ci_run sgdisk --zap-all "$CI_DISK"
        ci_run sgdisk \
            --new="1:0:$CI_ESP_SGDISK_SIZE" --typecode=1:ef00 --change-name=1:"$CI_ESP_LABEL" \
            --new=2:0:0 --typecode=2:8300 --change-name=2:"$CI_ROOT_LABEL" \
            "$CI_DISK"
    fi

    # partprobe ships with parted and udevadm with systemd; neither is worth
    # requiring, because ci_wait_for_part is what actually guarantees the nodes.
    if command -v partprobe >/dev/null 2>&1; then
        ci_run partprobe "$CI_DISK" || true
    fi
    if command -v udevadm >/dev/null 2>&1; then
        ci_run udevadm settle || true
    fi

    ci_wait_for_part "$CI_ESP" || return 1
    ci_wait_for_part "$CI_ROOT_PART" || return 1

    success "GPT written by $CI_PARTITIONER: 1 GiB ESP plus ext4 root."
}

ci_format() {
    section "Formatting"

    ci_run "$CI_MKFS_FAT" -F32 -n "$CI_ESP_LABEL" "$CI_ESP" ||
        {
            error "Failed to format EFI partition: $CI_ESP"
            return 1
        }

    ci_run mkfs.ext4 -F -L "$CI_ROOT_LABEL" "$CI_ROOT_PART" ||
        {
            error "Failed to format root partition: $CI_ROOT_PART"
            return 1
        }

    if [[ "$CI_DRY_RUN" -eq 0 ]]; then
        [[ "$(blkid -s TYPE -o value "$CI_ESP" 2>/dev/null)" == "vfat" ]] ||
            {
                error "EFI partition is not vfat after formatting."
                return 1
            }

        [[ "$(blkid -s TYPE -o value "$CI_ROOT_PART" 2>/dev/null)" == "ext4" ]] ||
            {
                error "Root partition is not ext4 after formatting."
                return 1
            }

        [[ "$(blkid -s LABEL -o value "$CI_ESP" 2>/dev/null)" == "$CI_ESP_LABEL" ]] ||
            {
                error "EFI partition label is incorrect after formatting."
                return 1
            }

        [[ "$(blkid -s LABEL -o value "$CI_ROOT_PART" 2>/dev/null)" == "$CI_ROOT_LABEL" ]] ||
            {
                error "Root partition label is incorrect after formatting."
                return 1
            }
    fi

    success "Filesystems created."
}

ci_mount() {
    section "Mounting"

    ci_run mkdir -p "$CI_TARGET"
    ci_run mount "$CI_ROOT_PART" "$CI_TARGET"
    ci_run mkdir -p "$CI_TARGET/boot"
    ci_run mount "$CI_ESP" "$CI_TARGET/boot"

    if [[ "$CI_DRY_RUN" -eq 0 ]]; then
        mountpoint -q "$CI_TARGET" || {
            error "$CI_TARGET is not a mountpoint."
            return 1
        }
        mountpoint -q "$CI_TARGET/boot" || {
            error "$CI_TARGET/boot is not a mountpoint."
            return 1
        }

        [[ "$(findmnt -no FSTYPE "$CI_TARGET")" == "ext4" ]] ||
            {
                error "$CI_TARGET is not ext4."
                return 1
            }
        [[ "$(findmnt -no FSTYPE "$CI_TARGET/boot")" == "vfat" ]] ||
            {
                error "$CI_TARGET/boot is not vfat."
                return 1
            }

        lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS "$CI_DISK" 2>/dev/null || lsblk "$CI_DISK" || true
        df -h "$CI_TARGET" "$CI_TARGET/boot" || true
    fi

    success "Mounted."
}

# Install-time swap and scratch space on the target.
#
# The writable layer of the ISO's /nix/store is a tmpfs, so every path this
# build downloads or produces is held in RAM until nixos-install copies it to
# the target. A closure this size, Hyprland and Quickshell and Neovim and
# Stylix and the font set, is a well known way to run a live installer out of
# memory partway through.
#
# Swap on the freshly mounted target lets that tmpfs spill to disk instead.
# Both the swapfile and the scratch directory exist only for the install and
# are removed afterwards, so hardware-configuration.nix keeps
# swapDevices = [ ] and nothing is left behind.
ci_setup_swap() {
    section "Install-time swap"

    if [[ "$CI_DRY_RUN" -eq 1 ]]; then
        run_cmd "fallocate + mkswap + swapon $CI_TARGET/.setup-swapfile"
        run_cmd "TMPDIR=$CI_TARGET/.setup-tmp"
        info "Both removed again once the install finishes."
        return 0
    fi

    export TMPDIR="$CI_TARGET/.setup-tmp"
    mkdir -p "$TMPDIR"

    local avail_kb size_g
    avail_kb="$(df -Pk "$CI_TARGET" | awk 'NR==2{print $4}')"
    size_g=$((avail_kb / 1024 / 1024 / 4))
    ((size_g > 8)) && size_g=8

    if ((size_g < 2)); then
        v_info "too little free space for install-time swap; continuing without it"
        return 0
    fi

    local f="$CI_TARGET/.setup-swapfile"

    if ! fallocate -l "${size_g}G" "$f" 2>/dev/null; then
        if ! dd if=/dev/zero of="$f" bs=1M count=$((size_g * 1024)) status=none 2>/dev/null; then
            v_info "could not create a swapfile; continuing without it"
            rm -f "$f"
            return 0
        fi
    fi

    chmod 600 "$f"

    if mkswap "$f" >/dev/null 2>&1 && swapon "$f" 2>/dev/null; then
        CI_SWAPFILE="$f"
        success "${size_g} GiB install-time swap active, scratch space on the target."
    else
        v_info "could not enable swap; continuing without it"
        rm -f "$f"
    fi
}

ci_teardown_swap() {
    if [[ -n "$CI_SWAPFILE" ]]; then
        swapoff "$CI_SWAPFILE" 2>/dev/null || true
        rm -f "$CI_SWAPFILE"
        CI_SWAPFILE=""
        info "Install-time swap removed."
    fi

    if [[ -n "${TMPDIR:-}" && "$TMPDIR" == "$CI_TARGET/.setup-tmp" ]]; then
        rm -rf "$TMPDIR" 2>/dev/null || true
        unset TMPDIR
    fi
}

ci_place_repo() {
    section "Repository"

    CI_DEST="$CI_TARGET/home/$CI_USER/NixOS"
    ci_run mkdir -p "$CI_DEST"

    if [[ -d "$ROOT/.git" ]]; then
        info "Copying this checkout, preserving history and uncommitted work."
        ci_run cp -a "$ROOT/." "$CI_DEST/"
    else
        ci_need_cmd git
        info "Cloning $CI_REPO_URL"
        ci_run git clone "$CI_REPO_URL" "$CI_DEST"
    fi

    if [[ "$CI_DRY_RUN" -eq 0 ]]; then
        [[ -f "$CI_DEST/flake.nix" ]] || {
            error "No flake.nix at $CI_DEST"
            return 1
        }

    fi

    success "Repository at $CI_DEST"
}

# Identity is collected and applied in two separate steps, on purpose.
#
# Collecting happens before anything on disk is touched, so every question is
# answered before the destructive part begins. Applying happens after the
# repository has been placed, because the file that must be edited is the copy
# inside the target, not the one on the USB.
#
# They were one step before, which was a bug: the destination path is derived
# from the username, so changing the username at the prompt left the
# repository under the old name while ownership was fixed on the new one.

ci_collect_identity() {
    section "Host settings"
    host_collect_settings --redetect
    CI_USER="$(printf '%s' "$HOST_SETTINGS" | python3 -c 'import json,sys; print(json.load(sys.stdin)["identity"]["username"])')"
    CI_DEST="$CI_TARGET/home/$CI_USER/NixOS"
    confirm "Use these settings for $HOST?" || return 1
}

ci_apply_identity() {
    if [[ "$CI_DRY_RUN" -eq 1 ]]; then
        info "Would write hosts/$HOST/settings.json and default.nix at $CI_DEST"
        return 0
    fi
    printf '%s' "$HOST_SETTINGS" | python3 "$ROOT/scripts/host-config.py" apply --root "$CI_DEST" --host "$HOST"
}

ci_generate_hardware() {
    ci_need_cmd nixos-generate-config
    section "Hardware configuration for the target"

    local dest="$CI_DEST/hosts/$HOST/hardware-configuration.nix"

    if [[ "$CI_DRY_RUN" -eq 1 ]]; then
        run_cmd "nixos-generate-config --root $CI_TARGET --show-hardware-config > $dest"
        info "The --root flag is what makes this describe the target rather than the ISO."
        return 0
    fi

    write_hardware_config "$CI_TARGET" "$dest" ||
        {
            error "Hardware generation failed."
            return 1
        }

    host_stage_files "$CI_DEST"

    success "Generated against $CI_TARGET."
}

# Extract one filesystem block from a generated hardware configuration.
ci_fs_block() {
    awk -v key="fileSystems.\"$2\"" '
    index($0, key) { inblk = 1 }
    inblk         { print }
    inblk && /\};/ { inblk = 0 }
  ' "$1"
}

ci_fs_uuid() {
    ci_fs_block "$1" "$2" | sed -nE 's|.*by-uuid/([^"]+)".*|\1|p' | head -n1
}

ci_fs_type() {
    ci_fs_block "$1" "$2" | sed -nE 's|.*fsType[[:space:]]*=[[:space:]]*"([^"]+)".*|\1|p' | head -n1
}

ci_verify_hardware() {
    section "Hardware configuration verification"

    local f="$CI_DEST/hosts/$HOST/hardware-configuration.nix"
    if [[ ! -f "$f" ]]; then
        v_fail "missing $f"
        return 1
    fi
    v_ok "hardware-configuration.nix present"

    local want_root want_boot got_root got_boot
    want_root="$(blkid -s UUID -o value "$CI_ROOT_PART" 2>/dev/null || printf '')"
    want_boot="$(blkid -s UUID -o value "$CI_ESP" 2>/dev/null || printf '')"
    got_root="$(ci_fs_uuid "$f" "/")"
    got_boot="$(ci_fs_uuid "$f" "/boot")"

    if [[ -n "$want_root" && "$got_root" == "$want_root" ]]; then
        v_ok "root UUID matches $CI_ROOT_PART  ($want_root)"
    else
        v_fail "root UUID mismatch: config=${got_root:-none} target=${want_root:-unknown}"
    fi

    if [[ -n "$want_boot" && "$got_boot" == "$want_boot" ]]; then
        v_ok "boot UUID matches $CI_ESP  ($want_boot)"
    else
        v_fail "boot UUID mismatch: config=${got_boot:-none} target=${want_boot:-unknown}"
    fi

    if [[ "$(ci_fs_type "$f" "/")" == "ext4" ]]; then
        v_ok "root fsType is ext4"
    else
        v_fail "root fsType is not ext4"
    fi

    if [[ "$(ci_fs_type "$f" "/boot")" == "vfat" ]]; then
        v_ok "boot fsType is vfat"
    else
        v_fail "boot fsType is not vfat"
    fi

    if grep -q 'hostPlatform = lib.mkDefault "x86_64-linux"' "$f"; then
        v_ok "hostPlatform is x86_64-linux"
    else
        v_fail "hostPlatform is not x86_64-linux"
    fi

    if grep -q '"nvme"' "$f"; then
        v_ok "nvme present in initrd modules"
    else
        v_info "nvme absent from initrd modules; expected only on a non-NVMe target"
    fi
}

ci_validate_flake() {
    ci_need_cmd nix
    section "Flake validation"

    if [[ "$CI_DRY_RUN" -eq 1 ]]; then
        run_cmd "nix flake check --no-build $CI_DEST"
        return 0
    fi

    local cache="$CI_TARGET/.nix-cache"
    local tmp="$CI_TARGET/.nix-tmp"

    mkdir -p "$cache" "$tmp"
    chmod 700 "$cache" "$tmp"

    info "Using target-disk cache: $cache"
    info "Using target-disk temporary space: $tmp"

    XDG_CACHE_HOME="$cache" \
        TMPDIR="$tmp" \
        NIX_CONFIG="experimental-features = nix-command flakes" \
        nix "${CI_NIX_FLAGS[@]}" flake check --no-build "$CI_DEST" ||
        {
            error "Flake check failed."
            return 1
        }

    success "Flake evaluates."
}

ci_prepare_target_store() {
    section "Target Nix store"

    local store="$CI_TARGET/nix/store"

    if [[ "$CI_DRY_RUN" -eq 1 ]]; then
        run_cmd "mkdir -p $CI_TARGET/nix/store $CI_TARGET/nix/var/nix"
        run_cmd "nix --store $CI_TARGET store info"
        info "The system build will use the disk-backed target store."
        return 0
    fi

    mkdir -p "$store" "$CI_TARGET/nix/var/nix"
    chmod 755 "$CI_TARGET/nix" "$store" "$CI_TARGET/nix/var/nix"

    nix "${CI_NIX_FLAGS[@]}" --store "$CI_TARGET" store info >/dev/null || {
        error "Target Nix store is not usable: $CI_TARGET"
        return 1
    }

    success "Target Nix store ready at $store."
}

ci_build_system() {
    section "Build .#$HOST in target store"

    local attr="$CI_DEST#nixosConfigurations.$HOST.config.system.build.toplevel"

    if [[ "$CI_DRY_RUN" -eq 1 ]]; then
        run_cmd "nix --store $CI_TARGET build --no-link --print-out-paths $attr"
        info "The system build will use the disk-backed target store."
        return 0
    fi

    local result

    result="$(
        nix "${CI_NIX_FLAGS[@]}" \
            --store "$CI_TARGET" \
            build \
            --no-link \
            --print-out-paths \
            "$attr"
    )" || {
        error "Build of .#$HOST failed."
        return 1
    }

    result="$(printf '%s\n' "$result" | tail -n1)"

    [[ "$result" == /nix/store/* ]] || {
        error "Build returned an unexpected store path: $result"
        return 1
    }

    [[ -e "$CI_TARGET$result" ]] || {
        error "Built system path does not exist: $result"
        return 1
    }

    CI_SYSTEM_PATH="$result"

    success "System closure built in the target store."
    info "System path: $result"
}

ci_install() {
    ci_need_cmd nixos-install
    section "Installing NixOS"

    if [[ "$CI_DRY_RUN" -eq 1 ]]; then
        run_cmd "nixos-install --root $CI_TARGET --store-path /nix/store/<system-closure> --no-channel-copy"
        info "Installing the already-built closure from the target Nix store."
        return 0
    fi

    [[ -n "$CI_SYSTEM_PATH" ]] || {
        error "No target-store system closure was built."
        return 1
    }

    nix "${CI_NIX_FLAGS[@]}" \
        --store "$CI_TARGET" \
        path-info "$CI_SYSTEM_PATH" >/dev/null || {
        error "System closure is not present in the target Nix store: $CI_SYSTEM_PATH"
        return 1
    }

    info "Installing the already-built closure."
    info "Source: $CI_SYSTEM_PATH"

    run_cmd "nixos-install --root $CI_TARGET --store-path $CI_SYSTEM_PATH --no-channel-copy"

    nixos-install \
        --root "$CI_TARGET" \
        --store-path "$CI_SYSTEM_PATH" \
        --no-channel-copy || {
        error "nixos-install failed."
        return 1
    }

    success "NixOS installed from the target-store closure."
}

ci_cleanup_installer_artifacts() {
    section "Installer cleanup"

    if [[ "$CI_DRY_RUN" -eq 1 ]]; then
        run_cmd "swapoff $CI_TARGET/.setup-swapfile"
        run_cmd "rm -rf $CI_TARGET/.nix-cache $CI_TARGET/.nix-tmp"
        run_cmd "rm -rf $CI_TARGET/.nix-root-cache $CI_TARGET/.setup-tmp"
        run_cmd "rm -f $CI_TARGET/.setup-swapfile $CI_TARGET/.nixos-build-swap"
        run_cmd "rm -rf $CI_TARGET/backup-usb"
        info "Installer-only files will be removed from the target."
        return 0
    fi

    if [[ -e "$CI_TARGET/.setup-swapfile" ]]; then
        swapoff "$CI_TARGET/.setup-swapfile" 2>/dev/null || true
    fi

    if [[ -e "$CI_TARGET/.nixos-build-swap" ]]; then
        swapoff "$CI_TARGET/.nixos-build-swap" 2>/dev/null || true
    fi

    rm -rf \
        "$CI_TARGET/.nix-cache" \
        "$CI_TARGET/.nix-tmp" \
        "$CI_TARGET/.nix-root-cache" \
        "$CI_TARGET/.setup-tmp" \
        "$CI_TARGET/backup-usb"

    rm -f \
        "$CI_TARGET/.setup-swapfile" \
        "$CI_TARGET/.nixos-build-swap"

    success "Installer-only files cleaned up."
}

ci_fix_ownership() {
    section "Ownership"

    if [[ "$CI_DRY_RUN" -eq 1 ]]; then
        run_cmd "chown -R $CI_USER $CI_TARGET/home/$CI_USER"
        return 0
    fi

    local uid gid
    uid="$(nixos-enter --root "$CI_TARGET" -- id -u "$CI_USER" 2>/dev/null | tr -dc '0-9')"
    gid="$(nixos-enter --root "$CI_TARGET" -- id -g "$CI_USER" 2>/dev/null | tr -dc '0-9')"

    if [[ -z "$uid" || -z "$gid" ]]; then
        error "Could not resolve uid/gid for $CI_USER inside the target."
        return 1
    fi

    ci_run chown -R "$uid:$gid" "$CI_TARGET/home/$CI_USER"
    success "$CI_TARGET/home/$CI_USER owned by $CI_USER ($uid:$gid)."
}

ci_set_password() {
    section "Password"
    info "Set interactively inside the installed system."
    info "Never written to Nix, to variables.nix, or to any log."

    if [[ "$CI_DRY_RUN" -eq 1 ]]; then
        run_cmd "nixos-enter --root $CI_TARGET -- passwd $CI_USER"
        return 0
    fi

    local i
    for i in 1 2 3; do
        if nixos-enter --root "$CI_TARGET" -- passwd "$CI_USER"; then
            success "Password set for $CI_USER."
            return 0
        fi
        warning "passwd failed, attempt $i of 3."
    done

    error "Could not set a password for $CI_USER."
    warning "This configuration defines no initialPassword and no display manager,"
    warning "so $CI_USER cannot log in until a password exists."
    warning "After reboot, log in as root and run: passwd $CI_USER"
    return 1
}

ci_verify_bootloader() {
    section "Bootloader"

    local fb="$CI_TARGET/boot/EFI/BOOT/BOOTX64.EFI"

    if [[ -f "$fb" ]]; then
        v_ok "fallback loader present at /boot/EFI/BOOT/BOOTX64.EFI"
    else
        v_fail "missing $fb"
        return 1
    fi

    if grep -qa "systemd-boot" "$fb"; then
        v_fail "fallback loader is systemd-boot, not GRUB"
    elif grep -qa "GRUB" "$fb"; then
        v_ok "fallback loader identifies as GRUB"
    else
        v_fail "cannot identify the fallback loader as GRUB"
    fi

    local cfg="$CI_TARGET/boot/grub/grub.cfg"
    if [[ -f "$cfg" ]]; then
        v_ok "grub.cfg present"
    else
        v_fail "missing $cfg"
        return 1
    fi

    if grep -q "menuentry" "$cfg"; then
        v_ok "grub.cfg has menu entries"
    else
        v_fail "grub.cfg has no menuentry"
    fi

    if grep -q "nixos-system" "$cfg"; then
        v_ok "grub.cfg boots a NixOS system closure"
    else
        v_fail "grub.cfg references no NixOS system closure"
    fi

    local sys
    sys="$(readlink -f "$CI_TARGET/nix/var/nix/profiles/system" 2>/dev/null || printf '')"
    if [[ -n "$sys" ]] && grep -q -- "${sys##*/}" "$cfg"; then
        v_ok "grub.cfg references the installed generation"
    else
        v_info "grub.cfg does not name the current system profile; check the menu on first boot"
    fi

    if [[ -d "$CI_TARGET/boot/EFI/systemd" ]]; then
        v_info "$CI_TARGET/boot/EFI/systemd still exists on the new ESP"
    fi
}

ci_efi_entries() { efibootmgr -v 2>/dev/null || true; }

# Read efibootmgr -v on stdin, print NUM|LABEL for entries that are stale
# NixOS systemd-boot loaders and nothing else.
#
# Deliberately narrow. Only an entry naming systemd-bootx64.efi, or carrying
# the label systemd itself writes, is ever a candidate. Anything belonging to
# another operating system is skipped before matching, so a Windows or distro
# entry cannot be selected even if its path happened to mention systemd.
ci_parse_stale_efi() {
    local line num label
    while IFS= read -r line; do
        [[ "$line" =~ ^Boot([0-9A-Fa-f]{4})\*?[[:space:]]+(.*)$ ]] || continue
        num="${BASH_REMATCH[1]}"
        label="${BASH_REMATCH[2]}"

        case "$label" in
        *Microsoft* | *microsoft* | *Windows* | *windows* | *bootmgfw* | \
            *Ubuntu* | *ubuntu* | *Fedora* | *fedora* | *Debian* | *debian* | \
            *grubx64* | *shimx64* | *opensuse* | *Arch*)
            continue
            ;;
        esac

        if printf '%s' "$label" | grep -qiE 'systemd-bootx64\.efi|Linux Boot Manager'; then
            printf '%s|%s\n' "$num" "$label"
        fi
    done
}

ci_handle_stale_efi() {
    section "UEFI boot entries"

    if [[ ! -d /sys/firmware/efi ]]; then
        v_fail "not booted in UEFI mode; this configuration is UEFI only"
        return 1
    fi

    if ! command -v efibootmgr >/dev/null 2>&1; then
        v_fail "efibootmgr unavailable, cannot inspect UEFI boot entries"
        warning "GRUB here is installed only to the removable fallback path and creates"
        warning "no NVRAM entry, so a leftover entry can still win the boot."
        warning "From any live environment run: efibootmgr -v"
        warning "Then delete stale NixOS entries with: efibootmgr -b <NUM> -B"
        return 1
    fi

    local out
    out="$(ci_efi_entries)"
    printf '%s\n' "$out" | sed 's/^/    /'
    echo

    local -a stale=()
    local line num
    while IFS= read -r line; do
        [[ -n "$line" ]] && stale+=("$line")
    done < <(printf '%s\n' "$out" | ci_parse_stale_efi)

    if [[ "${#stale[@]}" -eq 0 ]]; then
        v_ok "no stale systemd-boot entry in NVRAM"
        return 0
    fi

    warning "These NVRAM entries point at the old systemd-boot loader:"
    for line in "${stale[@]}"; do
        printf '    Boot%s  %s\n' "${line%%|*}" "${line#*|}"
    done
    echo
    info "This repository installs GRUB with efiInstallAsRemovable = true and"
    info "efi.canTouchEfiVariables = false, so GRUB lives only at"
    info "\\EFI\\BOOT\\BOOTX64.EFI and registers no NVRAM entry of its own."
    info "While an entry above exists and is ordered ahead of the fallback, the"
    info "firmware will keep booting the previous installation."
    echo

    if [[ "$CI_DRY_RUN" -eq 1 ]]; then
        run_cmd "efibootmgr -b <NUM> -B   for each entry above"
        return 0
    fi

    if ! confirm "Delete the entries listed above?"; then
        v_fail "stale systemd-boot entry left in place; this machine may boot the old system"
        return 1
    fi

    for line in "${stale[@]}"; do
        num="${line%%|*}"
        ci_run efibootmgr -b "$num" -B || warning "Could not delete Boot$num"
    done

    out="$(ci_efi_entries)"
    if printf '%s' "$out" | ci_parse_stale_efi | grep -q .; then
        v_fail "a systemd-boot entry survived deletion"
        return 1
    fi

    success "Stale entries removed."
    printf '%s\n' "$out" | sed 's/^/    /'
}

ci_final_verify() {
    V_FAILED=0
    section "Final verification"

    mountpoint -q "$CI_TARGET" && v_ok "$CI_TARGET mounted" || v_fail "$CI_TARGET not mounted"
    mountpoint -q "$CI_TARGET/boot" && v_ok "$CI_TARGET/boot mounted" || v_fail "$CI_TARGET/boot not mounted"

    [[ -d "$CI_TARGET/etc" ]] && v_ok "$CI_TARGET/etc exists" || v_fail "$CI_TARGET/etc missing"

    [[ -d "$CI_TARGET/home/$CI_USER" ]] &&
        v_ok "$CI_TARGET/home/$CI_USER exists" || v_fail "$CI_TARGET/home/$CI_USER missing"

    [[ -f "$CI_DEST/flake.nix" ]] &&
        v_ok "repository present at ${CI_DEST#"$CI_TARGET"}" || v_fail "repository missing at $CI_DEST"

    local owner
    owner="$(stat -c '%U:%G' "$CI_TARGET/home/$CI_USER" 2>/dev/null || printf '')"
    if [[ -z "$owner" ]]; then
        v_fail "cannot read ownership of $CI_TARGET/home/$CI_USER"
    elif [[ "$owner" == "root:root" ]]; then
        v_fail "$CI_TARGET/home/$CI_USER is still root:root"
    else
        v_ok "home ownership is $owner"
    fi

    # Each group records its own failures into V_FAILED. None may abort the
    # aggregate, otherwise a single early failure hides every later check and
    # the verdict never prints.
    ci_verify_hardware || true
    ci_verify_bootloader || true
    ci_handle_stale_efi || true

    echo
    if [[ "$V_FAILED" -eq 0 ]]; then
        verdict "$GREEN" "$ICON_OK" "Installation verified"
        return 0
    fi

    verdict "$RED" "$ICON_FAIL" "Installation NOT verified"
    error "Do not reboot expecting the new configuration until the failures above are resolved."
    return 1
}

ci_on_error() {
    echo
    ci_teardown_swap || true
    error "Clean installation stopped at line $1."
    warning "The target is left mounted at $CI_TARGET so it can be inspected."
    warning "Nothing was rebooted and no bootloader claim has been made."
    info "To retry, re-run: ./setup.sh clean-install"
}

clean_install() {
    CI_DRY_RUN="$SETUP_DRY_RUN"
    [[ "${1:-}" == "--dry-run" || "${1:-}" == "-n" ]] && CI_DRY_RUN=1

    clear_screen
    panel "NixOS Clean Installation" "v$VERSION" \
        "Flake target : .#$HOST" \
        "Repository   : the git checkout, never /etc/nixos" \
        "Bootloader   : GRUB at \\EFI\\BOOT\\BOOTX64.EFI"
    echo

    if [[ "$CI_DRY_RUN" -eq 1 ]]; then
        warning "Dry run. Detection and planning only; nothing is written."
    else
        ci_require_live

        # The graphical ISO logs in as an unprivileged user, so this is a normal
        # thing to hit rather than a mistake. Say what to do about it.
        if [[ "$(id -u)" -ne 0 ]]; then
            error "A clean installation has to run as root."
            info "Re-run it as:  sudo ./setup.sh"
            die "Not running as root."
        fi

        trap 'ci_on_error $LINENO' ERR
    fi

    # The installer ISO does not enable flakes, and nixos-install shells out to
    # nix itself, so passing a flag to our own nix calls is not enough. NIX_CONFIG
    # reaches every nix invocation in this process tree, including that one.
    export NIX_CONFIG="experimental-features = nix-command flakes"

    ci_preflight || return 1

    ci_collect_identity || return 1

    ci_show_disks
    ci_select_target_disk || return 1

    if [[ "$CI_DRY_RUN" -eq 0 ]]; then
        ci_confirm_destroy || return 1
        ci_release_target
        ci_partition || return 1
        ci_format || return 1
        ci_mount || return 1
        ci_setup_swap
        ci_place_repo || return 1
    else
        info "Would partition, format and mount $CI_DISK."
        ci_setup_swap
        info "Would place the repository at $CI_DEST."
    fi

    ci_apply_identity || return 1
    ci_generate_hardware || return 1
    ci_prepare_target_store || return 1

    if [[ "$CI_DRY_RUN" -eq 1 ]]; then
        ci_validate_flake
        ci_build_system
        ci_install
        ci_fix_ownership
        ci_set_password
        ci_handle_stale_efi || true

        section "Verification that a real run performs"
        info "target mounts, /etc, home directory, repository presence"
        info "generated UUIDs against the real target partitions"
        info "GRUB fallback binary identity and grub.cfg contents"
        info "stale systemd-boot NVRAM entries"
        info "home ownership is not root:root"
        echo
        verdict "$CYAN" "$ICON_INFO" "Dry run complete, nothing changed"
        return 0
    fi

    ci_verify_hardware
    if [[ "$V_FAILED" -ne 0 ]]; then
        die "Hardware configuration does not describe the target. Stopping before install."
    fi

    ci_validate_flake || return 1
    ci_build_system || return 1
    ci_install || return 1

    # Nothing after this point needs the extra memory, and leaving a swapfile on
    # a system whose configuration declares no swap would be a surprise.
    ci_teardown_swap

    ci_fix_ownership || return 1
    ci_set_password || true

    ci_final_verify || return 1
    ci_cleanup_installer_artifacts || return 1

    echo
    success "Clean installation complete."
    info "Reboot into GRUB, then the newest generation of ${CI_DEST#"$CI_TARGET"}."
    confirm "Reboot now?" && reboot
}

