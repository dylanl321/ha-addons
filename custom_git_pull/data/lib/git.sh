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

    # Initialize git repo in-place instead of cloning into /config
    # git clone requires an empty directory, but /config is a Docker bind mount
    # that can't be fully emptied. git init + fetch + reset achieves the same
    # result and naturally preserves untracked files (secrets, .storage, etc.)
    log::info "Initializing git repository in /config..."

    cd /config || bashio::exit.nok "Cannot cd into /config"

    if ! git init; then
        log::error "git init failed -- restoring from backup"
        backup::restore "$backup_location"
        bashio::exit.nok "git init failed"
    fi

    log::info "Adding remote ${GIT_REMOTE} -> ${REPOSITORY}"
    if ! git remote add "$GIT_REMOTE" "$REPOSITORY"; then
        log::error "git remote add failed -- restoring from backup"
        rm -rf /config/.git
        backup::restore "$backup_location"
        bashio::exit.nok "git remote add failed"
    fi

    log::info "Fetching from ${GIT_REMOTE}..."
    if ! git fetch "$GIT_REMOTE"; then
        log::error "git fetch failed -- restoring from backup"
        rm -rf /config/.git
        backup::restore "$backup_location"
        bashio::exit.nok "git fetch failed, /config has been restored from backup"
    fi

    # Determine the branch to checkout
    local target_branch="${GIT_BRANCH:-main}"

    # Verify the branch exists on the remote
    if ! git rev-parse --verify "${GIT_REMOTE}/${target_branch}" &>/dev/null; then
        local available_branches
        available_branches=$(git branch -r | sed 's/^[[:space:]]*//' | tr '\n' ', ')
        log::error "Branch '${target_branch}' does not exist on remote '${GIT_REMOTE}'"
        log::error "Available remote branches: ${available_branches}"
        log::error "Update the git_branch setting in the addon configuration to match your repo"
        rm -rf /config/.git
        backup::restore "$backup_location"
        bashio::exit.nok "Branch '${target_branch}' not found. Available: ${available_branches}"
    fi

    log::info "Checking out branch ${target_branch}..."
    if ! git checkout -f -B "$target_branch" "${GIT_REMOTE}/${target_branch}"; then
        log::error "git checkout failed -- restoring from backup"
        rm -rf /config/.git
        backup::restore "$backup_location"
        bashio::exit.nok "git checkout failed, /config has been restored from backup"
    fi

    log::info "Git clone (init + fetch + checkout) complete"
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
