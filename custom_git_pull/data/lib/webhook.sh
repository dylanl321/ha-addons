#!/usr/bin/env bash
# vim: ft=bash
# shellcheck shell=bash
# Lightweight GitHub webhook listener using socat.
# Validates HMAC-SHA256 signatures when a secret is configured.

WEBHOOK_TRIGGER_FILE="/tmp/webhook_trigger"
WEBHOOK_PID_FILE="/tmp/webhook.pid"

function webhook::hmac-sha256 {
    local secret="$1" payload="$2"
    printf '%s' "$payload" | openssl dgst -sha256 -hmac "$secret" | sed 's/^.* //'
}

function webhook::verify-signature {
    local secret="$1" signature_header="$2" body="$3"

    if [ -z "$secret" ]; then
        return 0
    fi

    if [ -z "$signature_header" ]; then
        log::warning "Webhook: request missing X-Hub-Signature-256 header"
        return 1
    fi

    local expected
    expected="sha256=$(webhook::hmac-sha256 "$secret" "$body")"

    if [ "$signature_header" != "$expected" ]; then
        log::warning "Webhook: signature mismatch (request rejected)"
        return 1
    fi

    return 0
}

function webhook::handle-request {
    local port="$1" secret="$2"

    local request_line=""
    local content_length=0
    local signature_header=""
    local event_header=""

    read -r request_line

    local method path _
    read -r method path _ <<< "$request_line"

    while IFS= read -r header; do
        header="${header%%$'\r'}"
        [ -z "$header" ] && break

        local lower_header
        lower_header=$(echo "$header" | tr '[:upper:]' '[:lower:]')

        case "$lower_header" in
            content-length:*)
                content_length="${header#*: }"
                content_length="${content_length%%$'\r'}"
                ;;
            x-hub-signature-256:*)
                signature_header="${header#*: }"
                signature_header="${signature_header%%$'\r'}"
                ;;
            x-github-event:*)
                event_header="${header#*: }"
                event_header="${event_header%%$'\r'}"
                ;;
        esac
    done

    if [ "$method" != "POST" ]; then
        printf "HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        return
    fi

    local body=""
    if [ "$content_length" -gt 0 ] 2>/dev/null; then
        body=$(head -c "$content_length")
    fi

    if ! webhook::verify-signature "$secret" "$signature_header" "$body"; then
        printf "HTTP/1.1 403 Forbidden\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{\"error\":\"invalid signature\"}\n"
        return
    fi

    case "$event_header" in
        ping)
            log::info "Webhook: received ping event from GitHub"
            printf "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{\"ok\":true,\"event\":\"ping\"}\n"
            ;;
        push)
            local ref branch
            ref=$(echo "$body" | jq -r '.ref // empty' 2>/dev/null)
            branch="${ref#refs/heads/}"

            log::info "Webhook: received push event (branch: ${branch:-unknown})"

            if [ -n "$GIT_BRANCH" ] && [ -n "$branch" ] && [ "$branch" != "$GIT_BRANCH" ]; then
                log::info "Webhook: push was for branch '${branch}', not '${GIT_BRANCH}' -- ignoring"
                printf "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{\"ok\":true,\"skipped\":true,\"reason\":\"branch mismatch\"}\n"
                return
            fi

            touch "$WEBHOOK_TRIGGER_FILE"
            log::info "Webhook: sync triggered"
            printf "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{\"ok\":true,\"event\":\"push\",\"triggered\":true}\n"
            ;;
        *)
            log::info "Webhook: ignoring event '${event_header:-none}'"
            printf "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{\"ok\":true,\"ignored\":true}\n"
            ;;
    esac
}

function webhook::start {
    local port="$1" secret="$2"

    rm -f "$WEBHOOK_TRIGGER_FILE"

    log::info "Webhook: starting listener on port ${port}"

    while true; do
        socat "TCP-LISTEN:${port},reuseaddr,fork" \
            SYSTEM:"source /lib/logging.sh && source /lib/webhook.sh && GIT_BRANCH='${GIT_BRANCH}' webhook::handle-request '${port}' '${secret}'" \
            2>/dev/null &
        local socat_pid=$!
        echo "$socat_pid" > "$WEBHOOK_PID_FILE"
        wait "$socat_pid" 2>/dev/null || true
        log::warning "Webhook: listener exited, restarting in 2s..."
        sleep 2
    done
}

function webhook::stop {
    if [ -f "$WEBHOOK_PID_FILE" ]; then
        local pid
        pid=$(cat "$WEBHOOK_PID_FILE")
        kill "$pid" 2>/dev/null || true
        rm -f "$WEBHOOK_PID_FILE"
    fi
    rm -f "$WEBHOOK_TRIGGER_FILE"
}

function webhook::triggered {
    if [ -f "$WEBHOOK_TRIGGER_FILE" ]; then
        rm -f "$WEBHOOK_TRIGGER_FILE"
        return 0
    fi
    return 1
}
