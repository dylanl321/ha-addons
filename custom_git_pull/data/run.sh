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
log::info "Repeat: ${REPEAT_ACTIVE} (interval: ${REPEAT_INTERVAL}s)"

if [ ! -d /config/.storage ]; then
    log::warning ".storage/ is missing from /config -- HA may show onboarding screen"
    log::warning "If this is unexpected, restore from a Home Assistant backup"
fi

if [ -n "$DEPLOYMENT_KEY" ]; then
    if ! ssh::setup-key; then
        log::fatal "SSH key setup failed -- cannot continue"
        bashio::exit.nok "SSH key setup failed. Check addon logs for details."
    fi
fi

while true; do
    if utils::acquire-lock; then
        ssh::check-connection
        utils::setup-credentials

        DEPLOY_BACKUP=""
        OLD_COMMIT=""
        NEW_COMMIT=""

        if git::synchronize; then
            if [ -n "${NEW_COMMIT:-}" ] && [ "${NEW_COMMIT:-}" != "${OLD_COMMIT:-}" ]; then
                git::validate-config
            fi
        fi

        utils::release-lock
    fi

    if [ "$REPEAT_ACTIVE" != "true" ]; then
        exit 0
    fi

    log::info "Next sync in ${REPEAT_INTERVAL} seconds"
    sleep "$REPEAT_INTERVAL"
done
