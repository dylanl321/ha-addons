#!/usr/bin/env bash
# vim: ft=bash
# shellcheck shell=bash
# SSH key management -- handles reading key from HA config array, formatting, and validation

function ssh::setup-key {
    if [ -z "$DEPLOYMENT_KEY" ]; then
        return 0
    fi

    log::info "Setting up SSH deployment key (protocol: ${DEPLOYMENT_KEY_PROTOCOL})"
    mkdir -p ~/.ssh
    chmod 700 ~/.ssh

    # Write SSH config
    cat > ~/.ssh/config <<-SSHCONFIG
Host *
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
    IdentityFile ${HOME}/.ssh/id_${DEPLOYMENT_KEY_PROTOCOL}
SSHCONFIG
    chmod 600 ~/.ssh/config

    # Build the key file from the config array
    # The HA config schema defines deployment_key as an array of strings.
    # bashio::config returns JSON for arrays, so we parse each element properly.
    local key_file="${HOME}/.ssh/id_${DEPLOYMENT_KEY_PROTOCOL}"
    rm -f "$key_file"

    local key_count
    key_count=$(bashio::config 'deployment_key | length')

    if [ "$key_count" -eq 0 ]; then
        log::warning "deployment_key is configured but empty"
        return 1
    fi

    log::info "Reading deployment key (${key_count} lines from config array)"

    local i
    for (( i=0; i<key_count; i++ )); do
        local line
        line=$(bashio::config "deployment_key[${i}]")
        echo "$line" >> "$key_file"
    done

    # Ensure the key file ends with a newline (required by OpenSSH)
    local last_char
    last_char=$(tail -c 1 "$key_file" 2>/dev/null | xxd -p)
    if [ "$last_char" != "0a" ] && [ -s "$key_file" ]; then
        echo "" >> "$key_file"
    fi

    chmod 600 "$key_file"

    # Validate the key
    if ! ssh::validate-key "$key_file"; then
        return 1
    fi

    log::info "SSH key written and validated: ${key_file}"
    return 0
}

function ssh::validate-key {
    local key_file="$1"

    if [ ! -f "$key_file" ]; then
        log::error "SSH key file does not exist: ${key_file}"
        return 1
    fi

    if [ ! -s "$key_file" ]; then
        log::error "SSH key file is empty: ${key_file}"
        return 1
    fi

    # Check that it looks like a PEM key (begins with -----BEGIN)
    local first_line
    first_line=$(head -n 1 "$key_file")
    if [[ ! "$first_line" =~ ^-----BEGIN ]]; then
        log::error "SSH key does not start with a valid PEM header"
        log::error "First line is: ${first_line}"
        log::error "This usually means the key was pasted incorrectly in the addon config."
        log::error "Each line of the key must be a separate entry in the deployment_key array."
        log::error "Example config:"
        log::error '  deployment_key:'
        log::error '    - "-----BEGIN OPENSSH PRIVATE KEY-----"'
        log::error '    - "b3BlbnNzaC1rZXktdjEAAAAABG5vbm..."'
        log::error '    - "-----END OPENSSH PRIVATE KEY-----"'
        return 1
    fi

    # Validate with ssh-keygen
    local keygen_output
    if ! keygen_output=$(ssh-keygen -l -f "$key_file" 2>&1); then
        log::error "SSH key failed validation (ssh-keygen -l): ${keygen_output}"
        log::error "The key may be corrupted, truncated, or in an unsupported format."

        # Try to give more specific diagnostics
        local line_count
        line_count=$(wc -l < "$key_file")
        log::error "Key file has ${line_count} lines"

        local last_line
        last_line=$(tail -n 1 "$key_file" | tr -d '[:space:]')
        if [[ ! "$last_line" =~ ^-----END ]]; then
            log::error "Key file does not end with a proper PEM footer (-----END ...-----)"
            log::error "Last non-empty line: ${last_line}"
        fi

        # Check for common formatting issues
        if grep -qP '\r' "$key_file" 2>/dev/null; then
            log::error "Key file contains Windows-style line endings (\\r\\n) -- stripping them"
            sed -i 's/\r$//' "$key_file"
            # Retry after fixing
            if ssh-keygen -l -f "$key_file" &>/dev/null; then
                log::info "Key is valid after stripping carriage returns"
                return 0
            fi
        fi

        # Check for leading/trailing whitespace on lines
        if grep -qP '^\s+\S|^\S.*\s+$' "$key_file" 2>/dev/null; then
            log::warning "Key lines contain leading or trailing whitespace -- cleaning"
            sed -i 's/^[[:space:]]*//;s/[[:space:]]*$//' "$key_file"
            if ssh-keygen -l -f "$key_file" &>/dev/null; then
                log::info "Key is valid after trimming whitespace"
                return 0
            fi
        fi

        return 1
    fi

    log::info "SSH key fingerprint: ${keygen_output}"
    return 0
}

function ssh::check-connection {
    if [ -z "$DEPLOYMENT_KEY" ]; then
        return 0
    fi

    local key_file="${HOME}/.ssh/id_${DEPLOYMENT_KEY_PROTOCOL}"

    # Make sure key is set up first
    if [ ! -f "$key_file" ]; then
        ssh::setup-key || return 1
    fi

    log::info "Testing SSH connection to git remote..."

    # Extract domain from repository URL (git@github.com:user/repo.git -> git@github.com)
    IFS=':' read -ra GIT_URL_PARTS <<< "$REPOSITORY"
    # shellcheck disable=SC2029
    local domain="${GIT_URL_PARTS[0]}"

    local output
    local exit_code
    output=$(ssh -T -o "StrictHostKeyChecking=no" -o "BatchMode=yes" -o "ConnectTimeout=10" "$domain" 2>&1)
    exit_code=$?

    # GitHub returns exit code 1 even on success, with a "successfully authenticated" message
    if [ $exit_code -eq 0 ]; then
        log::info "SSH connection to ${domain} successful"
        return 0
    elif [[ "$domain" = *"@github.com"* ]] && [[ "$output" = *"successfully authenticated"* ]]; then
        log::info "SSH connection to ${domain} successful (GitHub confirmed)"
        return 0
    elif [[ "$domain" = *"@gitlab.com"* ]] && [[ "$output" = *"Welcome to GitLab"* ]]; then
        log::info "SSH connection to ${domain} successful (GitLab confirmed)"
        return 0
    elif [[ "$domain" = *"@bitbucket.org"* ]] && [[ "$output" = *"logged in as"* ]]; then
        log::info "SSH connection to ${domain} successful (Bitbucket confirmed)"
        return 0
    fi

    log::error "SSH connection to ${domain} FAILED (exit code: ${exit_code})"
    log::error "SSH output: ${output}"

    # If key is already written, try re-writing it fresh from config
    log::warning "Attempting to re-setup SSH key from config..."
    if ssh::setup-key; then
        # Retry connection
        output=$(ssh -T -o "StrictHostKeyChecking=no" -o "BatchMode=yes" -o "ConnectTimeout=10" "$domain" 2>&1)
        exit_code=$?
        if [ $exit_code -eq 0 ] || \
           { [[ "$domain" = *"@github.com"* ]] && [[ "$output" = *"successfully authenticated"* ]]; } || \
           { [[ "$domain" = *"@gitlab.com"* ]] && [[ "$output" = *"Welcome to GitLab"* ]]; } || \
           { [[ "$domain" = *"@bitbucket.org"* ]] && [[ "$output" = *"logged in as"* ]]; }; then
            log::info "SSH connection succeeded after key re-setup"
            return 0
        fi
        log::error "SSH connection still failing after key re-setup"
        log::error "SSH retry output: ${output}"
    fi

    return 1
}
