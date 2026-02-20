#!/usr/bin/env bash
# vim: ft=bash
# shellcheck shell=bash
# Git operations -- clone, synchronize, and config validation with rollback

SAFETY_SNAPSHOT="/tmp/.git_pull_protected_snapshot"

function git::remove-git-locks {
    [ -d /config/.git ] || return 0
    rm -f /config/.git/index.lock /config/.git/*.lock 2>/dev/null || true
}

function git::remove-git-dir {
    git::remove-git-locks
    rm -rf /config/.git 2>/dev/null || true
    if [ -d /config/.git ]; then
        log::warning "Could not fully remove /config/.git (e.g. lock held); continuing"
    fi
}

function git::clone {
    local backup_location
    backup_location=$(backup::create "pre-clone")
    if [ $? -ne 0 ] || [ -z "$backup_location" ]; then
        log::fatal "Cannot proceed with clone: backup failed"
        bashio::exit.nok "Clone aborted -- backup failed"
    fi

    safety::snapshot-protected-paths "$SAFETY_SNAPSHOT"
    backup::save-protected-paths "$backup_location" || true

    cd /config || bashio::exit.nok "Cannot cd into /config"

    if [ -d /config/.git ]; then
        log::info "Removing existing .git for clean clone (avoid bad object HEAD)"
        git::remove-git-dir
    fi

    log::info "Initializing git repository in /config..."

    if ! git init; then
        log::error "git init failed -- restoring from backup"
        backup::restore "$backup_location"
        bashio::exit.nok "git init failed"
    fi

    safety::ensure-gitignore-entries

    log::info "Adding remote ${GIT_REMOTE} -> ${REPOSITORY}"
    if ! git remote add "$GIT_REMOTE" "$REPOSITORY"; then
        log::error "git remote add failed -- restoring from backup"
        git::remove-git-dir
        backup::restore "$backup_location"
        bashio::exit.nok "git remote add failed"
    fi

    log::info "Fetching from ${GIT_REMOTE}..."
    if ! git fetch "$GIT_REMOTE"; then
        log::error "git fetch failed -- restoring from backup"
        git::remove-git-dir
        backup::restore "$backup_location"
        bashio::exit.nok "git fetch failed, /config has been restored from backup"
    fi

    local target_branch="${GIT_BRANCH:-main}"

    if ! git rev-parse --verify "${GIT_REMOTE}/${target_branch}" &>/dev/null; then
        local available_branches
        available_branches=$(git branch -r | sed 's/^[[:space:]]*//' | tr '\n' ', ')
        log::error "Branch '${target_branch}' does not exist on remote '${GIT_REMOTE}'"
        log::error "Available remote branches: ${available_branches}"
        log::error "Update the git_branch setting in the addon configuration to match your repo"
        git::remove-git-dir
        backup::restore "$backup_location"
        bashio::exit.nok "Branch '${target_branch}' not found. Available: ${available_branches}"
    fi

    # Back up any local files that the checkout would overwrite
    git::backup-conflicting-files "${GIT_REMOTE}/${target_branch}" "$backup_location"

    log::info "Checking out branch ${target_branch}..."
    git::remove-git-locks
    # Use checkout --orphan + reset --hard instead of checkout -f.
    # checkout -f from an empty branch wipes untracked files; reset --hard
    # only touches files tracked by the target commit.
    if ! git checkout --orphan "$target_branch"; then
        log::error "git checkout --orphan failed -- restoring from backup"
        git::remove-git-dir
        backup::restore "$backup_location"
        bashio::exit.nok "git checkout --orphan failed, /config has been restored from backup"
    fi

    if ! git reset --hard "${GIT_REMOTE}/${target_branch}"; then
        log::error "git reset --hard failed -- restoring from backup"
        git::remove-git-dir
        backup::restore "$backup_location"
        bashio::exit.nok "git reset failed, /config has been restored from backup"
    fi

    git branch --set-upstream-to="${GIT_REMOTE}/${target_branch}" "$target_branch" &>/dev/null || true

    if ! safety::verify-protected-paths "$SAFETY_SNAPSHOT" "initial clone checkout"; then
        log::fatal "Protected paths lost during clone -- restoring from backup"
        git::remove-git-dir
        backup::restore "$backup_location"
        bashio::exit.nok "Clone aborted -- protected HA state was destroyed"
    fi

    backup::restore-protected-paths-only "$backup_location"
    safety::ensure-gitignore-entries
    log::info "Git clone (init + fetch + checkout) complete"
}

function git::backup-conflicting-files {
    local remote_ref="$1"
    local backup_location="$2"

    cd /config || return 1

    local incoming_files
    incoming_files=$(git ls-tree -r --name-only "$remote_ref" 2>/dev/null)
    [ -z "$incoming_files" ] && return 0

    local conflict_dir="${backup_location}/.pre-checkout-conflicts"
    local conflicts=0

    while IFS= read -r file; do
        if [ -f "/config/${file}" ]; then
            local dir
            dir=$(dirname "$file")
            mkdir -p "${conflict_dir}/${dir}" 2>/dev/null
            if cp -a "/config/${file}" "${conflict_dir}/${file}"; then
                conflicts=$((conflicts + 1))
            fi
        fi
    done <<< "$incoming_files"

    if [ "$conflicts" -gt 0 ]; then
        log::warning "${conflicts} existing file(s) will be overwritten by checkout -- backed up to ${conflict_dir}"
    fi
}

function git::synchronize {
    if ! git rev-parse --is-inside-work-tree &>/dev/null; then
        log::warning "No git repository in /config -- performing initial clone"
        git::clone
        return
    fi

    log::info "Local git repository exists"

    local current_remote
    current_remote=$(git remote get-url --all "$GIT_REMOTE" | head -n 1)
    if [ "$current_remote" != "$REPOSITORY" ]; then
        log::fatal "Git origin '${current_remote}' does not match configured repository '${REPOSITORY}'"
        bashio::exit.nok "Remote mismatch -- fix addon configuration"
        return
    fi

    log::info "Git origin is correctly set to ${REPOSITORY}"
    OLD_COMMIT=$(git rev-parse HEAD)

    safety::snapshot-protected-paths "$SAFETY_SNAPSHOT"
    safety::log-untracked-inventory

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
            if ! git pull --no-rebase; then
                log::warning "Git pull failed, attempting to resolve..."

                git merge --abort &>/dev/null || true

                log::info "Resetting tracked files and retrying pull..."
                git reset --hard HEAD &>/dev/null || true

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
        log::error "Git operation failed -- restoring /config from backup"
        backup::restore "$backup_location"
        return 1
    fi

    if ! safety::verify-protected-paths "$SAFETY_SNAPSHOT" "git ${GIT_COMMAND}"; then
        log::fatal "Protected paths lost during git ${GIT_COMMAND} -- restoring from backup"
        backup::restore "$backup_location"
        return 1
    fi

    log::info "Git synchronize complete"
    backup::cleanup
}

function git::validate-config {
    log::info "Checking if anything changed..."

    if [ -z "${OLD_COMMIT:-}" ]; then
        log::info "Initial clone detected, skipping change comparison"
        log::info "Validating Home Assistant configuration..."
        if ! bashio::core.check; then
            log::error "Configuration check FAILED after initial clone"
            log::error "Fix your repository configuration before restarting HA"
            return 1
        fi
        log::info "Configuration check passed"
        return 0
    fi

    NEW_COMMIT=$(git rev-parse HEAD)
    if [ "$NEW_COMMIT" == "$OLD_COMMIT" ]; then
        log::info "Nothing has changed."
        return
    fi

    log::info "New commit: ${NEW_COMMIT} (was: ${OLD_COMMIT})"
    log::info "Validating Home Assistant configuration..."

    if ! bashio::core.check; then
        log::error "Configuration check FAILED after pulling new changes"

        log::warning "Reverting to previous commit ${OLD_COMMIT} to protect Home Assistant"
        local revert_diff
        revert_diff=$(git diff --stat HEAD "$OLD_COMMIT" 2>/dev/null)
        if [ -n "$revert_diff" ]; then
            log::info "Files being reverted:"
            while IFS= read -r line; do
                log::info "  ${line}"
            done <<< "$revert_diff"
        fi

        if git reset --hard "$OLD_COMMIT"; then
            log::info "Successfully reverted to ${OLD_COMMIT}"

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

    local do_restart="false"
    local changed_files
    changed_files=$(git diff "$OLD_COMMIT" "$NEW_COMMIT" --name-only)
    log::info "Changed files: ${changed_files}"

    if [ -n "$RESTART_IGNORED_FILES" ]; then
        for changed_file in $changed_files; do
            local is_ignored=""
            for ignored in $RESTART_IGNORED_FILES; do
                if [ -d "$ignored" ]; then
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
