#!/usr/bin/env bash
# vim: ft=bash
# shellcheck shell=bash
# Backup and restore for git-tracked files only.

BACKUP_DIR="/config/.git_pull_backups"
MAX_BACKUPS=3

function backup::create {
    local backup_label="${1:-manual}"
    local backup_location="${BACKUP_DIR}/config-${backup_label}-$(date +%Y-%m-%d_%H-%M-%S)"

    mkdir -p "${BACKUP_DIR}" || { log::error "Failed to create backup parent directory"; return 1; }
    mkdir "${backup_location}" || { log::error "Failed to create backup directory ${backup_location}"; return 1; }

    cd /config || { log::error "Cannot cd into /config"; return 1; }

    if ! git rev-parse --is-inside-work-tree &>/dev/null; then
        log::info "No git repo yet -- skipping tracked-file backup"
        echo "${backup_location}"
        return 0
    fi

    log::info "Backing up git-tracked files to ${backup_location}"

    local file_list
    file_list=$(git ls-files 2>/dev/null)

    if [ -z "$file_list" ]; then
        log::info "No tracked files to back up"
        echo "${backup_location}"
        return 0
    fi

    while IFS= read -r file; do
        [ -f "$file" ] || continue
        local dir
        dir=$(dirname "$file")
        mkdir -p "${backup_location}/${dir}" 2>/dev/null
        cp -a "$file" "${backup_location}/${file}" || log::warning "Failed to copy ${file}"
    done <<< "$file_list"

    if [ -f /config/.git/HEAD ]; then
        mkdir -p "${backup_location}/.git-state"
        cp /config/.git/HEAD "${backup_location}/.git-state/HEAD" 2>/dev/null
        git rev-parse HEAD > "${backup_location}/.git-state/commit-sha" 2>/dev/null
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

    log::warning "Restoring git-tracked files from backup: ${backup_location}"

    cd /config || { log::error "Cannot cd into /config"; return 1; }

    if [ -f "${backup_location}/.git-state/commit-sha" ] && git rev-parse --is-inside-work-tree &>/dev/null; then
        local old_sha
        old_sha=$(cat "${backup_location}/.git-state/commit-sha")
        if [ -n "$old_sha" ] && git rev-parse --verify "$old_sha" &>/dev/null; then
            log::info "Resetting git to pre-sync commit ${old_sha}"
            git reset --hard "$old_sha" &>/dev/null || log::warning "git reset to ${old_sha} failed"
        fi
    fi

    local restored=0
    while IFS= read -r file; do
        [ -f "${backup_location}/${file}" ] || continue
        local dir
        dir=$(dirname "$file")
        mkdir -p "/config/${dir}" 2>/dev/null
        if cp -a "${backup_location}/${file}" "/config/${file}"; then
            restored=$((restored + 1))
        else
            log::warning "Failed to restore ${file}"
        fi
    done < <(cd "${backup_location}" && find . -type f -not -path './.git-state/*' | sed 's|^\./||')

    log::info "Restored ${restored} tracked files from backup"
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
