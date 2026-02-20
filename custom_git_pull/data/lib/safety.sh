#!/usr/bin/env bash
# vim: ft=bash
# shellcheck shell=bash
# Safety checks -- protected-path verification and untracked-file inventory

PROTECTED_PATHS=(
    ".storage"
    "secrets.yaml"
    "home-assistant_v2.db"
    ".cloud"
)

function safety::snapshot-protected-paths {
    local snapshot_file="$1"
    : > "$snapshot_file"

    cd /config || return 1

    for path in "${PROTECTED_PATHS[@]}"; do
        if [ -e "$path" ]; then
            echo "$path" >> "$snapshot_file"
        fi
    done
}

function safety::verify-protected-paths {
    local snapshot_file="$1"
    local context="${2:-unknown operation}"

    if [ ! -f "$snapshot_file" ] || [ ! -s "$snapshot_file" ]; then
        return 0
    fi

    cd /config || return 1

    local missing=()
    while IFS= read -r path; do
        if [ ! -e "$path" ]; then
            missing+=("$path")
        fi
    done < "$snapshot_file"

    if [ ${#missing[@]} -gt 0 ]; then
        log::fatal "PROTECTED PATHS MISSING after ${context}:"
        for p in "${missing[@]}"; do
            log::fatal "  - ${p}"
        done
        return 1
    fi

    log::info "Protected path check passed after ${context}"
    return 0
}

function safety::log-untracked-inventory {
    cd /config || return 0

    if ! git rev-parse --is-inside-work-tree &>/dev/null; then
        return 0
    fi

    log::info "Untracked file inventory before operation:"

    local untracked
    untracked=$(git ls-files --others --exclude-standard 2>/dev/null | head -n 50)

    if [ -z "$untracked" ]; then
        log::info "  (no untracked files)"
        return 0
    fi

    local count
    count=$(git ls-files --others --exclude-standard 2>/dev/null | wc -l)

    while IFS= read -r f; do
        log::info "  [untracked] ${f}"
    done <<< "$untracked"

    if [ "$count" -gt 50 ]; then
        log::info "  ... and $((count - 50)) more untracked files"
    fi

    for path in "${PROTECTED_PATHS[@]}"; do
        if [ -e "$path" ]; then
            log::info "  [protected] ${path} -- exists"
        else
            log::info "  [protected] ${path} -- not present"
        fi
    done
}

function safety::ensure-gitignore-entries {
    cd /config || return 0

    local entries=(
        ".git_pull_backups/"
        ".git_pull.log"
        ".git_pull.log.*"
    )

    [ -f .gitignore ] || touch .gitignore

    for entry in "${entries[@]}"; do
        if ! grep -qxF "$entry" .gitignore 2>/dev/null; then
            echo "$entry" >> .gitignore
            log::info "Added '${entry}' to .gitignore"
        fi
    done
}
