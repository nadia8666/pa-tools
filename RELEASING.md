# Releasing

Releases are published from version tags on `main`. Ask for a release explicitly after the requested plugin changes are complete; ordinary plugin changes do not create releases or tags.

## Release procedure

1. Finish the requested plugin changes and merge them into `main`.
2. Run CI on the exact `main` commit to be released and require it to pass.
3. Choose the next semantic version tag in the form `vMAJOR.MINOR.PATCH`.
4. Create `.github/releases/<tag>.md` from [`RELEASE_TEMPLATE.md`](RELEASE_TEMPLATE.md).
5. Replace the unique-changes placeholder with concise, user-facing descriptions of the actual changes in that release. Mention new tools and meaningful plugin behavior changes; do not repeat generic implementation details.
6. Replace `TAG` in the changelog URL with the tag, or leave it for the workflow to substitute.
7. If a new plugin is introduced, add its filename and stable description to the tools table in `RELEASE_TEMPLATE.md`. Include it in the current release notes and retain it in all future release notes.
8. Commit the release notes, then create and push the version tag at that same commit.

The tag workflow validates the version, formats and analyzes Luau in Roblox mode using the Luau LSP PluginSecurity definitions, builds the Windows backends, stages the release's plugin source files under their canonical filenames, and publishes the GitHub Release.

## Release contents

Each GitHub Release attaches these seven files individually at the top level, in this order:

1. `pa-combine.exe`
2. `sync_backend.exe`
3. `paTools.lua`
4. `PASync.lua`
5. `combinePlugin.lua`
6. `districtMapper.lua`
7. `holeCutter.lua`

The plugin source assets are the actual `.lua` files, not compiled `.luac` output. No plugin ZIP is generated.

## Release notes

Use the exact structure in `RELEASE_TEMPLATE.md`. Keep the full changelog link first, followed by release-specific descriptions and the complete tools table. The tools table is cumulative: every tool remains listed in future releases, including newly added tools.
