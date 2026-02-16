#!/usr/bin/env bash
# vim: ft=bash
# shellcheck shell=bash
# Utility functions -- lock file management, credential setup

LOCK_FILE="/tmp/git_pull.lock"

function utils::acquire-lock {
    if [ -f "$LOCK_FILE" ]; then
        local lock_pid
        lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
            log::warning "Another instance is already running (PID: ${lock_pid}), skipping this cycle"
            return 1
        else
            log::warning "Stale lock file found (PID: ${lock_pid} no longer running), removing it"
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"
    return 0
}

function utils::release-lock {
    rm -f "$LOCK_FILE"
}

function utils::cleanup-on-exit {
    utils::release-lock
    log::info "=== Git Pull session ended (PID $$) ==="
}

function utils::setup-credentials {
    if [ -z "$DEPLOYMENT_USER" ]; then
        return 0
    fi

    cd /config || return 1

    log::info "Setting up credential.helper for user: ${DEPLOYMENT_USER}"
    git config --system credential.helper 'store --file=/tmp/git-credentials'

    # Extract hostname from repository URL
    local h="$REPOSITORY"
    local proto="${h%%://*}"
    h="${h#*://}"
    h="${h#*:*@}"
    h="${h#*@}"
    h="${h%%/*}"

    local cred_data
    cred_data="protocol=${proto}
host=${h}
username=${DEPLOYMENT_USER}
password=${DEPLOYMENT_PASSWORD}
"

    log::info "Saving git credentials to /tmp/git-credentials"
    # shellcheck disable=SC2259
    git credential fill | git credential approve <<< "$cred_data"
}
