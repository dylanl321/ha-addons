#!/usr/bin/env bash
# vim: ft=bash
# shellcheck shell=bash
# Ensure addon-specific paths are excluded from git tracking.

function safety::ensure-gitignore-entries {
    cd /config || return 0

    local entries=(
        ".git_sync_repo/"
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
