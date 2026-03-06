# Changelog

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
