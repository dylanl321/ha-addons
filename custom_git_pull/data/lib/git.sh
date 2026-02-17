#!/usr/bin/env bash
# vim: ft=bash
# shellcheck shell=bash
# Git operations -- clone, synchronize, and config validation with rollback

function git::clone {
    # Create backup before any destructive operations
    local backup_location
    backup_location=$(backup::create "pre-clone")
    if [ $? -ne 0 ] || [ -z "$backup_location" ]; then
        log::fatal "Cannot proceed with clone: backup failed"
        bashio::exit.nok "Clone aborted -- backup failed"
    fi

    # Remove /config folder content (including hidden files)
    log::info "Clearing /config for fresh clone..."
    find /config -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true

    # Verify /config is actually empty before cloning
    local remaining
    remaining=$(find /config -mindepth 1 -maxdepth 1 | head -5)
    if [ -n "$remaining" ]; then
        log::error "Failed to fully clear /config, remaining items:"
        log::error "$remaining"
        log::error "Restoring from backup"
        backup::restore "$backup_location"
        bashio::exit.nok "/config could not be cleared for clone"
    fi

    # git clone
    log::info "Starting git clone of ${REPOSITORY}"
    if ! git clone "$REPOSITORY" /config; then
        log::error "Git clone failed -- restoring from backup"
        backup::restore "$backup_location"
        bashio::exit.nok "Git clone failed, /config has been restored from backup"
    fi

    # Restore non-git-tracked files from backup that HA needs
    log::info "Restoring non-repo files from backup..."

    # Restore secrets.yaml if it was in the backup but not in the repo
    if [ -f "${backup_location}/secrets.yaml" ] && [ ! -f /config/secrets.yaml ]; then
        cp -a "${backup_location}/secrets.yaml" /config/secrets.yaml
        log::info "Restored secrets.yaml from backup"
    fi

    # Restore hidden directories/files that are not part of the repo
    # (e.g. .storage, .cloud, .google_maps, etc.)
    for item in "${backup_location}"/.[!.]*; do
        [ -e "$item" ] || continue
        local name
        name=$(basename "$item")
        # Skip .git since we just cloned fresh
        [ "$name" = ".git" ] && continue
        # Skip our own log files
        [[ "$name" = .git_pull* ]] && continue
        # Only restore if it doesn't exist in the clone
        if [ ! -e "/config/${name}" ]; then
            cp -a "$item" "/config/${name}"
            log::info "Restored hidden item from backup: ${name}"
        fi
    done

    log::info "Git clone complete"
}

function git::synchronize {
    # is /config a local git repo?
    if ! git rev-parse --is-inside-work-tree &>/dev/null; then
        log::warning "No git repository in /config -- performing initial clone"
        git::clone
        return
    fi

    log::info "Local git repository exists"

    # Is the local repo set to the correct origin?
    local current_remote
    current_remote=$(git remote get-url --all "$GIT_REMOTE" | head -n 1)
    if [ "$current_remote" != "$REPOSITORY" ]; then
        log::fatal "Git origin '${current_remote}' does not match configured repository '${REPOSITORY}'"
        bashio::exit.nok "Remote mismatch -- fix addon configuration"
        return
    fi

    log::info "Git origin is correctly set to ${REPOSITORY}"
    OLD_COMMIT=$(git rev-parse HEAD)

    # Create a backup before any git operations that modify the working tree
    local backup_location
    backup_location=$(backup::create "pre-sync")
    if [ $? -ne 0 ] || [ -z "$backup_location" ]; then
        log::error "Backup failed, aborting sync to protect /config"
        return 1
    fi

    # Fetch
    log::info "Starting git fetch..."
    if ! git fetch "$GIT_REMOTE" "$GIT_BRANCH"; then
        log::error "Git fetch failed"
        return 1
    fi

    # Prune if configured
    if [ "$GIT_PRUNE" == "true" ]; then
        log::info "Starting git prune..."
        if ! git prune; then
            log::warning "Git prune failed, continuing anyway"
        fi
    fi

    # Branch checkout
    GIT_CURRENT_BRANCH=$(git rev-parse --symbolic-full-name --abbrev-ref HEAD)
    if [ -z "$GIT_BRANCH" ] || [ "$GIT_BRANCH" == "$GIT_CURRENT_BRANCH" ]; then
        log::info "Staying on branch: ${GIT_CURRENT_BRANCH}"
    else
        log::info "Switching to branch ${GIT_BRANCH}..."
        if ! git checkout "$GIT_BRANCH"; then
            log::error "Git checkout failed -- restoring from backup"
            git merge --abort &>/dev/null || true
            git checkout --force "$GIT_CURRENT_BRANCH" &>/dev/null || true
            backup::restore "$backup_location"
            return 1
        fi
        GIT_CURRENT_BRANCH=$(git rev-parse --symbolic-full-name --abbrev-ref HEAD)
    fi

    # Pull or reset
    local git_op_failed=false
    case "$GIT_COMMAND" in
        pull)
            log::info "Starting git pull..."
            if ! git pull; then
                log::error "Git pull failed"
                # Clean up any merge conflict state
                git merge --abort &>/dev/null || true
                git_op_failed=true
            fi
            ;;
        reset)
            log::info "Starting git reset..."
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
        log::error "Git operation failed -- restoring /config from backup"
        backup::restore "$backup_location"
        return 1
    fi

    log::info "Git synchronize complete"
    backup::cleanup
}

function git::validate-config {
    log::info "Checking if anything changed..."

    NEW_COMMIT=$(git rev-parse HEAD)
    if [ "$NEW_COMMIT" == "$OLD_COMMIT" ]; then
        log::info "Nothing has changed."
        return
    fi

    log::info "New commit: ${NEW_COMMIT} (was: ${OLD_COMMIT})"
    log::info "Validating Home Assistant configuration..."

    if ! bashio::core.check; then
        log::error "Configuration check FAILED after pulling new changes"

        # Revert to the old commit so HA stays on a known-good config
        log::warning "Reverting to previous commit ${OLD_COMMIT} to protect Home Assistant"
        if git reset --hard "$OLD_COMMIT"; then
            log::info "Successfully reverted to ${OLD_COMMIT}"

            # Verify the reverted config is actually good
            if bashio::core.check; then
                log::info "Reverted configuration passes validation"
            else
                log::error "Even the reverted configuration fails validation -- leaving as-is"
            fi
        else
            log::error "Failed to revert to ${OLD_COMMIT} -- config may be in a bad state"
        fi

        log::error "Do NOT restart until the upstream repo is fixed and a new sync succeeds"
        return 1
    fi

    log::info "Configuration check passed"

    if [ "$AUTO_RESTART" != "true" ]; then
        log::info "Local configuration has changed. Manual restart required."
        return
    fi

    # Determine if a restart is needed based on changed files vs ignored files
    local do_restart="false"
    local changed_files
    changed_files=$(git diff "$OLD_COMMIT" "$NEW_COMMIT" --name-only)
    log::info "Changed files: ${changed_files}"

    if [ -n "$RESTART_IGNORED_FILES" ]; then
        for changed_file in $changed_files; do
            local is_ignored=""
            for ignored in $RESTART_IGNORED_FILES; do
                if [ -d "$ignored" ]; then
                    set +e
                    is_ignored=$(echo "${changed_file}" | grep "^${ignored}")
                    set -e
                else
                    set +e
                    is_ignored=$(echo "${changed_file}" | grep "^${ignored}$")
                    set -e
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
