#!/usr/bin/env bash
# vim: ft=bash
# shellcheck shell=bash
# Persistent logging module -- writes to both bashio log and a rotating log file in /config

LOG_FILE="/config/.git_pull.log"
LOG_MAX_SIZE=524288  # 512KB before rotation
LOG_BACKUP_COUNT=2   # keep .log.1 and .log.2

function log::init {
    # Ensure log file exists and is writable
    touch "$LOG_FILE" 2>/dev/null || {
        bashio::log.warning "[Warn] Cannot write to ${LOG_FILE}, persistent logging disabled"
        LOG_FILE="/dev/null"
        return
    }
    log::rotate
    log::info "=== Git Pull session started (PID $$) ==="
}

function log::rotate {
    [ "$LOG_FILE" = "/dev/null" ] && return
    [ ! -f "$LOG_FILE" ] && return

    local size
    size=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)

    if [ "$size" -ge "$LOG_MAX_SIZE" ]; then
        # Shift old logs: .log.2 -> delete, .log.1 -> .log.2, .log -> .log.1
        local i
        for (( i=LOG_BACKUP_COUNT; i>1; i-- )); do
            [ -f "${LOG_FILE}.$((i-1))" ] && mv -f "${LOG_FILE}.$((i-1))" "${LOG_FILE}.${i}"
        done
        mv -f "$LOG_FILE" "${LOG_FILE}.1"
        : > "$LOG_FILE"
    fi
}

function log::_write {
    local level="$1"
    shift
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local message="[${timestamp}] [${level}] $*"

    # Write to persistent log file
    if [ "$LOG_FILE" != "/dev/null" ]; then
        echo "$message" >> "$LOG_FILE" 2>/dev/null
    fi
}

function log::info {
    bashio::log.info "$*"
    log::_write "INFO" "$*"
}

function log::warning {
    bashio::log.warning "$*"
    log::_write "WARN" "$*"
}

function log::error {
    bashio::log.error "$*"
    log::_write "ERROR" "$*"
}

function log::fatal {
    bashio::log.fatal "$*"
    log::_write "FATAL" "$*"
}
