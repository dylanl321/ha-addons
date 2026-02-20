# Home Assistant Addon: Custom Git Pull

## How It Works

This addon synchronizes your Home Assistant `/config` directory with a git
repository. Git never operates inside `/config`. Instead, all git operations
happen in an isolated staging directory, and only your configuration files are
deployed to `/config` via `rsync` with explicit excludes.

### Architecture

```
/config/.git_sync_repo/     <-- git clone/pull/reset happen here (staging)
        |
        | rsync --exclude .storage/ --exclude secrets.yaml ...
        v
/config/                    <-- HA runtime state is never touched
```

1. **Clone/fetch/pull/reset** happen inside `/config/.git_sync_repo/`.
2. A **preflight check** verifies the repository does not track any protected
   HA paths (`.storage/`, `secrets.yaml`, `home-assistant_v2.db`, `.cloud/`).
   If it does, the addon refuses to deploy and logs an error.
3. **rsync** copies configuration files from the staging repo into `/config`,
   excluding all protected paths. HA runtime state stays in place untouched.
4. **Validation** runs `bashio::core.check` after deploy. If it fails, the
   addon rolls back `/config` to the pre-deploy state from a backup.

### Why This is Safe

- Git never runs inside `/config`. No git command can read, modify, or delete
  anything in `/config`.
- `rsync` with `--exclude` skips protected paths entirely. They are never read,
  copied, moved, or overwritten.
- No files are ever moved in or out of `/config`. HA runtime state stays in
  place at all times.
- A crash during git operations leaves `/config` untouched (git was operating
  in the staging directory).
- A crash during rsync leaves `/config` in a partially-updated state but
  protected paths are never affected (they are excluded).
- The preflight check blocks deployment if the repository tracks protected
  paths, providing a second layer of defense.

### Protected / Excluded Paths

These paths are excluded from rsync deploy and backup/restore. They are never
touched by the addon under any circumstances:

| Path | What it contains |
|------|-----------------|
| `.storage/` | Entity registry, device registry, area registry, auth tokens, integration config, UI settings |
| `secrets.yaml` | Passwords, API keys, tokens referenced by `!secret` in config |
| `home-assistant_v2.db` | State history and long-term statistics database |
| `home-assistant_v2.db-wal` | SQLite write-ahead log (companion to the database) |
| `home-assistant_v2.db-shm` | SQLite shared memory (companion to the database) |
| `.cloud/` | Nabu Casa / Home Assistant Cloud connection state |
| `backups/` | Home Assistant backup archives |
| `tts/` | Text-to-speech cache |
| `deps/` | Python dependency cache |

Additional addon-internal paths are also excluded:

| Path | Purpose |
|------|---------|
| `.git_sync_repo/` | The staging git repository |
| `.git_pull_backups/` | Pre-deploy backup snapshots |
| `.git_pull.log` | Persistent addon log |

### Execution Flow

#### Startup

1. Container starts, loads addon configuration.
2. Sets `git config --global pull.rebase false` (merge strategy).
3. Ensures `.gitignore` entries exist for addon-internal paths.
4. Warns if `.storage/` is missing (HA may show onboarding).
5. Sets up SSH key if configured (reads from addon config, reconstructs PEM
   format if needed, validates fingerprint).

#### Sync Cycle

Each sync cycle (runs once, or repeats on an interval):

1. **Lock** -- Acquire an `flock`-based lock. Automatically released on process
   death.
2. **Check for staging repo** -- If `/config/.git_sync_repo` does not exist,
   perform initial clone. Otherwise perform sync.

#### Initial Clone

1. `git clone --branch <branch> --single-branch <repo> /config/.git_sync_repo`
2. **Preflight**: verify HEAD tree does not contain protected paths.
3. **Backup**: rsync snapshot of current `/config` (minus excludes).
4. **Deploy**: rsync from staging to `/config` (minus excludes).
5. **Validate**: run `bashio::core.check`. Rollback on failure.

#### Regular Sync

1. Verify staging repo remote URL matches configuration.
2. `git fetch` in staging repo.
3. `git prune` if configured.
4. Branch switch if needed.
5. `git pull --no-rebase` or `git reset --hard` (depending on config).
6. **Preflight**: verify HEAD tree does not contain protected paths.
7. Compare old and new commit SHAs. If unchanged, skip deploy.
8. **Backup**: rsync snapshot of current `/config` (minus excludes).
9. **Deploy**: rsync from staging to `/config` (minus excludes).
10. **Validate**: run `bashio::core.check`. Rollback on failure.
11. If `auto_restart` enabled and relevant files changed, restart HA.

### Backup and Rollback

- Before each deploy, a backup is created by rsyncing `/config` (minus
  excluded paths) into `/config/.git_pull_backups/<timestamp>/`.
- On validation failure, the backup is rsynced back to `/config` with
  `--delete`, restoring the exact pre-deploy state.
- A maximum of 3 backups are retained.
- Backups never contain protected paths (same exclude list as deploy).

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
  branch. Will preserve any local changes to tracked files in the staging repo.
- `reset` -- Will execute `git reset --hard` in the staging repo and overwrite
  any local changes, then deploy to `/config`.

### Option: `git_prune` (required)

`true`/`false`: If set to true, the addon will clean-up branches that are
deleted on the remote repository. Leave this as `false` if you are unsure.

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
