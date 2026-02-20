# Home Assistant Addon: Custom Git Pull

## How It Works

This addon synchronizes your Home Assistant `/config` directory with a git
repository. It runs inside a Docker container with `/config` mounted as a
read-write bind mount.

### The Core Problem

Home Assistant's `/config` directory contains two types of content:

1. **Your configuration files** -- `configuration.yaml`, `automations.yaml`,
   dashboards, packages, etc. These are what you commit to git.
2. **HA runtime state** -- `.storage/` (entity and device registries, auth
   tokens, area config, integrations), `secrets.yaml`, `home-assistant_v2.db`
   (history/state database), and `.cloud/` (Nabu Casa). These are created and
   managed by Home Assistant itself and must never be modified by git.

Every git command that updates the working tree (`pull`, `reset --hard`,
`checkout`) will overwrite any tracked file with the version from the
repository. If your repository happens to contain `.storage/`, `secrets.yaml`,
or any other HA runtime file, git will silently replace the live version with
whatever is in the repo -- which can be stale, empty, or wrong. This causes
Home Assistant to lose all of its state (users, integrations, entities, history)
and show the initial onboarding screen on next restart.

### The Solution: Move Out, Git, Move Back

Before any git command runs, we **physically move** the protected HA paths out
of `/config` into a temporary directory (`/tmp/.ha-protected/`). While they are
not in `/config`, it is impossible for any git command to read, modify, or
delete them. After git finishes -- whether it succeeded or failed -- we move
them back.

```
BEFORE GIT
  /config/.storage/          -->  /tmp/.ha-protected/.storage/
  /config/secrets.yaml       -->  /tmp/.ha-protected/secrets.yaml
  /config/home-assistant_v2.db --> /tmp/.ha-protected/home-assistant_v2.db
  /config/.cloud/            -->  /tmp/.ha-protected/.cloud/

GIT RUNS (clone, pull, reset -- whatever it needs to do)
  These four paths do not exist in /config, so git cannot touch them.

AFTER GIT
  /tmp/.ha-protected/.storage/     -->  /config/.storage/
  /tmp/.ha-protected/secrets.yaml  -->  /config/secrets.yaml
  /tmp/.ha-protected/home-assistant_v2.db --> /config/home-assistant_v2.db
  /tmp/.ha-protected/.cloud/       -->  /config/.cloud/
```

This happens on **every code path** -- success, failure, error recovery. The
move-back runs before the addon exits from any git operation.

### Protected Paths

| Path | What it contains |
|------|-----------------|
| `.storage/` | Entity registry, device registry, area registry, auth tokens, integration config, UI settings |
| `secrets.yaml` | Passwords, API keys, tokens referenced by `!secret` in config |
| `home-assistant_v2.db` | State history and long-term statistics database |
| `.cloud/` | Nabu Casa / Home Assistant Cloud connection state |

### Execution Flow

#### Startup

1. Container starts, loads addon configuration from Home Assistant.
2. Sets `git config --global pull.rebase false` (use merge strategy).
3. Sets up SSH key if configured (reads from addon config, reconstructs PEM
   format if needed, validates fingerprint).
4. Tests SSH connectivity to the git remote.

#### Sync Cycle

Each sync cycle (runs once, or repeats on an interval):

1. **Lock** -- Acquire a PID-based lock file to prevent overlapping runs.
2. **Check for existing repo** -- If `/config` is not a git working tree, run
   the initial clone flow. Otherwise run the sync flow.

#### Initial Clone (no existing git repo)

1. Back up all currently git-tracked files (there are none on first clone, so
   this is a no-op).
2. **Move protected paths out** of `/config`.
3. Remove any leftover `.git` directory from a previous failed attempt.
4. `git init` -- create a fresh repository.
5. Add `.git_pull_backups/` and log files to `.gitignore`.
6. `git remote add` -- point to the configured repository.
7. `git fetch` -- download all objects and refs.
8. Verify the configured branch exists on the remote.
9. `git checkout --orphan <branch>` -- create the branch without touching the
   working tree.
10. `git reset --hard <remote>/<branch>` -- update tracked files to match the
    remote. Because protected paths are not in `/config`, they cannot be
    overwritten even if the repo tracks them.
11. Set upstream tracking.
12. **Move protected paths back** into `/config`.
13. Validate HA configuration via `bashio::core.check`.

#### Regular Sync (existing git repo)

1. Verify the remote URL matches the configured repository.
2. Record the current commit SHA.
3. Back up all git-tracked files to `/config/.git_pull_backups/` (for rollback).
4. **Move protected paths out** of `/config`.
5. `git fetch` -- download new objects.
6. `git prune` if configured.
7. Switch branches if the configured branch differs from the current one.
8. Execute the configured git command:
   - **pull**: `git pull --no-rebase`. If this fails (e.g. merge conflict),
     abort the merge, reset tracked files to HEAD, and retry once.
   - **reset**: Log `git diff --stat` showing what will be discarded, then
     `git reset --hard <remote>/<branch>`.
9. **Move protected paths back** into `/config` (runs on both success and
   failure).
10. If the git operation failed, restore tracked files from the pre-sync backup.
11. Clean up old backups (keep the 3 most recent).

#### Configuration Validation

After a successful sync:

1. Compare old and new commit SHAs. If unchanged, stop.
2. Run `bashio::core.check` to validate the HA configuration.
3. If validation **fails**: revert to the previous commit with `git reset --hard`
   and log the diff. Do not restart HA.
4. If validation **passes** and `auto_restart` is enabled: check which files
   changed. If all changed files are in the `restart_ignore` list, skip
   restart. Otherwise, restart Home Assistant.

### Backup System

The backup system exists solely for **git-tracked files** (your config). It
does not back up or restore protected HA state -- that is handled entirely by
the move-out/move-back mechanism.

- Backups are stored in `/config/.git_pull_backups/` (persistent across
  container restarts).
- Only files listed by `git ls-files` are backed up, plus the current commit
  SHA.
- On restore, git is reset to the saved commit SHA and the tracked files are
  copied back.
- A maximum of 3 backups are retained.

### Logging

All output goes to both the addon's stdout (visible in the HA addon log panel)
and a persistent log file at `/config/.git_pull.log`. The log file rotates at
512KB, keeping 2 old copies.

---

## Installation

1. Add this repository to your Home Assistant addon store.
2. Find the "Custom Git Pull" addon and click it.
3. Click on the "INSTALL" button.

## Configuration

Addon configuration:

```yaml
repository: "git@github.com:user/HomeAssistantConfig.git"
git_branch: main
git_command: pull
git_remote: origin
git_prune: false
auto_restart: false
restart_ignore:
  - ui-lovelace.yaml
  - ".gitignore"
  - exampledirectory/
repeat:
  active: false
  interval: 300
deployment_user: ""
deployment_password: ""
deployment_key:
  - "your-entire-private-key-here"
deployment_key_protocol: rsa
```

### Option: `repository` (required)

Git URL to your repository (make sure to use double quotes).

### Option: `git_branch` (required)

Branch name of the Git repo. If left empty, the currently checked out branch
will be updated.

### Option: `git_remote` (required)

Name of the tracked repository. Leave this as `origin` if you are unsure.

### Option: `git_command` (required)

`pull`/`reset`: Command to run. Leave this as `pull` if you are unsure.

- `pull` -- Incorporates changes from a remote repository into the current
  branch. Will preserve any local changes to tracked files.
- `reset` -- Will execute `git reset --hard` and overwrite any local changes
  to tracked files and update from the remote repository.

### Option: `git_prune` (required)

`true`/`false`: If set to true, the addon will clean-up branches that are
deleted on the remote repository, but still have cached entries on the local
machine. Leave this as `false` if you are unsure.

### Option: `auto_restart` (required)

`true`/`false`: Restart Home Assistant when the configuration has changed (and
is valid).

### Option: `restart_ignore` (optional)

When `auto_restart` is enabled, changes to these files will not make HA
restart. Full directories to ignore can be specified.

### Option group: `repeat`

#### Option: `repeat.active` (required)

`true`/`false`: Enable/disable automatic polling.

#### Option: `repeat.interval` (required)

The interval in seconds to poll the repo for if automatic polling is enabled.

### Option: `deployment_user` (optional)

Username to use when authenticating to a repository with a username and
password.

### Option: `deployment_password` (optional)

Password to use when authenticating to a repository. Ignored if
`deployment_user` is not set.

### Option: `deployment_key` (optional)

A private SSH key that will be used for communication during Git operations.
This key is mandatory for ssh-accessed repositories, which are the ones with
the following pattern: `<user>@<host>:<repository path>`. This key has to be
created without a passphrase. You can paste the entire key as a single array
element -- the addon will automatically detect the format and reconstruct it.

### Option: `deployment_key_protocol` (optional)

The key protocol. Default is `rsa`. Valid protocols are:

- dsa
- ecdsa
- ed25519
- rsa
