#!/usr/bin/env bash
# vim: ft=bash
# shellcheck shell=bash
# Git operations in staging directory + rsync deploy to /config.
# Git never runs inside /config. HA runtime state is never touched.

STAGING_DIR="/config/.git_sync_repo"

RSYNC_EXCLUDES=(
    ".storage/"
    "secrets.yaml"
    "home-assistant_v2.db"
    "home-assistant_v2.db-wal"
    "home-assistant_v2.db-shm"
    ".cloud/"
    "backups/"
    "tts/"
    "deps/"
    ".git/"
    ".git_sync_repo/"
    ".git_pull_backups/"
    ".git_pull.log"
    ".git_pull.log.*"
)

PREFLIGHT_PATTERNS='^(\.storage/|secrets\.yaml$|home-assistant_v2\.db(-wal|-shm)?$|\.cloud/)'

function git::build-rsync-excludes {
    local args=""
    for ex in "${RSYNC_EXCLUDES[@]}"; do
        args="${args} --exclude=${ex}"
    done
    echo "$args"
}

function git::preflight {
    cd "$STAGING_DIR" || return 1

    local violations
    violations=$(git ls-tree -r --name-only HEAD 2>/dev/null | grep -E "$PREFLIGHT_PATTERNS" || true)

    if [ -n "$violations" ]; then
        log::fatal "PREFLIGHT FAILED: repository tracks protected HA paths:"
        while IFS= read -r f; do
            log::fatal "  - ${f}"
        done <<< "$violations"
        log::fatal "Remove these files from your repository and add them to .gitignore."
        log::fatal "The addon will not deploy until this is fixed."
        return 1
    fi

    log::info "Preflight check passed (no protected paths in HEAD tree)"
    return 0
}

function git::deploy {
    log::info "Creating pre-deploy backup..."
    local backup_location
    backup_location=$(backup::create "pre-deploy")
    if [ $? -ne 0 ] || [ -z "$backup_location" ]; then
        log::error "Pre-deploy backup failed, aborting deploy"
        return 1
    fi

    log::info "Deploying from staging repo to /config via rsync..."

    local rsync_args
    rsync_args=$(git::build-rsync-excludes)

    local rsync_output
    # Phase 1: add and update files (no --delete)
    # shellcheck disable=SC2086
    if ! rsync_output=$(rsync -a --safe-links --no-owner --no-group \
        --delay-updates --itemize-changes \
        $rsync_args \
        "${STAGING_DIR}/" /config/ 2>&1); then
        log::error "rsync deploy failed: ${rsync_output}"
        log::warning "Restoring /config from pre-deploy backup..."
        backup::restore "$backup_location"
        return 1
    fi

    if [ -n "$rsync_output" ]; then
        local change_count
        change_count=$(echo "$rsync_output" | wc -l)
        log::info "Phase 1: deployed ${change_count} file change(s) to /config"
    else
        log::info "Phase 1: no file changes to deploy"
    fi

    DEPLOY_BACKUP="$backup_location"
    return 0
}

function git::clone {
    if [ -d "$STAGING_DIR/.git" ]; then
        log::info "Removing existing staging repo for clean clone"
        rm -rf "$STAGING_DIR"
    fi

    mkdir -p "$STAGING_DIR" || {
        log::error "Cannot create staging directory ${STAGING_DIR}"
        return 1
    }

    local target_branch="${GIT_BRANCH:-main}"

    log::info "Cloning ${REPOSITORY} (branch: ${target_branch}) into staging directory..."
    if ! git clone --branch "$target_branch" --single-branch "$REPOSITORY" "$STAGING_DIR"; then
        log::error "git clone failed"
        rm -rf "$STAGING_DIR"
        return 1
    fi

    log::info "Clone complete"

    if ! git::preflight; then
        return 1
    fi

    if ! git::deploy; then
        return 1
    fi

    return 0
}

function git::synchronize {
    if [ ! -d "$STAGING_DIR/.git" ]; then
        log::warning "No staging repo found -- performing initial clone"
        git::clone
        return
    fi

    cd "$STAGING_DIR" || {
        log::error "Cannot cd into staging directory"
        return 1
    }

    local current_remote
    current_remote=$(git remote get-url --all "$GIT_REMOTE" 2>/dev/null | head -n 1)
    if [ "$current_remote" != "$REPOSITORY" ]; then
        log::fatal "Staging repo remote '${current_remote}' does not match configured '${REPOSITORY}'"
        log::info "Removing stale staging repo and re-cloning..."
        rm -rf "$STAGING_DIR"
        git::clone
        return
    fi

    log::info "Staging repo remote matches: ${REPOSITORY}"
    OLD_COMMIT=$(git rev-parse HEAD)

    log::info "Starting git fetch..."
    if ! git fetch "$GIT_REMOTE" "$GIT_BRANCH"; then
        log::error "Git fetch failed -- /config is untouched"
        return 1
    fi

    if [ "$GIT_PRUNE" == "true" ]; then
        log::info "Starting git prune..."
        git remote prune "$GIT_REMOTE" || log::warning "Git prune failed, continuing anyway"
    fi

    GIT_CURRENT_BRANCH=$(git rev-parse --symbolic-full-name --abbrev-ref HEAD)
    if [ -n "$GIT_BRANCH" ] && [ "$GIT_BRANCH" != "$GIT_CURRENT_BRANCH" ]; then
        log::info "Switching to branch ${GIT_BRANCH}..."
        if ! git checkout "$GIT_BRANCH"; then
            log::error "Git checkout of branch ${GIT_BRANCH} failed -- /config is untouched"
            return 1
        fi
        GIT_CURRENT_BRANCH=$(git rev-parse --symbolic-full-name --abbrev-ref HEAD)
    else
        log::info "Staying on branch: ${GIT_CURRENT_BRANCH}"
    fi

    local git_op_failed=false
    case "$GIT_COMMAND" in
        pull)
            log::info "Starting git pull..."
            if ! git pull --no-rebase; then
                log::warning "Git pull failed, attempting to resolve..."
                git merge --abort &>/dev/null || true
                git reset --hard HEAD &>/dev/null || true

                log::info "Retrying pull..."
                if ! git pull --no-rebase; then
                    log::error "Git pull failed even after reset"
                    git merge --abort &>/dev/null || true
                    git_op_failed=true
                else
                    log::info "Git pull succeeded after reset"
                fi
            fi
            ;;
        reset)
            log::info "Starting git reset..."
            local diff_stat
            diff_stat=$(git diff --stat HEAD "${GIT_REMOTE}/${GIT_CURRENT_BRANCH}" 2>/dev/null)
            if [ -n "$diff_stat" ]; then
                log::info "Changes that will be discarded by reset:"
                while IFS= read -r line; do
                    log::info "  ${line}"
                done <<< "$diff_stat"
            fi
            if ! git reset --hard "$GIT_REMOTE"/"$GIT_CURRENT_BRANCH"; then
                log::error "Git reset failed"
                git_op_failed=true
            fi
            ;;
        *)
            log::error "Git command '${GIT_COMMAND}' is not valid. Must be 'pull' or 'reset'"
            git_op_failed=true
            ;;
    esac

    if [ "$git_op_failed" = true ]; then
        log::error "Git operation failed in staging repo -- /config is untouched"
        return 1
    fi

    if ! git::preflight; then
        return 1
    fi

    NEW_COMMIT=$(git rev-parse HEAD)
    if [ "$NEW_COMMIT" == "$OLD_COMMIT" ]; then
        log::info "No new commits. Nothing to deploy."
        return 0
    fi

    log::info "New commit: ${NEW_COMMIT} (was: ${OLD_COMMIT})"

    if ! git::deploy; then
        return 1
    fi

    log::info "Synchronize complete"
    backup::cleanup
    return 0
}

function git::validate-config {
    log::info "Validating Home Assistant configuration..."

    if ! bashio::core.check; then
        log::error "Configuration check FAILED after deploy"

        if [ -n "${DEPLOY_BACKUP:-}" ] && [ -d "${DEPLOY_BACKUP:-}" ]; then
            log::warning "Rolling back /config to pre-deploy state..."
            backup::restore "$DEPLOY_BACKUP"
            log::info "Rollback complete. /config restored to pre-deploy state."
        fi

        log::error "Fix your repository configuration before running again"
        return 1
    fi

    log::info "Configuration check passed"

    if [ "$AUTO_RESTART" != "true" ]; then
        log::info "Local configuration has changed. Manual restart required."
        return 0
    fi

    if [ -z "${OLD_COMMIT:-}" ] || [ -z "${NEW_COMMIT:-}" ] || [ "$OLD_COMMIT" == "$NEW_COMMIT" ]; then
        return 0
    fi

    local do_restart="false"
    local changed_files
    changed_files=$(cd "$STAGING_DIR" && git diff "$OLD_COMMIT" "$NEW_COMMIT" --name-only 2>/dev/null)
    log::info "Changed files: ${changed_files}"

    if [ -n "$RESTART_IGNORED_FILES" ]; then
        for changed_file in $changed_files; do
            local is_ignored=""
            for ignored in $RESTART_IGNORED_FILES; do
                if [ -d "/config/$ignored" ]; then
                    case "$changed_file" in
                        "${ignored}"|"${ignored}"/*) is_ignored=1 ;;
                        *) is_ignored="" ;;
                    esac
                else
                    case "$changed_file" in
                        "${ignored}") is_ignored=1 ;;
                        *) is_ignored="" ;;
                    esac
                fi
                if [ -n "$is_ignored" ]; then break; fi
            done
            if [ -z "$is_ignored" ]; then
                do_restart="true"
                log::info "Restart-required file changed: ${changed_file}"
            else
                log::info "Ignored file changed: ${changed_file}"
            fi
        done
    else
        do_restart="true"
    fi

    if [ "$do_restart" == "true" ]; then
        log::info "Restarting Home Assistant"
        bashio::core.restart
    else
        log::info "No restart required -- only ignored files changed"
    fi
}
