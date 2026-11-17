# pa-tools

Standalone repository for the Plus Architecture Studio plugins and their local backends.

See [RELEASING.md](RELEASING.md) for the versioned release process and [RELEASE_TEMPLATE.md](RELEASE_TEMPLATE.md) for the required release notes format.

# ui framework

`pa_tools/paTools.lua` owns the shared UI framework, exposed as `shared.paTools.ui` once `shared.paTools.ready` is true. It holds the pSync palette (`ui.colors`) and the builders every plugin panel uses: `create`, `corner`, `stroke`, `pad`, `stack`, `escape`, `page`, `card`, `section`, `floating`, `label`, `title`, `titleRow`, `scroller`, `button`, `input`, `output` and `progress`. Plugins wait for `shared.paTools`, read `local ui = shared.paTools.ui`, and build panels only from these helpers so every tool keeps the same look. New plugin UI should extend the framework in `paTools.lua` rather than defining its own helpers.

# ai

All of these plugins are programmed entirely by AI. pSync's sync layer was co-developed until functional. All future changes were done by AI.
