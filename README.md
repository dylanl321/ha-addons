# Dylan's Home Assistant Custom Addons

Custom Home Assistant addons for personal use.

## Addons

- **[Custom Git Pull](/custom_git_pull/README.md)**

    Custom version of the Git Pull addon for syncing Home Assistant configuration from a Git repository.

## Installation

To use this repository, add it as a custom addon repository in Home Assistant:

1. Go to **Settings** > **Add-ons** > **Add-on Store**
2. Click the three-dot menu in the top right and select **Repositories**
3. Add this repository URL: `https://github.com/dylanl321/ha-addons`
4. Click **Add** and then **Close**
5. Refresh the page and the custom addons will appear in the store

## Development

Each addon lives in its own folder with:

- `config.yaml` - Addon metadata, options schema, and image reference
- `build.yaml` - Multi-architecture base image mappings
- `Dockerfile` - Container build instructions
- `data/` or `rootfs/` - Runtime scripts and filesystem overlay

Pushing to `main` triggers the CI workflow which builds Docker images for each changed addon and publishes them to GitHub Container Registry (GHCR).
