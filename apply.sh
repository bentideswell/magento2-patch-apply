#!/usr/bin/env bash
#
# Applies .patch and .sh files found in this script's directory, in
# alphabetical order (prefix filenames with a date to control order).
#
# Usage:
#   ./patches/apply.sh                       # run every .patch/.sh file in order
#   ./patches/apply.sh 2026-09-09-vuln1234.patch   # run just one file
#   ./patches/apply.sh --dry-run             # show what would be applied/run, without changing anything
#   ./patches/apply.sh -v                    # show full output even when running the whole directory
#
# Patches are applied with `patch -p1`, run from the parent directory of
# this script (i.e. the project root), so they should be generated as
# `git diff` output relative to the repo root.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_ROOT"

DRY_RUN=false
FORCE_VERBOSE=false
args=()
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        -v)        FORCE_VERBOSE=true ;;
        *)         args+=("$arg") ;;
    esac
done
set -- "${args[@]+"${args[@]}"}"

VERBOSE=false
if [ "$#" -gt 0 ] || [ "$FORCE_VERBOSE" = true ]; then
    VERBOSE=true
fi

RESULT_NAMES=()
RESULT_STATUSES=()

record_result() {
    RESULT_NAMES+=("$1")
    RESULT_STATUSES+=("$2")
}

apply_patch() {
    local file="$1"
    local patch_args=(-p1 --forward --batch)
    local verb="Applying"
    if [ "$DRY_RUN" = true ]; then
        patch_args+=(--dry-run)
        verb="[dry-run] Would apply"
    fi
    if [ "$VERBOSE" = true ]; then
        echo "==> $verb patch: $(basename "$file")"
        echo ""
    fi

    local output
    if output=$(patch "${patch_args[@]}" < "$file" 2>&1); then
        if [ "$VERBOSE" = true ]; then
            echo "$output"
            echo ""
        fi
        record_result "$(basename "$file")" "Applied"
    elif grep -qi "previously applied" <<< "$output" && ! grep -qi "failed" <<< "$output"; then
        if [ "$VERBOSE" = true ]; then
            echo "$output"
            echo ""
            echo "==> Already applied, skipping: $(basename "$file")"
        fi
        record_result "$(basename "$file")" "Already applied"
    else
        if [ "$VERBOSE" = true ]; then
            echo "$output" >&2
            echo ""
            echo "ERROR: failed to apply patch: $(basename "$file")" >&2
        fi
        record_result "$(basename "$file")" "FAILED"
    fi
    if [ "$VERBOSE" = true ]; then
        echo ""
    fi
}

run_script() {
    local file="$1"
    if [ "$DRY_RUN" = true ]; then
        if [ "$VERBOSE" = true ]; then
            echo "==> [dry-run] Would run script: $(basename "$file")"
        fi
        record_result "$(basename "$file")" "Skipped (dry-run)"
        return
    fi
    if [ "$VERBOSE" = true ]; then
        echo "==> Running script: $(basename "$file")"
        if bash "$file"; then
            record_result "$(basename "$file")" "Applied"
        else
            echo "ERROR: script exited with a non-zero status: $(basename "$file")" >&2
            record_result "$(basename "$file")" "FAILED"
        fi
    else
        if bash "$file" > /dev/null 2>&1; then
            record_result "$(basename "$file")" "Applied"
        else
            record_result "$(basename "$file")" "FAILED"
        fi
    fi
}

process_file() {
    local file="$1"
    case "$file" in
        *.patch) apply_patch "$file" ;;
        *.sh)    run_script "$file" ;;
        *)       echo "Skipping unrecognized file: $(basename "$file")" ;;
    esac
}

color_for_status() {
    case "$1" in
        FAILED)             echo -n $'\033[31m' ;;
        "Already applied")  echo -n $'\033[33m' ;;
        Applied)            echo -n $'\033[32m' ;;
        "Skipped (dry-run)") echo -n $'\033[38;5;208m' ;;
    esac
}

print_summary_and_exit() {
    echo "==> Summary:"
    local i failed=false color="" reset=""
    if [ -t 1 ]; then
        reset=$'\033[0m'
    fi
    for i in "${!RESULT_NAMES[@]}"; do
        color=""
        if [ -t 1 ]; then
            color="$(color_for_status "${RESULT_STATUSES[$i]}")"
        fi
        printf "    %-55s %s%s%s\n" "${RESULT_NAMES[$i]}" "$color" "${RESULT_STATUSES[$i]}" "$reset"
        if [ "${RESULT_STATUSES[$i]}" = "FAILED" ]; then
            failed=true
        fi
    done
    if [ "$failed" = true ]; then
        exit 1
    fi
    exit 0
}

if [ "$#" -gt 0 ]; then
    for arg in "$@"; do
        file="$SCRIPT_DIR/$(basename "$arg")"
        if [ ! -f "$file" ]; then
            echo "ERROR: file not found: $arg" >&2
            exit 1
        fi
        process_file "$file"
    done
    print_summary_and_exit
fi

SELF_NAME="$(basename "${BASH_SOURCE[0]}")"

shopt -s nullglob
files=()
for f in "$SCRIPT_DIR"/*.patch "$SCRIPT_DIR"/*.sh; do
    if [ "$(basename "$f")" != "$SELF_NAME" ]; then
        files+=("$f")
    fi
done
shopt -u nullglob

if [ "${#files[@]}" -eq 0 ]; then
    echo "No .patch or .sh files found in $SCRIPT_DIR"
    exit 0
fi

IFS=$'\n' sorted=($(printf '%s\n' "${files[@]}" | sort))
unset IFS

for file in "${sorted[@]}"; do
    process_file "$file"
done

print_summary_and_exit
