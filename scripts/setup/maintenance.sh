# shellcheck shell=bash
M_NIXOS_DIR="$ROOT"
M_FLAKE_TARGET="$ROOT#$HOST"
M_KEEP_GENERATIONS=5
M_ICON_OK="✓"
M_ICON_INFO="ℹ"
M_ICON_CLEAN="✦"
M_ICON_NIX=""
M_ICON_GIT=""
M_ICON_SYSTEM="⚙"
M_ICON_DISK="▣"
M_ICON_TRASH="✕"
M_ICON_CHECK="✓"

# The maintenance dashboard used to carry its own copy of the log and
# framing helpers (m_section, m_info, m_run, m_header, ...). They are
# gone; it now speaks the shared vocabulary defined at the top of the
# file. The M_ICON_* and M_* configuration values above stay, because
# the printf call sites in this section reference the icons directly.

# Safety

m_check_environment() {

    section "Environment"

    if [[ $EUID -eq 0 ]]; then
        error "Do not run this script with sudo."
        echo
        echo "  Run it as your normal user:"
        echo
        echo "    ./setup.sh maintain"
        echo
        exit 1
    fi

    if [[ ! -d "$M_NIXOS_DIR" ]]; then
        error "NixOS directory not found:"
        echo "    $M_NIXOS_DIR"
        exit 1
    fi

    if ! command -v nix >/dev/null 2>&1; then
        error "Nix command not found."
        exit 1
    fi

    if ! command -v nixos-rebuild >/dev/null 2>&1; then
        error "nixos-rebuild not found."
        exit 1
    fi

    if ! command -v git >/dev/null 2>&1; then
        error "git command not found."
        exit 1
    fi

    success "NixOS environment detected."
    info "Configuration: $M_NIXOS_DIR"
    info "Flake target:  $M_FLAKE_TARGET"
}

# Git

m_check_git() {

    section "${M_ICON_GIT} Git status"

    cd "$M_NIXOS_DIR" || return 1

    if [[ -n "$(git status --porcelain)" ]]; then

        warning "Working tree contains uncommitted changes."

        echo
        git status --short

        echo
        printf '%b\n' "${YELLOW}  This is allowed, but review your changes before continuing.${RESET}"

    else

        success "Working tree is clean."

    fi
}

# Flake check

m_check_flake() {

    section "${M_ICON_NIX} Flake validation"

    run_cmd "nix flake check"

    if nix flake check; then
        success "Flake check passed."
    else
        error "Flake check failed."
        return 1
    fi
}

# Dry build

m_dry_build() {

    section "${M_ICON_CHECK} NixOS configuration"

    run_cmd "nixos-rebuild dry-build"

    if sudo nixos-rebuild dry-build --flake "$M_FLAKE_TARGET"; then
        success "Dry-build passed."
        return 0
    fi

    error "Dry-build failed."
    return 1
}

# Generation information

m_get_generations() {

    sudo nix-env \
        --list-generations \
        --profile /nix/var/nix/profiles/system
}

m_get_current_generation() {

    m_get_generations |
        awk '/\(current\)/ {print $1}'
}

# Generation dashboard

m_generation_status() {

    section "${M_ICON_SYSTEM} System generations"

    local output
    local current
    local total

    output="$(m_get_generations)"
    current="$(echo "$output" | awk '/\(current\)/ {print $1}')"
    total="$(echo "$output" | awk 'NF {count++} END {print count+0}')"

    echo
    printf '  %b Current generation: %b%s%b\n' \
        "${GREEN}${M_ICON_OK}${RESET}" \
        "${BOLD}" \
        "$current" \
        "${RESET}"

    printf '  %b Total generations:  %b%s%b\n' \
        "${BLUE}${M_ICON_INFO}${RESET}" \
        "${BOLD}" \
        "$total" \
        "${RESET}"

    printf '  %b Keeping:            %b%s%b\n' \
        "${CYAN}${M_ICON_CLEAN}${RESET}" \
        "${BOLD}" \
        "$M_KEEP_GENERATIONS" \
        "${RESET}"

    echo
}

# Generation cleanup

m_cleanup_generations() {

    section "${M_ICON_CLEAN} Generation cleanup"

    local output
    local current
    local generations
    local total
    local delete_count
    local old_generations

    output="$(m_get_generations)"

    current="$(echo "$output" | awk '/\(current\)/ {print $1}')"

    mapfile -t generations < <(
        echo "$output" |
            awk '{print $1}'
    )

    total="${#generations[@]}"

    if ((total <= M_KEEP_GENERATIONS)); then
        success "Nothing to remove."
        info "Only $total generation(s) exist."
        return
    fi

    delete_count=$((total - M_KEEP_GENERATIONS))

    old_generations=(
        "${generations[@]:0:$delete_count}"
    )

    echo
    warning "Old generations selected for removal:"
    echo

    for generation in "${old_generations[@]}"; do
        printf '    %b generation %s%b\n' \
            "${RED}${M_ICON_TRASH}${RESET}" \
            "$generation" \
            "${RESET}"
    done

    echo
    info "Current generation $current is protected."
    info "Newest $M_KEEP_GENERATIONS generations will remain."

    if confirm "Remove these generations?"; then

        run_cmd "Removing old generations..."

        sudo nix-env \
            --profile /nix/var/nix/profiles/system \
            --delete-generations \
            "${old_generations[@]}"

        success "Old generations removed."

    else

        warning "Generation cleanup cancelled."

    fi
}

# Garbage collection

m_garbage_collect() {

    section "${M_ICON_TRASH} Garbage collection"

    info "Scanning for unreachable store paths..."

    local dead_paths
    dead_paths="$(
        nix-store --gc --print-dead 2>/dev/null || true
    )"

    if [[ -z "$dead_paths" ]]; then

        success "No unreachable store paths found."
        return

    fi

    local count
    count="$(echo "$dead_paths" | wc -l)"

    info "Approximately $count unreachable paths found."

    if confirm "Run garbage collection?"; then

        run_cmd "Running Nix garbage collection..."

        sudo nix-collect-garbage

        success "Garbage collection completed."

    else

        warning "Garbage collection cancelled."

    fi
}

# Store optimization

m_optimize_store() {

    section "${M_ICON_NIX} Store optimization"

    if confirm "Optimize the Nix store?"; then

        run_cmd "Optimizing Nix store..."

        sudo nix-store --optimise

        success "Nix store optimization completed."

    else

        warning "Store optimization skipped."

    fi
}

# Store verification

m_verify_store() {

    section "${M_ICON_CHECK} Store verification"

    warning "This can take a while."

    if ! confirm "Verify Nix store contents?"; then
        warning "Store verification skipped."
        return
    fi

    # The one operation in this script that a spinner genuinely improves:
    # it runs for minutes, prints nothing at all while it succeeds, and
    # prints the corrupt paths when it does not -- which spinner replays to
    # stderr. The other long operations here (nix-collect-garbage,
    # --optimise, flake check, dry-build) each end on a summary line worth
    # reading, so they stay streaming.
    if spinner "Verifying Nix store" sudo nix-store --verify --check-contents; then
        success "Nix store verification passed."
    else
        error "Nix store verification reported problems."
    fi
}

# Systemd

m_systemd_health() {

    section "${M_ICON_SYSTEM} Systemd health"

    local failed

    failed="$(
        systemctl \
            --failed \
            --no-legend \
            --no-pager ||
            true
    )"

    if [[ -z "$failed" ]]; then

        success "No failed systemd units."

    else

        warning "Failed systemd units detected:"
        echo
        systemctl --failed --no-pager

    fi
}

# Disk usage

m_store_usage() {

    section "${M_ICON_DISK} Nix store"

    local usage

    usage="$(du -sh /nix/store 2>/dev/null | awk '{print $1}')"

    echo
    printf '  %b Nix store size: %b%s%b\n' \
        "${CYAN}${M_ICON_DISK}${RESET}" \
        "${BOLD}" \
        "$usage" \
        "${RESET}"

    echo

    df -h /nix
}

# System overview

m_system_overview() {

    section "${M_ICON_SYSTEM} System overview"

    local hostname
    local kernel
    local nix_version
    local uptime

    hostname="$(hostname)"
    kernel="$(uname -r)"
    nix_version="$(nix --version)"
    uptime="$(uptime_human)"

    printf '  %b Host:       %s\n' "${CYAN}${M_ICON_SYSTEM}${RESET}" "$hostname"
    printf '  %b Kernel:     %s\n' "${BLUE}${M_ICON_INFO}${RESET}" "$kernel"
    printf '  %b Nix:        %s\n' "${MAGENTA}${M_ICON_NIX}${RESET}" "$nix_version"
    printf '  %b Uptime:     %s\n' "${GREEN}${M_ICON_OK}${RESET}" "$uptime"
}

# Full maintenance is implemented by m_maintenance_dashboard above.
m_maintenance_dashboard() {
    clear_screen
    panel "NixOS Maintenance" "v$VERSION" "System maintenance dashboard"
    echo
    m_check_environment
    m_check_git
    echo
    if ! m_check_flake; then
        error "Maintenance stopped."
        pause
        return
    fi
    if ! m_dry_build; then
        error "Maintenance stopped."
        echo
        echo "Fix the NixOS configuration before cleanup."
        pause
        return
    fi
    m_generation_status
    m_cleanup_generations
    m_garbage_collect
    m_optimize_store
    m_verify_store
    m_systemd_health
    m_store_usage
    echo
    section "Final configuration check"
    run_cmd "Running final dry-build..."
    if sudo nixos-rebuild dry-build --flake "$M_FLAKE_TARGET"; then
        success "Final dry-build passed."
    else
        error "Final dry-build failed."
    fi
    echo
    hr
    echo
    printf '%b\n' "${GREEN}${BOLD}  ${M_ICON_OK} Maintenance complete${RESET}"
    echo
    printf '  %b Current generation: %s\n' "${GREEN}${M_ICON_SYSTEM}${RESET}" "$(m_get_current_generation)"
    printf '  %b Generations kept:  %s\n' "${CYAN}${M_ICON_CLEAN}${RESET}" "$M_KEEP_GENERATIONS"
    echo
    printf '%b\n' "${DIM}  Your NixOS configuration was not modified.${RESET}"
    echo
    pause
}
