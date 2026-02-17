#!/usr/bin/env bash
# vim: ft=bash
# shellcheck shell=bash
# Backup and restore functions for /config

BACKUP_DIR="/tmp/config-backups"
MAX_BACKUPS=3

function backup::create {
    local backup_label="${1:-manual}"
    local backup_location="${BACKUP_DIR}/config-${backup_label}-$(date +%Y-%m-%d_%H-%M-%S)"

    mkdir -p "${BACKUP_DIR}" || { log::error "Failed to create backup parent directory"; return 1; }
    mkdir "${backup_location}" || { log::error "Failed to create backup directory ${backup_location}"; return 1; }

    log::info "Backing up /config to ${backup_location} (including hidden files)"

    # cp -a preserves permissions, timestamps, symlinks, and the /. syntax includes hidden files
    if ! cp -a /config/. "${backup_location}/"; then
        log::error "Backup copy failed"
        rm -rf "${backup_location}"
        return 1
    fi

    # Verify backup is not empty
    local file_count
    file_count=$(find "${backup_location}" -maxdepth 1 | wc -l)
    if [ "$file_count" -le 1 ]; then
        log::error "Backup appears to be empty"
        rm -rf "${backup_location}"
        return 1
    fi

    # Verify key HA file exists in backup
    if [ -f /config/configuration.yaml ] && [ ! -f "${backup_location}/configuration.yaml" ]; then
        log::error "Backup is missing configuration.yaml despite it existing in /config"
        rm -rf "${backup_location}"
        return 1
    fi

    log::info "Backup complete: ${backup_location} ($(du -sh "${backup_location}" | cut -f1))"
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

    # Clear current /config contents (including hidden files)
    find /config -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true

    # Restore from backup
    if ! cp -a "${backup_location}/." /config/; then
        log::error "[CRITICAL] Failed to restore backup from ${backup_location} to /config!"
        log::error "[CRITICAL] Backup files remain at ${backup_location} -- manual recovery required"
        return 1
    fi

    # Verify the restore worked
    if [ -f "${backup_location}/configuration.yaml" ] && [ ! -f /config/configuration.yaml ]; then
        log::error "[CRITICAL] Restore completed but configuration.yaml is missing from /config!"
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
        find "$BACKUP_DIR" -maxdepth 1 -mindepth 1 -type d -printf '%T@ %p\n' \
            | sort -n \
            | head -n -"$MAX_BACKUPS" \
            | awk '{print $2}' \
            | while read -r old_backup; do
                log::info "Removing old backup: ${old_backup}"
                rm -rf "$old_backup"
            done
    fi
}
