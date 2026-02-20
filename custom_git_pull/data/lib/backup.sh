#!/usr/bin/env bash
# vim: ft=bash
# shellcheck shell=bash
# Backup and restore for config files via rsync.
# Uses the same exclude list as deploy so protected paths are never in backups.

BACKUP_DIR="/config/.git_pull_backups"
MAX_BACKUPS=3

function backup::create {
    local backup_label="${1:-manual}"
    local backup_location="${BACKUP_DIR}/config-${backup_label}-$(date +%Y-%m-%d_%H-%M-%S)"

    mkdir -p "${BACKUP_DIR}" || { log::error "Failed to create backup parent directory"; return 1; }
    mkdir -p "${backup_location}" || { log::error "Failed to create backup directory"; return 1; }

    log::info "Backing up /config to ${backup_location} (excluding protected paths)..."

    local rsync_args
    rsync_args=$(git::build-rsync-excludes)

    # shellcheck disable=SC2086
    if ! rsync -a --safe-links --no-owner --no-group \
        $rsync_args \
        /config/ "${backup_location}/" 2>/dev/null; then
        log::error "Backup rsync failed"
        rm -rf "${backup_location}"
        return 1
    fi

    local backup_size
    backup_size=$(du -sh "${backup_location}" | cut -f1)
    log::info "Backup complete: ${backup_location} (${backup_size})"
    echo "${backup_location}"
    return 0
}

function backup::restore {
    local backup_location="$1"

    if [ -z "$backup_location" ] || [ ! -d "$backup_location" ]; then
        log::error "Cannot restore: backup location '${backup_location}' does not exist"
        return 1
    fi

    log::warning "Restoring /config from backup: ${backup_location}"

    local rsync_args
    rsync_args=$(git::build-rsync-excludes)

    # shellcheck disable=SC2086
    if ! rsync -a --delete --safe-links --no-owner --no-group \
        $rsync_args \
        "${backup_location}/" /config/ 2>/dev/null; then
        log::error "Restore rsync failed"
        return 1
    fi

    log::info "Restore from backup complete"
    return 0
}

function backup::cleanup {
    if [ ! -d "$BACKUP_DIR" ]; then
        return
    fi

    local backup_count
    backup_count=$(find "$BACKUP_DIR" -maxdepth 1 -mindepth 1 -type d | wc -l)

    if [ "$backup_count" -gt "$MAX_BACKUPS" ]; then
        log::info "Cleaning up old backups (keeping newest ${MAX_BACKUPS})..."
        (cd "$BACKUP_DIR" && ls -1dt */ 2>/dev/null) | tail -n +$((MAX_BACKUPS + 1)) | while read -r d; do
            old_backup="${BACKUP_DIR}/${d%/}"
            log::info "Removing old backup: ${old_backup}"
            rm -rf "$old_backup"
        done
    fi
}
