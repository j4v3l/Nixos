#!/usr/bin/env bash
set -Eeuo pipefail

if ((BASH_VERSINFO[0] < 4)); then
    echo "Setup requires Bash 4 or newer." >&2
    exit 1
fi
VERSION="2.0"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HOST=""
PROFILE=""
MODEL=""
INSTALL_LAYOUT=""
INSTALL_SWAP_GIB=""
SETUP_DRY_RUN=0
COMMAND=""
while (($#)); do
    case "$1" in
        --host|--profile|--model|--layout|--swap-gib)
            (($# >= 2)) || { echo "Missing value for $1" >&2; exit 2; }
            case "$1" in
                --host) HOST="$2" ;; --profile) PROFILE="$2" ;; --model) MODEL="$2" ;;
                --layout) INSTALL_LAYOUT="$2" ;; --swap-gib) INSTALL_SWAP_GIB="$2" ;;
            esac
            shift 2 ;;
        --dry-run|-n) SETUP_DRY_RUN=1; shift ;;
        --help|-h) COMMAND=help; shift ;;
        --version|-v) COMMAND=version; shift ;;
        --*) echo "Unknown option: $1" >&2; exit 2 ;;
        *) [[ -z "$COMMAND" ]] || { echo "Unexpected argument: $1" >&2; exit 2; }; COMMAND="$1"; shift ;;
    esac
done
if [[ -z "$HOST" && -f "$ROOT/.setup-host" ]]; then IFS= read -r HOST < "$ROOT/.setup-host"; fi
HOST="${HOST:-laptop}"
[[ "$HOST" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] || { echo "Invalid host name" >&2; exit 2; }
[[ -z "$PROFILE" || "$PROFILE" == "laptop" || "$PROFILE" == "desktop" || "$PROFILE" == "vm" ]] || { echo "Invalid profile" >&2; exit 2; }
[[ -z "$INSTALL_LAYOUT" || "$INSTALL_LAYOUT" == plain || "$INSTALL_LAYOUT" == encrypted ]] || { echo "Invalid layout" >&2; exit 2; }
[[ -z "$INSTALL_SWAP_GIB" || "$INSTALL_SWAP_GIB" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid swap size" >&2; exit 2; }
if [[ -n "$INSTALL_LAYOUT$INSTALL_SWAP_GIB" ]]; then
    case "$COMMAND" in
        clean-install|clean_install|install|help) ;;
        *) echo "Storage flags apply only to fresh installation." >&2; exit 2 ;;
    esac
fi
FLAKE_TARGET="$ROOT#$HOST"
V_FAILED=0
HOST_SETTINGS=""
# shellcheck source=scripts/setup/common.sh
source "$ROOT/scripts/setup/common.sh"
# shellcheck source=scripts/setup/hardware.sh
source "$ROOT/scripts/setup/hardware.sh"
# shellcheck source=scripts/setup/operations.sh
source "$ROOT/scripts/setup/operations.sh"
# shellcheck source=scripts/setup/maintenance.sh
source "$ROOT/scripts/setup/maintenance.sh"
# shellcheck source=scripts/setup/validation.sh
source "$ROOT/scripts/setup/validation.sh"
# shellcheck source=scripts/setup/installation.sh
source "$ROOT/scripts/setup/installation.sh"

# Never silently ignore --dry-run on a command that changes the machine.
if [[ "$SETUP_DRY_RUN" -eq 1 ]]; then
    case "${COMMAND:-menu}" in
        configure|identity|install|clean-install|clean_install|hardware|hw|detect|help|version) ;;
        *) die "--dry-run is supported by configure, install, clean-install, and hardware." ;;
    esac
fi
main "${COMMAND:-menu}"
