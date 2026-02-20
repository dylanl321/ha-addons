#!/usr/bin/env bash
# vim: ft=bash
# shellcheck shell=bash
# Safety: physically move HA runtime state out of /config before git operations,
# then move it back after. Git cannot touch what isn't there.

HA_SAFE_DIR="/tmp/.ha-protected"

PROTECTED_PATHS=(
    ".storage"
    "secrets.yaml"
    "home-assistant_v2.db"
    ".cloud"
)

function safety::move-out {
    rm -rf "$HA_SAFE_DIR"
    mkdir -p "$HA_SAFE_DIR" || { log::error "Cannot create ${HA_SAFE_DIR}"; return 1; }

    cd /config || return 1

    local moved=0
    for path in "${PROTECTED_PATHS[@]}"; do
        if [ -e "$path" ]; then
            if mv "$path" "${HA_SAFE_DIR}/${path}"; then
                moved=$((moved + 1))
                log::info "  Moved ${path} out of /config"
            else
                log::error "  FAILED to move ${path} -- copying instead"
                cp -a "$path" "${HA_SAFE_DIR}/${path}" 2>/dev/null || true
            fi
        fi
    done

    log::info "Protected ${moved} path(s) moved to ${HA_SAFE_DIR}"
    return 0
}

function safety::move-back {
    cd /config || return 1

    if [ ! -d "$HA_SAFE_DIR" ]; then
        log::warning "No protected paths to restore (${HA_SAFE_DIR} missing)"
        return 0
    fi

    local restored=0
    for path in "${PROTECTED_PATHS[@]}"; do
        if [ -e "${HA_SAFE_DIR}/${path}" ]; then
            rm -rf "/config/${path}" 2>/dev/null
            if mv "${HA_SAFE_DIR}/${path}" "/config/${path}"; then
                restored=$((restored + 1))
                log::info "  Restored ${path} to /config"
            else
                log::error "  FAILED to move ${path} back -- copying instead"
                cp -a "${HA_SAFE_DIR}/${path}" "/config/${path}" 2>/dev/null || true
            fi
        fi
    done

    rm -rf "$HA_SAFE_DIR" 2>/dev/null
    log::info "Restored ${restored} protected path(s) to /config"
    return 0
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
