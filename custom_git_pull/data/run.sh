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
# shellcheck source=lib/backup.sh
source /lib/backup.sh
# shellcheck source=lib/ssh.sh
source /lib/ssh.sh
# shellcheck source=lib/utils.sh
source /lib/utils.sh
# shellcheck source=lib/git.sh
source /lib/git.sh

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

cd /config || bashio::exit.nok "Failed to cd into /config"

log::init

log::info "Repository: ${REPOSITORY}"
log::info "Branch: ${GIT_BRANCH}"
log::info "Command: ${GIT_COMMAND}"
log::info "Auto restart: ${AUTO_RESTART}"
log::info "Repeat: ${REPEAT_ACTIVE} (interval: ${REPEAT_INTERVAL}s)"

# One-time SSH key setup and validation on startup
if [ -n "$DEPLOYMENT_KEY" ]; then
    if ! ssh::setup-key; then
        log::fatal "SSH key setup failed -- cannot continue"
        bashio::exit.nok "SSH key setup failed. Check addon logs for details."
    fi
fi

while true; do
    if utils::acquire-lock; then
        # Verify SSH connectivity each cycle (re-setup if needed)
        ssh::check-connection
        utils::setup-credentials

        if git::synchronize; then
            git::validate-config
        fi

        utils::release-lock
    fi

    if [ "$REPEAT_ACTIVE" != "true" ]; then
        exit 0
    fi

    log::info "Next sync in ${REPEAT_INTERVAL} seconds"
    sleep "$REPEAT_INTERVAL"
done
