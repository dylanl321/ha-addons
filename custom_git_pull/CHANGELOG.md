# Changelog

## 3.1.0

- Exclude `custom_components/` from pull-deploy rsync so HACS-installed
  integrations are never overwritten by a git sync
- Add `push_custom_components` option to automatically commit and push
  instance-side `custom_components/` changes back to the git repository

## 1.0.0

- Initial release based on official git_pull addon v8.0.1
- Custom version for personal deployment
