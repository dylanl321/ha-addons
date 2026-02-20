# Custom Git Pull Addon — Full Review (Logic, Safety, Commands)

## 1. Execution Flow Summary

```
run.sh
  └─ acquire lock → ssh check → credentials → git::synchronize → git::validate-config → release lock
       │
       ├─ No repo? → git::clone (init, fetch, orphan+reset, verify protected paths)
       └─ Has repo? → snapshot protected paths, log untracked inventory, backup::create
                      → fetch, [optional prune], [optional branch switch]
                      → pull (or reset with diff --stat logged)
                      → verify protected paths → backup::cleanup
```

## 2. Destructive Operations Audit

| Operation | Location | Touches untracked? | Safe? |
|-----------|----------|--------------------|-------|
| `git init` | git::clone | No | Yes |
| `rm -rf /config/.git` | clone error paths | Only .git | Yes |
| `git checkout --orphan` | git::clone | No (working tree unchanged) | Yes |
| `git reset --hard <ref>` | clone, sync pull/reset, validate-config | No — only tracked files; untracked "in the way" of a tracked path are removed (repo should not track .storage, secrets.yaml, etc.) | Yes |
| `git checkout` (branch switch) | git::synchronize | No | Yes |
| `git reset --hard HEAD` | pull retry path | No | Yes |
| `backup::restore` | on failure | No — only overwrites files that were in the backup (tracked + now protected paths in clone backup) | Yes |
| `backup::save-protected-paths` / restore of `.protected-paths` | clone backup/restore | N/A — copies protected paths into/from backup dir | Yes |

Conclusion: No command is intended to delete or overwrite untracked HA state (.storage, secrets.yaml, home-assistant_v2.db, .cloud) except by mistake; the clone path now backs up and restores protected paths so any failure path can restore them.

## 3. Safety Mechanisms

- **Protected path snapshot/verify**: Before destructive git ops we record which of `.storage`, `secrets.yaml`, `home-assistant_v2.db`, `.cloud` exist; after the op we verify they still exist; on failure we restore from backup and abort.
- **Pre-clone backup of protected paths**: On initial clone we copy those paths into `backup_location/.protected-paths/` so `backup::restore` can restore them if clone fails or verify fails.
- **Backup only tracked + protected**: `backup::create` backs up only `git ls-files` (+ .git-state); clone path also calls `backup::save-protected-paths`. Restore only overwrites those; it never wipes entire `/config`.
- **Persistent backup dir**: Backups live under `/config/.git_pull_backups/` so they survive container restarts.
- **Untracked inventory logging**: Before each sync we log untracked files and protected-path presence for diagnostics.

## 4. Logic Checks

- **Clone**: Orphan checkout then `reset --hard` ensures only files in the target commit are applied; untracked files are preserved. Upstream set with `git branch --set-upstream-to`.
- **Sync**: Remote URL must match config; backup created before fetch/pull/reset; on failure we restore and return; after success we verify protected paths then cleanup old backups.
- **Validate-config**: If config check fails after pull we revert with `git reset --hard $OLD_COMMIT` (tracked only); we log diff before reverting; we do not call `backup::restore` (git state is enough).
- **Restart-ignore**: Uses `case` for prefix/exact match so special characters in filenames (e.g. `.`, `*`) are not treated as regex.

## 5. Fixes Applied in This Review

1. **backup::cleanup portability**: Replaced `find ... -printf '%T@ %p\n'` (GNU-only) with `(cd "$BACKUP_DIR" && ls -1dt */)` so cleanup works on Alpine/Busybox.
2. **validate-config restart_ignore matching**: Replaced `grep "^${ignored}"` / `grep "^${ignored}$"` with `case "$changed_file" in ... esac` so literal paths with dots or other special characters are matched correctly.
3. **Clone backup of protected paths**: Added `backup::save-protected-paths` and call it in `git::clone` before any destructive step; `backup::restore` now restores `.protected-paths` (`.storage`, `secrets.yaml`, `home-assistant_v2.db`, `.cloud`) when present so a failed clone or verify can restore full HA state.
4. **Restore find exclusion**: Excluded `./.protected-paths/*` from the main restore `find` so protected-path data is only restored in the dedicated step.

## 6. Edge Cases and Assumptions

- **Empty pre-clone backup**: When there is no repo yet, `backup::create` returns a path with no tracked files; we still use it for `.pre-checkout-conflicts` and `.protected-paths`. Restore then restores only those.
- **GIT_PRUNE**: `git prune` runs in the object store; it does not touch the working tree. Safe.
- **Branch switch failure**: We `checkout --force` back to the previous branch and run `backup::restore`; no extra wipe of `/config`.
- **Lock**: Single lock file under `/tmp`; stale PID causes lock to be cleared so a new run can proceed.
- **Logging**: `stat -c%s` in `logging.sh` may be GNU-specific; if the image uses Busybox `stat`, rotation might behave differently; rotation is non-critical.

## 7. File-Level Summary

| File | Role |
|------|------|
| `run.sh` | Entrypoint, config load, lock, SSH, sync loop, sources all libs |
| `git.sh` | Clone (orphan+reset), sync (fetch/pull/reset), validate-config, backup-conflicting-files |
| `backup.sh` | create (tracked + .git-state), restore (tracked + .protected-paths), save-protected-paths, cleanup |
| `safety.sh` | snapshot/verify protected paths, log untracked inventory, ensure-gitignore-entries |
| `utils.sh` | Lock acquire/release, cleanup-on-exit, setup-credentials |
| `ssh.sh` | SSH key setup/validate, check-connection |
| `logging.sh` | Persistent log under /config, rotate by size |

All logic, safety, and commands have been validated and the above fixes applied.
