#!/usr/bin/env bash
# vim: ft=bash
# shellcheck shell=bash
# Utility functions -- flock-based locking, credential setup

LOCK_FILE="/tmp/git_pull.lock"
LOCK_FD=9

function utils::acquire-lock {
    exec 9>"$LOCK_FILE"
    if ! flock -n $LOCK_FD; then
        log::warning "Another instance is already running, skipping this cycle"
        return 1
    fi
    return 0
}

function utils::release-lock {
    flock -u $LOCK_FD 2>/dev/null || true
    exec 9>&- 2>/dev/null || true
    rm -f "$LOCK_FILE" 2>/dev/null || true
}

function utils::cleanup-on-exit {
    if [ "${DEPLOY_IN_PROGRESS:-}" == "1" ] && [ -n "${DEPLOY_BACKUP:-}" ] && [ -d "${DEPLOY_BACKUP:-}" ]; then
        log::warning "Deploy was interrupted -- restoring /config from pre-deploy backup"
        backup::restore "$DEPLOY_BACKUP" || log::error "Interrupted-deploy restore failed"
        DEPLOY_IN_PROGRESS=""
    fi
    utils::release-lock
    log::info "=== Git Pull session ended (PID $$) ==="
}

function utils::setup-credentials {
    if [ -z "$DEPLOYMENT_USER" ]; then
        return 0
    fi

    log::info "Setting up credential.helper for user: ${DEPLOYMENT_USER}"
    git config --system credential.helper 'store --file=/tmp/git-credentials'

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
