# sync_plugin

Studio plugin half of PA sync. Pairs with `tools/plugins/backend/sync`.

The project root must contain a `.psync` file whose contents are the numeric Roblox PlaceId. The plugin sends the open place's `game.PlaceId` to the backend, and the backend refuses all sync traffic unless the values match. The PA repository marker is `17309485731`. Copy the marker with the project when configuring another place, and change its contents to that place's PlaceId.

Sync disconnects during playtests and reconnects after returning to edit mode. This prevents playtest changes from being backsynced.

Install: copy `PASync.lua` into Studio's Plugins folder (Plugins tab > Plugins Folder), restart Studio, and allow HTTP requests to `127.0.0.1` when prompted.
