#!/usr/bin/env bash

# Shared helpers for qinux-build.
#
# Sourced by the scripts in scripts/. Not executable on its own.
#
# shellcheck shell=bash

# Guard against double-sourcing: lib functions must not clobber each other's
# state when a caller already has them.
if [[ -n "${QINUX_BUILD_LIB_COMMON:-}" ]]; then
    return 0
fi
QINUX_BUILD_LIB_COMMON=1

# --------------------------------------------------------------------------
# Output
#
# Colour is used only when writing to a terminal, and is suppressed when
# NO_COLOR is set (https://no-color.org) or when not a tty, so CI logs and
# redirected output stay clean.
# --------------------------------------------------------------------------

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_RESET=$'\033[0m'
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'
    C_DIM=$'\033[2m'
    C_BOLD=$'\033[1m'
else
    C_RESET='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_DIM='' C_BOLD=''
fi

log()      { printf '%s==>%s %s\n'    "$C_BLUE$C_BOLD" "$C_RESET" "$*" >&2; }
log_step() { printf '%s  ->%s %s\n'   "$C_DIM" "$C_RESET" "$*" >&2; }
log_ok()   { printf '%s  ok%s %s\n'   "$C_GREEN" "$C_RESET" "$*" >&2; }
log_warn() { printf '%swarn:%s %s\n'  "$C_YELLOW" "$C_RESET" "$*" >&2; }
log_err()  { printf '%serror:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }

# die MSG...   Print to stderr and exit 1.
die() {
    log_err "$*"
    exit 1
}

# have CMD   True if CMD is on PATH.
have() {
    command -v "$1" >/dev/null 2>&1
}

# --------------------------------------------------------------------------
# Timing
# --------------------------------------------------------------------------

# Seconds since the epoch. The perl fallback covers a host whose date does not
# support %s, which is otherwise a silent zero that makes every build report
# 0.0s.
now() {
    local n
    n=$(date +%s 2>/dev/null) && printf '%s' "$n" && return 0
    n=$(perl -MTime::Seconds -e 'print time' 2>/dev/null) && printf '%s' "$n" && return 0
    printf '0'
}

# format_duration SECONDS -> "1m 05s" / "12.3s"
format_duration() {
    local total=$1
    if (( total < 60 )); then
        printf '%d.%01ds' "$total" $(( (total % 10) ))
        return
    fi
    printf '%dm %02ds' $(( total / 60 )) $(( total % 60 ))
}

# --------------------------------------------------------------------------
# Module graph
# --------------------------------------------------------------------------

# Populated by load_modules.
declare -a MODULE_NAMES=()
declare -A MODULE_KIND=()
declare -A MODULE_REPO=()
declare -A MODULE_DEPS=()

# load_modules PATH
#
# Sources a modules.conf and fills the MODULE_* arrays. Kept as a separate step
# so a malformed config fails before any build work starts.
load_modules() {
    local conf=$1
    [[ -r "$conf" ]] || die "module config not readable: $conf"

    local line name kind deps repo lineno=0
    local -A seen=()

    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno + 1))

        # Skip blanks, comments and section headers.
        [[ -z "${line// }" ]] && continue
        [[ "$line" == \#* ]] && continue
        [[ "$line" == '---'* ]] && continue

        IFS='|' read -r name kind deps repo <<<"$line"
        name=$(trim "$name")
        kind=$(trim "$kind")
        deps=$(trim "$deps")
        repo=$(trim "$repo")

        if [[ -z "$name" || -z "$kind" || -z "$repo" ]]; then
            die "$conf:$lineno: malformed module line: $line"
        fi
        if [[ -n "${seen[$name]:-}" ]]; then
            die "$conf:$lineno: duplicate module: $name"
        fi
        seen[$name]=1

        MODULE_NAMES+=("$name")
        MODULE_KIND[$name]=$kind
        MODULE_REPO[$name]=$repo
        MODULE_DEPS[$name]=$deps
    done <"$conf"

    [[ ${#MODULE_NAMES[@]} -gt 0 ]] || die "no modules defined in $conf"

    local n d
    for n in "${MODULE_NAMES[@]}"; do
        for d in ${MODULE_DEPS[$n]}; do
            [[ -n "${MODULE_KIND[$d]:-}" ]] \
                || die "module $n depends on unknown module $d"
        done
    done
}

# trim STRING   Remove leading and trailing whitespace.
trim() {
    local s=$1
    s=${s#"${s%%[![:space:]]*}"}
    s=${s%"${s##*[![:space:]]}"}
    printf '%s' "$s"
}

# module_exists NAME
module_exists() {
    [[ -n "${MODULE_KIND[$1]:-}" ]]
}

# --------------------------------------------------------------------------
# Dependency ordering
# --------------------------------------------------------------------------

# resolve_order MODULE...
#
# Prints module names in build order, dependencies before dependents, one per
# line. Arguments are roots: their dependencies are pulled in transitively,
# and with no arguments every module is a root.
#
# A repeated scan over MODULE_NAMES rather than Kahn's algorithm. With 51
# modules the quadratic cost is irrelevant, and a fixed input order means the
# output is stable between runs, which matters for reproducible build logs.
resolve_order() {
    local -a roots=("$@")
    [[ ${#roots[@]} -eq 0 ]] && roots=("${MODULE_NAMES[@]}")

    # Transitive closure: everything that must be built before the roots.
    local -A need=()
    local -a stack=()
    local n d cur

    for n in "${roots[@]}"; do
        module_exists "$n" || die "unknown module: $n"
        [[ -n "${need[$n]:-}" ]] && continue
        need[$n]=1
        stack+=("$n")
    done

    while (( ${#stack[@]} > 0 )); do
        cur=${stack[$((${#stack[@]} - 1))]}
        unset 'stack[${#stack[@]}-1]'
        stack=("${stack[@]}")
        for d in ${MODULE_DEPS[$cur]}; do
            [[ -n "${need[$d]:-}" ]] && continue
            need[$d]=1
            stack+=("$d")
        done
    done

    # Emit any module whose dependencies are all emitted, until nothing moves.
    local -a ordered=()
    local -A emitted=()
    local progress=1 all_done

    while (( progress == 1 )); do
        progress=0
        for n in "${MODULE_NAMES[@]}"; do
            [[ -n "${need[$n]:-}" ]] || continue
            [[ -z "${emitted[$n]:-}" ]] || continue
            all_done=1
            for d in ${MODULE_DEPS[$n]}; do
                if [[ -n "${need[$d]:-}" && -z "${emitted[$d]:-}" ]]; then
                    all_done=0
                    break
                fi
            done
            if (( all_done == 1 )); then
                emitted[$n]=1
                ordered+=("$n")
                progress=1
            fi
        done
    done

    # Anything still unemitted is downstream of a cycle.
    for n in "${!need[@]}"; do
        [[ -n "${emitted[$n]:-}" ]] || die "dependency cycle involving: $n"
    done

    printf '%s\n' "${ordered[@]}"
}

# --------------------------------------------------------------------------
# Sanity checks
# --------------------------------------------------------------------------

# require_tools KIND   Warn about the tools a module kind needs.
#
# A missing tool is a warning, not an error: a host building only `data`
# modules has no reason to have the kernel toolchain installed.
require_tools() {
    local kind=$1
    local -a tools=()
    case $kind in
        shell)   tools=(bash shellcheck) ;;
        python)  tools=(python3 ruff) ;;
        qml)     tools=(qmllint) ;;
        kernel)  tools=(make gcc bc flex bison) ;;
        iso)     tools=(xorriso) ;;
        data)    tools=(python3) ;;
        *)       tools=() ;;
    esac

    local t missing=()
    for t in "${tools[@]}"; do
        have "$t" || missing+=("$t")
    done
    (( ${#missing[@]} > 0 )) && log_warn "$kind build needs: ${missing[*]} (missing)"
    return 0
}