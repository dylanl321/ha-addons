#!/usr/bin/env bash
# vim: ft=bash
# shellcheck shell=bash
# SSH key management -- handles reading key from HA config array, formatting, and validation

# Known PEM header/footer patterns (without dashes, spaces collapsed)
# Used to detect and reconstruct mangled keys
declare -a SSH_KEY_TYPES=(
    "OPENSSH PRIVATE KEY"
    "RSA PRIVATE KEY"
    "DSA PRIVATE KEY"
    "EC PRIVATE KEY"
    "PRIVATE KEY"
)

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

    local key_file="${HOME}/.ssh/id_${DEPLOYMENT_KEY_PROTOCOL}"
    rm -f "$key_file"

    # Read all array elements and concatenate into raw key material
    local key_count
    key_count=$(bashio::config 'deployment_key | length')

    if [ "$key_count" -eq 0 ]; then
        log::warning "deployment_key is configured but empty"
        return 1
    fi

    log::info "Reading deployment key (${key_count} elements from config array)"

    local raw_key=""
    local i
    for (( i=0; i<key_count; i++ )); do
        local line
        line=$(bashio::config "deployment_key[${i}]")
        if [ -n "$raw_key" ]; then
            raw_key="${raw_key}
${line}"
        else
            raw_key="$line"
        fi
    done

    # Attempt to write a valid key file from whatever we received
    if ! ssh::reconstruct-key "$raw_key" "$key_file"; then
        log::error "Failed to reconstruct a valid SSH key from the provided config"
        return 1
    fi

    chmod 600 "$key_file"

    # Validate the key
    if ! ssh::validate-key "$key_file"; then
        return 1
    fi

    log::info "SSH key written and validated: ${key_file}"
    return 0
}

function ssh::reconstruct-key {
    local raw="$1"
    local output_file="$2"

    # First, try writing as-is -- if the key was provided line-by-line correctly
    # it will already be in valid PEM format
    echo "$raw" > "$output_file"
    if ssh-keygen -l -f "$output_file" &>/dev/null; then
        log::info "Key is already in valid format"
        return 0
    fi

    log::info "Key is not in standard PEM format, attempting reconstruction..."

    # Collapse everything into a single string for pattern matching
    # Remove all newlines, carriage returns, and collapse spaces
    local flat
    flat=$(echo "$raw" | tr -d '\n\r' | tr -s ' ')

    # Try to find and extract the key type from known PEM headers
    local key_type=""
    local header=""
    local footer=""

    for type in "${SSH_KEY_TYPES[@]}"; do
        # Build patterns with and without spaces (HA config can strip spaces)
        local type_nospace="${type// /}"
        local begin_spaced="-----BEGIN ${type}-----"
        local end_spaced="-----END ${type}-----"
        local begin_nospace="-----BEGIN${type_nospace}-----"
        local end_nospace="-----END${type_nospace}-----"

        if [[ "$flat" == *"$begin_spaced"* ]]; then
            key_type="$type"
            header="$begin_spaced"
            footer="$end_spaced"
            break
        elif [[ "$flat" == *"$begin_nospace"* ]]; then
            key_type="$type"
            # Use the nospace version for extraction but write proper headers
            header="$begin_nospace"
            footer="$end_nospace"
            break
        fi
    done

    if [ -z "$key_type" ]; then
        log::error "Could not identify SSH key type from input"
        log::error "Expected a PEM key with -----BEGIN ... PRIVATE KEY----- header"
        return 1
    fi

    log::info "Detected key type: ${key_type}"

    # Extract the base64 body between header and footer
    local body
    body="${flat#*"$header"}"
    body="${body%"$footer"*}"

    # Strip all whitespace from the body to get pure base64
    body=$(echo "$body" | tr -d ' \t')

    if [ -z "$body" ]; then
        log::error "Key body is empty after extracting between header and footer"
        return 1
    fi

    # Write the properly formatted key
    local proper_header="-----BEGIN ${key_type}-----"
    local proper_footer="-----END ${key_type}-----"

    {
        echo "$proper_header"
        # Fold base64 body into 70-character lines (OpenSSH standard)
        echo "$body" | fold -w 70
        echo "$proper_footer"
    } > "$output_file"

    local line_count
    line_count=$(wc -l < "$output_file")
    log::info "Reconstructed key: ${line_count} lines (type: ${key_type})"

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
        return 1
    fi

    # Strip carriage returns before validation
    sed -i 's/\r$//' "$key_file" 2>/dev/null
    # Strip leading/trailing whitespace from lines
    sed -i 's/^[[:space:]]*//;s/[[:space:]]*$//' "$key_file" 2>/dev/null

    # Validate with ssh-keygen
    local keygen_output
    if ! keygen_output=$(ssh-keygen -l -f "$key_file" 2>&1); then
        log::error "SSH key failed validation: ${keygen_output}"
        log::error "The key may be corrupted, truncated, or in an unsupported format."

        local line_count
        line_count=$(wc -l < "$key_file")
        log::error "Key file has ${line_count} lines"

        # Show first and last lines for debugging
        log::error "First line: $(head -n 1 "$key_file")"
        log::error "Last line: $(tail -n 1 "$key_file")"

        log::error "Ensure your deployment_key contains the complete private key."
        log::error "You can paste the entire key as a single entry -- the addon"
        log::error "will automatically detect and reformat it."
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
