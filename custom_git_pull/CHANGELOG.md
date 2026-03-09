# Changelog

## 3.5.1

- Add "Last Sync" detail card on dashboard showing result, duration, trigger,
  commit range, and file count
- Add "Files Changed" card on dashboard showing all files from the last sync
  with color-coded extension badges
- Add expandable file lists in sync history events (click "Show files" to view)
- Track sync duration in all events (sync_complete, sync_no_changes, sync_failed)
- Track no_changes count separately in stats
- Fix files_changed display: was showing raw comma string, now properly parsed

## 3.5.0

- Add interactive web UI accessible from the Home Assistant sidebar via ingress
- Dashboard: live status, sync stats, current commit/branch, recent commits
- History: filterable timeline of all sync events (syncs, deploys, backups,
  restores, webhooks, HA restarts)
- Backups: browse and restore backups directly from the UI
- Logs: color-coded log viewer with search filtering and auto-scroll
- Settings: full addon configuration from the web UI including toggle switches,
  SSH key editor with live validation, schedule, webhook, and deploy settings
- Structured event logging (JSON-lines) for all addon operations
- Sync Now button for on-demand pulls from the UI
- Light/dark mode support matching Home Assistant's design language
- Responsive design for mobile and desktop

## 3.4.1

- Fix push_on_start failing when remote has newer commits: now fetches and
  pulls before committing and pushing local changes
- Add `.cache/` to rsync excludes (HA runtime brand icon cache)
- Make push_on_start non-fatal: addon continues to normal sync if push fails

## 3.4.0

- Add stdin trigger support via `hassio.addon_stdin` -- the addon now always
  listens for commands (sync/trigger/pull) on stdin, enabling HA automations
  to trigger git sync without exposing extra ports
- Addon now always stays alive (no more exiting after one-shot sync) so it
  can receive stdin commands at any time
- Enable `stdin: true` in addon config

## 3.3.0

- Add `push_on_start` option to push local /config changes to GitHub before
  pulling, so HA UI edits and local changes are captured in the repository
- Change `boot` from `manual` to `auto` so the addon starts automatically
  with Home Assistant
- Fix addon stopping prematurely when webhook is the only keep-alive mechanism

## 3.2.0

- Add GitHub webhook support for instant sync on push
- New `webhook.enabled`, `webhook.secret`, and `webhook.port` config options
- Webhook validates GitHub HMAC-SHA256 signatures when a secret is configured
- Only triggers sync for pushes to the configured branch
- Can be combined with polling for fallback reliability

## 3.1.0

- Exclude `custom_components/` from pull-deploy rsync so HACS-installed
  integrations are never overwritten by a git sync
- Add `push_custom_components` option to automatically commit and push
  instance-side `custom_components/` changes back to the git repository

## 1.0.0

- Initial release based on official git_pull addon v8.0.1
- Custom version for personal deployment
