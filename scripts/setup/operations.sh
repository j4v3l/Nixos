flake_check() {
    need_cmd nix
    section "Flake validation"
    run_cmd "nix flake check"
    nix flake check --no-build --no-write-lock-file "$ROOT"
    success "Flake check passed."
}

dry_build() {
    need_cmd nix
    section "NixOS dry build"
    run_cmd "nixos-rebuild dry-build --flake .#$HOST"
    sudo nixos-rebuild dry-build --flake "$FLAKE_TARGET"
    success "Dry-build passed."
}

rebuild() {
    need_cmd nix
    flake_check
    section "NixOS rebuild"
    run_cmd "sudo nixos-rebuild switch --flake .#$HOST"
    sudo nixos-rebuild switch --flake "$FLAKE_TARGET"
    success "System rebuilt and switched successfully."
}

update_config() {
    need_cmd git
    need_cmd nix
    section "Update configuration"
    cd "$ROOT"
    if [[ -n "$(git status --porcelain)" ]]; then
        warning "Working tree contains uncommitted changes."
        git status --short
        confirm "Continue with update?" || return
    fi
    run_cmd "git pull --ff-only"
    git pull --ff-only
    run_cmd "nix flake update"
    nix flake update
    flake_check
    if confirm "Rebuild and switch now?"; then
        rebuild
    else
        success "Configuration updated. Rebuild when ready."
    fi
}

rollback() {
    section "Rollback"
    warning "This switches to the previous NixOS generation."
    confirm "Continue with rollback?" || return
    sudo nixos-rebuild switch --rollback
    success "Rollback completed."
}

list_generations() {
    section "NixOS generations"
    sudo nix-env --list-generations --profile /nix/var/nix/profiles/system
}

test_install() {
    python3 -m unittest discover -s "$ROOT/tests" -p 'test_*.py' -v
}

system_overview() {
    section "System overview"
    printf '  Host:    %s\n' "$(hostname)"
    printf '  Kernel:  %s\n' "$(uname -r)"
    printf '  Nix:     %s\n' "$(nix --version 2>/dev/null || echo unavailable)"
    printf '  Uptime:  %s\n' "$(uptime_human)"
}

# Uptime, without `uptime -p`
#
# -p is a procps extension and the uptime on this system rejects it, so
# all three call sites used to fall back to their placeholder string.
# /proc/uptime is always there and needs no external command.

uptime_human() {
    local secs d h m

    if [[ ! -r /proc/uptime ]]; then
        printf 'unknown'
        return
    fi

    read -r secs _ </proc/uptime
    secs="${secs%%.*}"

    d=$((secs / 86400))
    h=$((secs % 86400 / 3600))
    m=$((secs % 3600 / 60))

    if [[ "$d" -gt 0 ]]; then
        printf '%dd %dh' "$d" "$h"
    elif [[ "$h" -gt 0 ]]; then
        printf '%dh %dm' "$h" "$m"
    else
        printf '%dm' "$m"
    fi
}

# One compact "user · kernel · nix · uptime" line for the menu panel.
overview_facts() {
    local nixv
    nixv="$(nix --version 2>/dev/null | grep -o '[0-9.]\+' | head -1)"

    printf '%s · %s · nix %s · up %s' \
        "${USER:-$(whoami 2>/dev/null || echo user)}" \
        "$(uname -r)" \
        "${nixv:-?}" \
        "$(uptime_human)"
}

# One menu row: number, label, dimmed description. The number keeps its
# colour so the eye can jump to it; the label is padded to a fixed
# column so the descriptions line up.
menu_item() {
    local num="$1" label="$2" desc="$3"

    printf '   %b%2s%b  %-22s%b%s%b\n' \
        "$CYAN" "$num" "$RESET" "$label" "$DIM" "$desc" "$RESET"
}

menu() {
    while true; do
        clear_screen

        echo
        panel "NixOS Configuration Manager" "v$VERSION" "$(overview_facts)"
        echo

        if ci_is_live_installer; then
            printf '  %b%bInstaller environment detected. Choose 1 to install NixOS.%b\n\n' \
                "$YELLOW" "$BOLD" "$RESET"
        fi

        # The first three are the whole lifecycle, in the order they are used:
        # install the machine, keep it current, reclaim space. Everything below
        # them is a tool you reach for only when you need it.
        printf '  %b%bMAIN%b\n' "$CYAN" "$BOLD" "$RESET"
        menu_item 1 "Install NixOS" "fresh install, partitions the disk"
        menu_item 2 "Upgrade" "git pull, flake update, rebuild"
        menu_item 3 "Free disk space" "old generations, GC, optimise"

        echo
        printf '  %b%bSYSTEM%b\n' "$CYAN" "$BOLD" "$RESET"
        menu_item 4 "Rebuild / Switch" "validate then switch"
        menu_item 5 "Dry rebuild" "build without switching"
        menu_item 6 "Check flake" "evaluate the flake"
        menu_item 7 "Rollback" "previous generation"
        menu_item 8 "List generations" "system profile history"
        menu_item 9 "Refresh hardware" "regenerate hardware config"
        menu_item 10 "Configure identity" "on an already-installed system"

        echo
        printf '  %b%bCHECKS & MAINTENANCE%b\n' "$CYAN" "$BOLD" "$RESET"
        menu_item 11 "Configuration check" "full validator"
        menu_item 12 "Maintenance dashboard" "guarded full cleanup"
        menu_item 13 "Garbage collection" "reclaim store space"
        menu_item 14 "Optimize store" "deduplicate the store"
        menu_item 15 "Verify store" "check store integrity"
        menu_item 16 "Systemd health" "failed units"
        menu_item 17 "Store usage" "disk footprint"

        echo
        printf '  %b%bINSTALLER TOOLS%b\n' "$CYAN" "$BOLD" "$RESET"
        menu_item 18 "Install dry-run" "plan the install, change nothing"
        menu_item 19 "Verify boot" "re-check an install mounted at /mnt"
        menu_item 20 "Identity preview" "preview the prompts only"

        echo
        menu_item 0 "Exit" ""
        echo

        local choice
        read -r -p "  Select: " choice
        case "$choice" in
        1)
            clean_install
            pause
            ;;
        2)
            update_config
            pause
            ;;
        3)
            free_space
            pause
            ;;

        4)
            rebuild
            pause
            ;;
        5)
            dry_build
            pause
            ;;
        6)
            flake_check
            pause
            ;;
        7)
            rollback
            pause
            ;;
        8)
            list_generations
            pause
            ;;
        9)
            refresh_hardware
            pause
            ;;
        10)
            install_flow
            pause
            ;;

        11)
            validator_run
            pause
            ;;
        12) m_maintenance_dashboard ;;
        13)
            m_garbage_collect
            pause
            ;;
        14)
            m_optimize_store
            pause
            ;;
        15)
            m_verify_store
            pause
            ;;
        16)
            m_systemd_health
            pause
            ;;
        17)
            m_store_usage
            pause
            ;;

        18)
            clean_install --dry-run
            pause
            ;;
        19)
            verify_boot
            pause
            ;;
        20)
            test_install
            pause
            ;;

        0)
            clear_screen
            exit 0
            ;;
        *)
            warning "Invalid option."
            sleep 1
            ;;
        esac
    done
}

usage() {
    cat <<EOF
Aurora NixOS setup
Usage: ./setup.sh <command> [--host NAME] [--profile laptop|desktop] [--dry-run]

configure       Review settings and generate hardware for a running NixOS host
install         Configure a running host, or run clean-install from a live ISO
clean-install   Review settings, partition a selected disk, and install NixOS
rebuild         Evaluate and switch the selected host
check, dry      Evaluate the flake or dry-build the selected host
validate        Run repository checks and evaluate the selected host
hardware        Refresh only the selected host's generated hardware file
detect          Print detected hardware as JSON without writing anything
upgrade         Pull this fork, update inputs, and offer a rebuild
rollback        Switch to the previous system generation
maintain        Maintenance dashboard
free-space      Review generation cleanup, garbage collection, and optimisation
verify-boot     Inspect the installation mounted at /mnt
test-install    Run installer fixture and safety tests
help, version   Show help or version

Examples:
  ./setup.sh configure --host desktop --profile desktop
  ./setup.sh clean-install --host desktop --profile desktop --dry-run
  ./setup.sh rebuild --host desktop

With no --host, setup uses .setup-host, then the existing laptop host.
Requires Bash 4+, Python 3, Git, and Nix; installation also needs the tools
checked during preflight. Passwords are collected by passwd, never stored here.
EOF
}

main() {
    cd "$ROOT"
    case "${1:-menu}" in
    menu) menu ;;
    # `install` means "install this machine" in whichever environment you are
    # standing in. From the ISO that is a fresh install; on a running NixOS it
    # is the identity/setup pass it has always been, so nobody's habit breaks.
    install)
        if ci_is_live_installer; then clean_install; else install_flow; fi
        ;;
    clean-install | clean_install)
        shift || true
        clean_install "$@"
        ;;
    configure | identity) install_flow ;;
    detect) python3 "$ROOT/scripts/host-config.py" detect ;;
    verify-boot | verify-install) verify_boot ;;
    upgrade | update) update_config ;;
    free-space | freespace | space) free_space ;;
    rebuild | switch) rebuild ;;
    dry | dry-build) dry_build ;;
    check) flake_check ;;
    validate | validator) validator_run ;;
    maintain | maintenance | cleanup) m_maintenance_dashboard ;;
    rollback) rollback ;;
    hardware | hw) refresh_hardware ;;
    generations | list-generations) list_generations ;;
    gc | garbage-collect) m_garbage_collect ;;
    optimize | optimise) m_optimize_store ;;
    verify-store | verify) m_verify_store ;;
    systemd) m_systemd_health ;;
    store | store-usage) m_store_usage ;;
    test-install) test_install ;;
    help | -h | --help) usage ;;
    version | -v | --version) printf '%s\n' "$VERSION" ;;
    *)
        error "Unknown command: $1"
        usage
        exit 2
        ;;
    esac
}

