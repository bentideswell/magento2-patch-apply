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
#   ./patches/apply.sh --self-update         # redownload this script from GitHub and overwrite it
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
SELF_UPDATE=false
args=()
for arg in "$@"; do
    case "$arg" in
        --dry-run)     DRY_RUN=true ;;
        -v)            FORCE_VERBOSE=true ;;
        --self-update) SELF_UPDATE=true ;;
        *)             args+=("$arg") ;;
    esac
done
set -- "${args[@]+"${args[@]}"}"

if [ "$SELF_UPDATE" = true ]; then
    SELF_UPDATE_URL="https://raw.githubusercontent.com/bentideswell/magento2-patch-apply/main/apply.sh"
    SELF_PATH="${BASH_SOURCE[0]}"
    echo "==> Downloading latest apply.sh from $SELF_UPDATE_URL"
    tmp_file="$(mktemp)"
    trap 'rm -f "$tmp_file"' EXIT
    if ! curl -fsSL "$SELF_UPDATE_URL" -o "$tmp_file"; then
        echo "ERROR: failed to download update" >&2
        exit 1
    fi
    if [ ! -s "$tmp_file" ] || ! head -n1 "$tmp_file" | grep -q '^#!'; then
        echo "ERROR: downloaded file does not look like a valid script" >&2
        exit 1
    fi
    chmod +x "$tmp_file"
    mv "$tmp_file" "$SELF_PATH"
    trap - EXIT
    echo "==> Updated $SELF_PATH"
    exit 0
fi

VERBOSE=false
if [ "$#" -gt 0 ] || [ "$FORCE_VERBOSE" = true ]; then
    VERBOSE=true
fi

RESULT_NAMES=()
RESULT_STATUSES=()
RESULT_NOTES=()

record_result() {
    RESULT_NAMES+=("$1")
    RESULT_STATUSES+=("$2")
    RESULT_NOTES+=("${3:-}")
}

# Splits `patch` output into per-file segments (each starts at a "patching
# file" or "No file to patch" line) and classifies every segment as applied,
# already-applied, failed, or skipped (target file missing). Prints the four
# counts as "applied already failed skipped".
classify_patch_output() {
    awk '
        { line = tolower($0) }
        line ~ /^(patching|checking) file / { seg++; type[seg] = "ok" }
        line ~ /^no file to patch/ { seg++; type[seg] = "skip" }
        line ~ /hunks? failed/ { if (seg > 0) type[seg] = "fail" }
        line ~ /previously applied/ { if (seg > 0 && type[seg] != "fail") type[seg] = "already" }
        END {
            a = 0; al = 0; f = 0; s = 0
            for (i = 1; i <= seg; i++) {
                if (type[i] == "skip") s++
                else if (type[i] == "fail") f++
                else if (type[i] == "already") al++
                else a++
            }
            printf "%d %d %d %d\n", a, al, f, s
        }
    '
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
    output=$(patch "${patch_args[@]}" < "$file" 2>&1) || true

    local n_applied n_already n_failed n_skipped
    read -r n_applied n_already n_failed n_skipped < <(classify_patch_output <<< "$output")

    local status
    if [ "$n_failed" -gt 0 ]; then
        status="FAILED"
    elif [ "$n_applied" -gt 0 ]; then
        status="Applied"
    elif [ "$n_already" -gt 0 ]; then
        status="Already applied"
    else
        # No file in the patch could be found at all.
        status="FAILED"
    fi

    local note=""
    if [ "$n_skipped" -gt 0 ]; then
        note="$n_skipped file"
        if [ "$n_skipped" -gt 1 ]; then
            note="${note}s"
        fi
        note="${note} skipped"
    fi

    if [ "$VERBOSE" = true ]; then
        if [ "$status" = "FAILED" ]; then
            echo "$output" >&2
            echo ""
            echo "ERROR: failed to apply patch: $(basename "$file")" >&2
        else
            echo "$output"
            echo ""
        fi
    fi

    record_result "$(basename "$file")" "$status" "$note"
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
    local display
    for i in "${!RESULT_NAMES[@]}"; do
        color=""
        if [ -t 1 ]; then
            color="$(color_for_status "${RESULT_STATUSES[$i]}")"
        fi
        display="${RESULT_STATUSES[$i]}"
        if [ -n "${RESULT_NOTES[$i]}" ]; then
            display="${display} - ${RESULT_NOTES[$i]}"
        fi
        printf "    %-55s %s%s%s\n" "${RESULT_NAMES[$i]}" "$color" "$display" "$reset"
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
