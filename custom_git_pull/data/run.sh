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
REPOSITORY=$(bashio::config 'repository')
AUTO_RESTART=$(bashio::config 'auto_restart')
RESTART_IGNORED_FILES=$(bashio::config 'restart_ignore | join(" ")')
REPEAT_ACTIVE=$(bashio::config 'repeat.active')
REPEAT_INTERVAL=$(bashio::config 'repeat.interval')

################
# Main
################

trap utils::cleanup-on-exit EXIT

git config --global pull.rebase false

cd /config || bashio::exit.nok "Failed to cd into /config"

log::init
safety::ensure-gitignore-entries

log::info "Repository: ${REPOSITORY}"
log::info "Branch: ${GIT_BRANCH}"
log::info "Command: ${GIT_COMMAND}"
log::info "Auto restart: ${AUTO_RESTART}"
log::info "Deploy delete: ${DEPLOY_DELETE}"
if [ "$DEPLOY_DRY_RUN" == "true" ]; then
    log::info "Deploy dry run: ENABLED (no changes will be made)"
fi
log::info "Repeat: ${REPEAT_ACTIVE} (interval: ${REPEAT_INTERVAL}s)"

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

while true; do
    if utils::acquire-lock; then
        ssh::check-connection
        utils::setup-credentials

        DEPLOY_BACKUP=""
        DEPLOY_IN_PROGRESS=""
        OLD_COMMIT=""
        NEW_COMMIT=""

        if git::synchronize; then
            if [ "$DEPLOY_DRY_RUN" == "true" ]; then
                log::info "Dry run complete. Disable deploy_dry_run to apply changes."
                utils::release-lock
                exit 0
            fi
            if [ -n "${NEW_COMMIT:-}" ] && [ "${NEW_COMMIT:-}" != "${OLD_COMMIT:-}" ]; then
                git::validate-config
            fi
        fi

        DEPLOY_IN_PROGRESS=""
        utils::release-lock
    fi

    if [ "$REPEAT_ACTIVE" != "true" ]; then
        exit 0
    fi

    log::info "Next sync in ${REPEAT_INTERVAL} seconds"
    sleep "$REPEAT_INTERVAL"
done
