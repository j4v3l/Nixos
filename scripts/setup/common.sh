#!/usr/bin/env bash
set -Eeuo pipefail
# Shared terminal output and prompts. Redirected output omits terminal controls.

if [[ -t 1 ]]; then IS_TTY=1; else IS_TTY=0; fi

# Colour is off when asked for (NO_COLOR), when the terminal says it
# cannot render it (TERM=dumb), or when stdout is not a terminal at all.
#
# Only an *explicit* TERM=dumb disables it. An unset TERM alongside a real
# tty means a stripped environment rather than a teletype, and every
# terminal emulator that can give us a tty can also handle basic ANSI --
# the -t 1 test above is what actually protects pipes and log files.
UI_COLOR=1
if [[ -n "${NO_COLOR:-}" ]]; then UI_COLOR=0; fi
if [[ "${TERM:-}" == "dumb" ]]; then UI_COLOR=0; fi
if [[ "$IS_TTY" -eq 0 ]]; then UI_COLOR=0; fi

# 24-bit colour is what lets the palette be the actual theme rather
# than an approximation of it. Without it we fall back to the 3-bit
# codes this script used to hardcode.
#
# COLORTERM is the reliable signal and kitty sets it, but it is lost
# across sudo and some multiplexers, so a TERM that advertises direct
# or 256 colour counts too.
UI_TRUECOLOR=0
if [[ "$UI_COLOR" -eq 1 ]]; then
    case "${COLORTERM:-}" in
    truecolor | 24bit) UI_TRUECOLOR=1 ;;
    esac

    case "${TERM:-}" in
    *-direct* | *-256color | kitty | xterm-kitty | alacritty | foot | wezterm)
        UI_TRUECOLOR=1
        ;;
    esac
fi

# Box drawing and the nicer glyphs need a UTF-8 locale.
#
# Also dropped without a tty. Strictly, UTF-8 keeps working through a
# pipe -- but validator output gets redirected into logs, pasted into
# issues and mailed around, and ASCII survives all of those intact.
UI_UNICODE=1
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
*UTF-8* | *utf-8* | *UTF8* | *utf8*) ;;
*) UI_UNICODE=0 ;;
esac
if [[ "${TERM:-}" == "dumb" ]]; then UI_UNICODE=0; fi
if [[ "$IS_TTY" -eq 0 ]]; then UI_UNICODE=0; fi

# Width for the panel frame and the section rules. Clamped: a rule
# stretched across a 210-column terminal reads as a divider in a
# spreadsheet, not a heading.
UI_WIDTH=64
if [[ "$IS_TTY" -eq 1 ]]; then
    UI_WIDTH="$(tput cols 2>/dev/null || printf '64')"
    if [[ "$UI_WIDTH" -gt 74 ]]; then UI_WIDTH=74; fi
    if [[ "$UI_WIDTH" -lt 40 ]]; then UI_WIDTH=40; fi
fi

# Palette, read from the live Aurora theme
#
# ~/.config/aurora/active-theme and themes/<id>.json are the same
# files core/Theme.qml watches, so the installer wears whatever
# colourscheme the desktop is currently wearing. Strictly read-only:
# this participates in no part of the theme pipeline, it only looks
# at the output. Every lookup carries the built-in aurora value as a
# fallback, so a missing or half-written file costs nothing.

AURORA_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/aurora"
UI_THEME_FILE=""

if [[ -r "$AURORA_DIR/active-theme" ]]; then
    UI_THEME_ID="$(tr -d '[:space:]' <"$AURORA_DIR/active-theme" 2>/dev/null || printf '')"

    if [[ -n "$UI_THEME_ID" && -r "$AURORA_DIR/themes/$UI_THEME_ID.json" ]]; then
        UI_THEME_FILE="$AURORA_DIR/themes/$UI_THEME_ID.json"
    fi
fi

# Pull one "key":"#rrggbb" pair out of the theme JSON. Deliberately
# grep rather than jq: jq is not guaranteed present on a machine that
# is still being installed, and this needs exactly one field.
ui_hex() {
    local key="$1" fallback="$2" hex=""

    if [[ -n "$UI_THEME_FILE" ]]; then
        hex="$(grep -o "\"$key\"[[:space:]]*:[[:space:]]*\"#[0-9a-fA-F]\{6\}\"" "$UI_THEME_FILE" 2>/dev/null |
            head -1 | grep -o '#[0-9a-fA-F]\{6\}' || printf '')"
    fi

    printf '%s' "${hex:-$fallback}"
}

# $1 theme key, $2 fallback hex, $3 basic ANSI code for 16-colour terminals
ui_fg() {
    local hex

    if [[ "$UI_COLOR" -eq 0 ]]; then
        printf ''
        return 0
    fi

    if [[ "$UI_TRUECOLOR" -eq 1 ]]; then
        hex="$(ui_hex "$1" "$2")"

        printf '\033[38;2;%d;%d;%dm' \
            "$((16#${hex:1:2}))" "$((16#${hex:3:2}))" "$((16#${hex:5:2}))"

        return 0
    fi

    printf '\033[%sm' "$3"
}

if [[ "$UI_COLOR" -eq 1 ]]; then
    RESET='\033[0m'
    BOLD='\033[1m'
else
    RESET=''
    BOLD=''
fi

# Semantic, not literal. The names are historical; the theme role in
# the trailing comment is what each one actually means.
RED="$(ui_fg error '#F38BA8' 31)"               # failure
GREEN="$(ui_fg success '#A6E3A1' 32)"           # success
YELLOW="$(ui_fg warning '#F9E2AF' 33)"          # warning
BLUE="$(ui_fg info '#89B4FA' 34)"               # information
MAGENTA="$(ui_fg terminalMagenta '#F5C2E7' 35)" # a command about to run
CYAN="$(ui_fg accent '#CBA6F7' 36)"             # chrome: headings, numbers, frames
DIM="$(ui_fg textMuted '#989CAC' 2)"            # de-emphasised

# Glyphs
#
# These literals are the Unicode / Nerd Font set. The block just below
# them swaps in ASCII when the locale cannot render it, so nothing here
# needs a conditional of its own.

ICON_OK="✓"
ICON_FAIL="✗"
ICON_WARN="!"
ICON_INFO="ℹ"
ICON_ARROW="→"

UI_TL="╭"
UI_TR="╮"
UI_BL="╰"
UI_BR="╯"
UI_H="─"
UI_V="│"
UI_RULE="─"

UI_SPIN=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")

# ASCII fallback, for a terminal without a UTF-8 locale. Everything
# above is replaced wholesale rather than conditionally, so the rest of
# the script only ever refers to the names.
if [[ "$UI_UNICODE" -eq 0 ]]; then
    ICON_OK="ok"
    ICON_FAIL="x"
    ICON_WARN="!"
    ICON_INFO="i"
    ICON_ARROW=">"

    UI_TL="+"
    UI_TR="+"
    UI_BL="+"
    UI_BR="+"
    UI_H="-"
    UI_V="|"
    UI_RULE="-"

    UI_SPIN=("|" "/" "-" "\\")
fi

# Cursor
#
# The trap lives here rather than three hundred lines further down next
# to the maintenance dashboard, because a Ctrl-C anywhere in the script
# has to put the cursor back.

hide_cursor() {
    if [[ "$IS_TTY" -eq 1 ]]; then tput civis 2>/dev/null || true; fi
}

show_cursor() {
    if [[ "$IS_TTY" -eq 1 ]]; then tput cnorm 2>/dev/null || true; fi
}

trap show_cursor EXIT INT TERM

# Primitives

# Repeat $1 exactly $2 times.
ui_repeat() {
    local char="$1" count="$2" out="" i

    for ((i = 0; i < count; i++)); do out+="$char"; done

    printf '%s' "$out"
}

# Length of a string with escape sequences discounted, so the panel
# border lines up whether or not colour is on.
ui_visible_len() {
    local stripped

    stripped="$(printf '%b' "$1" | sed -e 's/\x1b\[[0-9;]*m//g')"

    printf '%s' "${#stripped}"
}

clear_screen() {
    if [[ "$IS_TTY" -eq 1 ]]; then clear 2>/dev/null || printf '\033[H\033[2J'; fi
}

hr() {
    printf '  %b%s%b\n' "$DIM" "$(ui_repeat "$UI_RULE" "$((UI_WIDTH - 2))")" "$RESET"
}

# Log lines
#
# Two leading spaces, a coloured glyph, then the message -- the shape
# this script has always had, so nothing downstream needs re-reading.

die() {
    printf '  %b%s%b %s\n' "$RED" "$ICON_FAIL" "$RESET" "$*" >&2
    exit 1
}
info() { printf '  %b%s%b %s\n' "$BLUE" "$ICON_INFO" "$RESET" "$*"; }
success() { printf '  %b%s%b %s\n' "$GREEN" "$ICON_OK" "$RESET" "$*"; }
warning() { printf '  %b%s%b %s\n' "$YELLOW" "$ICON_WARN" "$RESET" "$*"; }
error() { printf '  %b%s%b %s\n' "$RED" "$ICON_FAIL" "$RESET" "$*" >&2; }
run_cmd() { printf '  %b%s%b %b%s%b\n' "$MAGENTA" "$ICON_ARROW" "$RESET" "$DIM" "$*" "$RESET"; }

section() {
    printf '\n  %b%b%s%b\n' "$CYAN" "$BOLD" "$1" "$RESET"
    hr
}

pause() {
    echo
    read -r -p "  Press Enter to continue..." _ || true
}

confirm() {
    local prompt="${1:-Continue?}" answer
    echo
    read -r -p "  $prompt [y/N]: " answer
    [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# Validator results
#
# Installation and validation collect failures before printing a verdict.

V_FAILED=0

v_ok() { printf '  %b%s%b %s\n' "$GREEN" "$ICON_OK" "$RESET" "$1"; }

v_fail() {
    printf '  %b%s%b %s\n' "$RED" "$ICON_FAIL" "$RESET" "$1"
    # Read by installation.sh after all verification steps finish.
    # shellcheck disable=SC2034
    V_FAILED=1
}

v_info() { printf '  %b%s%b %s\n' "$YELLOW" "$ICON_WARN" "$RESET" "$1"; }

v_separator() { hr; }

# Panel
#
# The framed header. $1 is the title, $2 an optional right-aligned tag
# (the version), and any further arguments become dimmed fact lines
# inside the frame.

panel() {
    local title="$1" tag="${2:-}"
    shift || true
    shift || true

    local inner=$((UI_WIDTH - 2))
    local head=" $title " tail="" pad

    if [[ -n "$tag" ]]; then tail=" $tag "; fi

    pad=$((inner - ${#head} - ${#tail} - 1))
    if [[ "$pad" -lt 1 ]]; then pad=1; fi

    printf '%b%s%s%b%s%b%s%s%s%b\n' \
        "$CYAN" "$UI_TL" "$UI_H" \
        "$BOLD" "$head" "$RESET$CYAN" \
        "$(ui_repeat "$UI_H" "$pad")" "$tail" "$UI_TR" "$RESET"

    local line len
    for line in "$@"; do
        len="$(ui_visible_len "$line")"

        pad=$((inner - len - 2))
        if [[ "$pad" -lt 0 ]]; then pad=0; fi

        printf '%b%s%b %b%s%b%s %b%s%b\n' \
            "$CYAN" "$UI_V" "$RESET" \
            "$DIM" "$line" "$RESET" "$(ui_repeat ' ' "$pad")" \
            "$CYAN" "$UI_V" "$RESET"
    done

    printf '%b%s%s%s%b\n' \
        "$CYAN" "$UI_BL" "$(ui_repeat "$UI_H" "$inner")" "$UI_BR" "$RESET"
}

# Verdict
#
# The framed one-line result the validator ends on. Same framing as
# panel() but tinted by outcome and centred, and it respects UI_WIDTH and
# UI_UNICODE rather than the fixed 62-column unicode box it replaces --
# which used to survive `| cat` as raw box characters.

verdict() {
    local tint="$1" icon="$2" msg="$3"

    local inner=$((UI_WIDTH - 2))
    local body="$icon  $msg"
    local len=${#body}

    if [[ "$len" -gt "$inner" ]]; then
        body="${body:0:$inner}"
        len="$inner"
    fi

    local left=$(((inner - len) / 2))
    local right=$((inner - len - left))

    local rule
    rule="$(ui_repeat "$UI_H" "$inner")"

    printf '%b%s%s%s%b\n' "$tint" "$UI_TL" "$rule" "$UI_TR" "$RESET"

    printf '%b%s%b%s%b%s%b%s%b%s%b\n' \
        "$tint" "$UI_V" "$RESET" \
        "$(ui_repeat ' ' "$left")" \
        "$tint$BOLD" "$body" "$RESET" \
        "$(ui_repeat ' ' "$right")" \
        "$tint" "$UI_V" "$RESET"

    printf '%b%s%s%s%b\n' "$tint" "$UI_BL" "$rule" "$UI_BR" "$RESET"
}

# Spinner
#
# Wraps a long operation whose output we do not need to watch, showing
# an elapsed second count so that a slow `nix flake check` never looks
# hung. Operations whose output IS the point -- nixos-rebuild switch
# above all -- are deliberately left streaming to the terminal.
#
# Without a TTY it degrades to plain lines, so piped output stays
# readable and no escape sequences leak into a log file. On failure the
# captured output is replayed to stderr, so nothing is ever swallowed.

spinner() {
    local label="$1"
    shift

    local log rc=0
    log="$(mktemp)"

    if [[ "$IS_TTY" -eq 0 ]]; then
        run_cmd "$label"

        if "$@" >"$log" 2>&1; then
            success "$label"
        else
            rc=$?
            error "$label"
            cat "$log" >&2
        fi

        rm -f "$log"
        return "$rc"
    fi

    "$@" >"$log" 2>&1 &
    local pid=$!
    local frame=0 start=$SECONDS

    hide_cursor

    while kill -0 "$pid" 2>/dev/null; do
        printf '\r  %b%s%b %s %b%ds%b' \
            "$CYAN" "${UI_SPIN[$frame]}" "$RESET" \
            "$label" "$DIM" "$((SECONDS - start))" "$RESET"

        frame=$(((frame + 1) % ${#UI_SPIN[@]}))
        sleep 0.08
    done

    wait "$pid" || rc=$?

    show_cursor

    # Erase the spinner line before the result replaces it.
    printf '\r\033[2K'

    if [[ "$rc" -eq 0 ]]; then
        success "$label ($((SECONDS - start))s)"
    else
        error "$label failed after $((SECONDS - start))s"
        cat "$log" >&2
    fi

    rm -f "$log"
    return "$rc"
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }
as_root() { sudo "$@"; }
