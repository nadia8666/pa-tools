# sync backend

The pSync backend serves the Studio plugin over a local WebSocket. It only starts polling and reconciling project files after a Studio client sends its PlaceId and the project-root `.psync` marker matches that ID. The marker must contain only the numeric PlaceId. An absent, malformed, or mismatched marker causes the client to receive a sync-ignored status and prevents project synchronization.

The Studio plugin disconnects while a playtest is running. Reconnection after returning to edit mode performs a fresh tracked-script handshake.
