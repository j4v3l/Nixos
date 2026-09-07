#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
theme_export="$(mktemp)"
trap 'rm -f "$theme_export"' EXIT
nix --option min-free 0 eval --impure --json --expr 'import ./tests/theme-export.nix { lib = (builtins.getFlake (toString ./.)).inputs.nixpkgs.lib; }' > "$theme_export"
export AURORA_THEME_EXPORT="$theme_export"
python3 -m unittest discover -s tests -p 'test_*.py' -v
node tests/test-shell.mjs
shellcheck -x -S warning setup.sh scripts/setup/*.sh home/hyprland/scripts/restore-wallpaper.sh scripts/check.sh scripts/measure.sh scripts/runtime-check.sh
while IFS= read -r -d '' file; do nix-instantiate --option min-free 0 --parse "$file" >/dev/null; done < <(find . -name '*.nix' -not -path './.git/*' -print0)
while IFS= read -r -d '' file; do luac -p "$file"; done < <(find home -name '*.lua' -print0)
if command -v qmlformat >/dev/null; then
    while IFS= read -r -d '' file; do qmlformat "$file" >/dev/null; done < <(find home -name '*.qml' -print0)
else
    echo "SKIP: qmlformat is unavailable; CI checks QML syntax."
fi
if [[ "${1:-}" == "--format" ]]; then
    while IFS= read -r -d '' file; do nixfmt --check "$file"; done < <(find . -name '*.nix' -not -path './.git/*' -print0)
fi
