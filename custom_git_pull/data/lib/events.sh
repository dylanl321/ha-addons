#!/usr/bin/env bash
# vim: ft=bash
# shellcheck shell=bash
# Structured event logging -- writes JSON-lines to /data/events.jsonl
# Events are consumed by the web UI for history, stats, and dashboards.

EVENTS_FILE="/data/events.jsonl"
EVENTS_MAX_LINES=1000

function events::emit {
    local type="$1"
    shift

    local ts
    ts=$(date +%s)

    # Build JSON using jq for safe escaping
    local json
    json=$(jq -n --arg type "$type" --argjson ts "$ts" '{ts: $ts, type: $type}')

    # Add key-value pairs from remaining arguments
    while [ $# -ge 2 ]; do
        json=$(echo "$json" | jq --arg k "$1" --arg v "$2" '. + {($k): $v}')
        shift 2
    done

    echo "$json" >> "$EVENTS_FILE"
    events::rotate
}

function events::rotate {
    [ ! -f "$EVENTS_FILE" ] && return
    local lines
    lines=$(wc -l < "$EVENTS_FILE" 2>/dev/null || echo 0)
    if [ "$lines" -gt "$EVENTS_MAX_LINES" ]; then
        tail -n 800 "$EVENTS_FILE" > "${EVENTS_FILE}.tmp"
        mv "${EVENTS_FILE}.tmp" "$EVENTS_FILE"
    fi
}
