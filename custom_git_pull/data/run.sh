#!/usr/bin/with-contenv bashio
# vim: ft=bash
# shellcheck shell=bash
set -o pipefail

# shellcheck disable=SC2034
CONFIG_PATH=/data/options.json
HOME=~

# Source library modules
# shellcheck source=lib/logging.sh
source /lib/logging.sh
# shellcheck source=lib/safety.sh
source /lib/safety.sh
# shellcheck source=lib/git.sh
source /lib/git.sh
# shellcheck source=lib/backup.sh
source /lib/backup.sh
# shellcheck source=lib/ssh.sh
source /lib/ssh.sh
# shellcheck source=lib/utils.sh
source /lib/utils.sh
# shellcheck source=lib/webhook.sh
source /lib/webhook.sh
# shellcheck source=lib/events.sh
source /lib/events.sh

################
# Load configuration
################

DEPLOYMENT_KEY=$(bashio::config 'deployment_key')
DEPLOYMENT_KEY_PROTOCOL=$(bashio::config 'deployment_key_protocol')
DEPLOYMENT_USER=$(bashio::config 'deployment_user')
DEPLOYMENT_PASSWORD=$(bashio::config 'deployment_password')
GIT_BRANCH=$(bashio::config 'git_branch')
GIT_COMMAND=$(bashio::config 'git_command')
GIT_REMOTE=$(bashio::config 'git_remote')
GIT_PRUNE=$(bashio::config 'git_prune')
DEPLOY_DELETE=$(bashio::config 'deploy_delete')
DEPLOY_DRY_RUN=$(bashio::config 'deploy_dry_run')
MIRROR_PROTECT_USER_DIRS=$(bashio::config 'mirror_protect_user_dirs')
ALLOW_LEGACY_CONFIG_GIT_DIR=$(bashio::config 'allow_legacy_config_git_dir')
PUSH_CUSTOM_COMPONENTS=$(bashio::config 'push_custom_components')
PUSH_ON_START=$(bashio::config 'push_on_start')
REPOSITORY=$(bashio::config 'repository')
AUTO_RESTART=$(bashio::config 'auto_restart')
RESTART_IGNORED_FILES=$(bashio::config 'restart_ignore | join(" ")')
REPEAT_ACTIVE=$(bashio::config 'repeat.active')
REPEAT_INTERVAL=$(bashio::config 'repeat.interval')
WEBHOOK_ENABLED=$(bashio::config 'webhook.enabled')
WEBHOOK_SECRET=$(bashio::config 'webhook.secret')
WEBHOOK_PORT=$(bashio::config 'webhook.port')

################
# Main
################

trap 'stdin::stop 2>/dev/null; webhook::stop 2>/dev/null; kill "$WEB_SERVER_PID" 2>/dev/null; utils::cleanup-on-exit' EXIT

git config --global pull.rebase false

cd /config || bashio::exit.nok "Failed to cd into /config"

log::init
safety::ensure-gitignore-entries

# Start web UI server
date +%s > /tmp/addon_start_ts
log::info "Starting web UI server on port 8099..."
python3 /web/server.py &
WEB_SERVER_PID=$!

log::info "Repository: ${REPOSITORY}"
log::info "Branch: ${GIT_BRANCH}"
log::info "Command: ${GIT_COMMAND}"
log::info "Auto restart: ${AUTO_RESTART}"
log::info "Deploy delete: ${DEPLOY_DELETE}"
if [ "$PUSH_CUSTOM_COMPONENTS" == "true" ]; then
    log::info "Push custom_components: ENABLED"
fi
if [ "$DEPLOY_DRY_RUN" == "true" ]; then
    log::info "Deploy dry run: ENABLED (no changes will be made)"
fi
if [ "$PUSH_ON_START" == "true" ]; then
    log::info "Push on start: ENABLED (local /config will be pushed to GitHub first)"
fi
log::info "Repeat: ${REPEAT_ACTIVE} (interval: ${REPEAT_INTERVAL}s)"
if [ "$WEBHOOK_ENABLED" == "true" ]; then
    log::info "Webhook: enabled (port: ${WEBHOOK_PORT})"
fi

if [ ! -d /config/.storage ]; then
    log::warning ".storage/ is missing from /config -- HA may show onboarding screen"
    log::warning "If this is unexpected, restore from a Home Assistant backup"
fi

if [ -d /config/.git ]; then
    if [ "$DEPLOY_DELETE" == "true" ] && [ "$ALLOW_LEGACY_CONFIG_GIT_DIR" != "true" ]; then
        log::fatal "Found /config/.git from a previous addon version or manual setup"
        log::fatal "Mirror mode (deploy_delete=true) is blocked while /config/.git exists"
        log::fatal "Either remove it (rm -rf /config/.git) or set allow_legacy_config_git_dir=true"
        bashio::exit.nok "Legacy /config/.git blocks mirror-mode deploy. See addon logs."
    else
        log::warning "Found /config/.git from a previous addon version or manual setup"
        log::warning "This addon uses a staging directory and does not need /config/.git"
        log::warning "Consider removing it: rm -rf /config/.git"
    fi
fi

cd / || true

if [ -n "$DEPLOYMENT_KEY" ]; then
    if ! ssh::setup-key; then
        log::fatal "SSH key setup failed -- cannot continue"
        bashio::exit.nok "SSH key setup failed. Check addon logs for details."
    fi
fi

DEPLOY_IN_PROGRESS=""

if [ "$PUSH_ON_START" == "true" ]; then
    if utils::acquire-lock; then
        ssh::check-connection
        utils::setup-credentials
        if ! git::push-config; then
            log::warning "push_on_start failed -- continuing with normal sync"
        fi
        utils::release-lock
    fi
fi

stdin::start

if [ "$WEBHOOK_ENABLED" == "true" ]; then
    log::info "Webhook: enabled on port ${WEBHOOK_PORT}"
    if [ -n "$WEBHOOK_SECRET" ] && [ "$WEBHOOK_SECRET" != "null" ]; then
        log::info "Webhook: HMAC-SHA256 signature verification enabled"
    else
        log::warning "Webhook: no secret configured -- requests will NOT be verified"
    fi
    webhook::start "$WEBHOOK_PORT" "$WEBHOOK_SECRET" &
    WEBHOOK_LISTENER_PID=$!
fi

function run::do-sync {
    if utils::acquire-lock; then
        ssh::check-connection
        utils::setup-credentials

        DEPLOY_BACKUP=""
        DEPLOY_IN_PROGRESS=""
        OLD_COMMIT=""
        NEW_COMMIT=""

        events::emit "sync_start" "trigger" "${SYNC_TRIGGER:-schedule}"
        local _sync_start_ts
        _sync_start_ts=$(date +%s)

        if git::synchronize; then
            if [ "$DEPLOY_DRY_RUN" == "true" ]; then
                log::info "Dry run complete. Disable deploy_dry_run to apply changes."
                events::emit "sync_complete" "dry_run" "true"
                utils::release-lock
                return 1
            fi
            if [ -n "${NEW_COMMIT:-}" ] && [ "${NEW_COMMIT:-}" != "${OLD_COMMIT:-}" ]; then
                local changed_files_list file_count files_detail _sync_duration
                changed_files_list=$(cd "$STAGING_DIR" 2>/dev/null && git diff --name-only "$OLD_COMMIT" "$NEW_COMMIT" 2>/dev/null | head -50 | tr '\n' ',' | sed 's/,$//')
                file_count=$(cd "$STAGING_DIR" 2>/dev/null && git diff --name-only "$OLD_COMMIT" "$NEW_COMMIT" 2>/dev/null | wc -l | tr -d ' ')
                files_detail=$(cd "$STAGING_DIR" 2>/dev/null && git diff --name-status "$OLD_COMMIT" "$NEW_COMMIT" 2>/dev/null | head -50 | awk '{print $1":"$2}' | tr '\n' ',' | sed 's/,$//')
                _sync_duration=$(( $(date +%s) - _sync_start_ts ))
                events::emit "sync_complete" \
                    "old_commit" "${OLD_COMMIT:-}" \
                    "new_commit" "${NEW_COMMIT:-}" \
                    "file_count" "${file_count:-0}" \
                    "files_changed" "${changed_files_list:-}" \
                    "files_detail" "${files_detail:-}" \
                    "duration" "${_sync_duration}"
                git::validate-config
            else
                local _sync_duration
                _sync_duration=$(( $(date +%s) - _sync_start_ts ))
                events::emit "sync_no_changes" "duration" "${_sync_duration}"
            fi
            git::push-local-changes
        else
            local _sync_duration
            _sync_duration=$(( $(date +%s) - _sync_start_ts ))
            events::emit "sync_failed" "error" "git synchronize failed" "duration" "${_sync_duration}"
        fi

        DEPLOY_IN_PROGRESS=""
        utils::release-lock
        date +%s > /tmp/last_sync_ts
    fi
    return 0
}

function run::check-restore-request {
    if [ -f /tmp/restore_request ]; then
        local restore_path
        restore_path=$(cat /tmp/restore_request)
        rm -f /tmp/restore_request
        if [ -d "$restore_path" ]; then
            log::info "Web UI: restore requested from ${restore_path}"
            if utils::acquire-lock; then
                backup::restore "$restore_path"
                events::emit "backup_restored" "path" "$restore_path"
                utils::release-lock
                log::info "Web UI: restore complete"
            fi
        else
            log::warning "Web UI: restore path does not exist: ${restore_path}"
        fi
    fi
}

SYNC_TRIGGER="startup"
run::do-sync || exit 0

if [ "$REPEAT_ACTIVE" != "true" ] && [ "$WEBHOOK_ENABLED" != "true" ]; then
    log::info "No repeat or webhook configured -- waiting for stdin triggers (hassio.addon_stdin)"
fi

while true; do
    run::check-restore-request

    if webhook::triggered; then
        log::info "Trigger received -- starting sync"
        SYNC_TRIGGER="webhook"
        run::do-sync || true
    fi

    if [ "$REPEAT_ACTIVE" == "true" ]; then
        local_interval=5
        elapsed=0
        while [ "$elapsed" -lt "$REPEAT_INTERVAL" ]; do
            run::check-restore-request
            if webhook::triggered; then
                log::info "Trigger received -- starting sync"
                SYNC_TRIGGER="webhook"
                run::do-sync || true
            fi
            sleep "$local_interval"
            elapsed=$((elapsed + local_interval))
        done
        log::info "Polling interval reached -- starting scheduled sync"
        SYNC_TRIGGER="schedule"
        run::do-sync || true
    else
        sleep 5
    fi
done
