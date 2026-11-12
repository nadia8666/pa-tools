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

The tag workflow validates the version, formats and analyzes Luau in Roblox mode using the Luau LSP PluginSecurity definitions, builds the Windows backends, packages the actual `.lua` and `.luau` source files, and publishes the GitHub Release.

## Release contents

Each GitHub Release uses the corresponding `.github/releases/<tag>.md` file as its complete description and attaches:

- `pa-combine.exe`
- `sync_backend.exe`
- `pa-tools-plugins.zip`

The plugin archive preserves the repository's plugin directory structure. It contains source files, not compiled `.luac` output.

## Release notes

Use the exact structure in `RELEASE_TEMPLATE.md`. Keep the full changelog link first, followed by release-specific descriptions and the complete tools table. The tools table is cumulative: every tool remains listed in future releases, including newly added tools.
