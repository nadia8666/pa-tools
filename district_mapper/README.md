# districtMapper

A Roblox Studio plugin for authoring district footprints directly over the PA map.

## Install

Copy `districtMapper.lua` into Studio's Plugins folder, then restart Studio. The plugin appears under the PA Tools toolbar. The VS Code task button **install plugins** copies every PA Studio plugin into the Studio Plugins folder.

## Workflow

1. Open districtMapper and create a district group. A folder named after the group is created under `Workspace.DistrictMapperPreview`.
2. Select **Add points**, then click map surfaces in the 3D viewport to place boundary vertices.
3. Pause point placement, then select any number of vertex markers in boundary order. Use **Link selected points** to connect each selected point to the next and connect the last point back to the first.
4. The plugin detects a complete loop and generates its filled polygon automatically. Removing one of the loop's edges removes the fill; reconnecting it restores the fill.
5. Enter an extrusion height in studs and select **Extrude district**. Each extrusion is added as a separate mesh, so the same group can contain multiple extrusions.
6. Add more points to an already extruded group to create another outline or extend its current outline. Link the points into a closed boundary and extrude again; earlier extrusions remain intact.
7. Select **Export extruded districts** to upload each extrusion as a Roblox Mesh asset using `AssetService:CreateAssetAsync`, then create an asset-backed `MeshPart` in `Workspace.DistrictMapExported`. Each exported part stores its asset ID in the `DistrictMapperAssetId` attribute.

The link action toggles the selected boundary edges, so selecting the same ordered points and linking them again breaks those connections. A group can contain multiple independent closed sections. Each section is resolved separately and receives its own fill and extrusion; incomplete sections do not invalidate completed sections.

## Undo and redo

Creating groups, placing points, linking or unlinking points, and generating extrusions are recorded through Studio's ChangeHistoryService. Use Studio's normal Undo and Redo commands to reverse or restore these actions. Moving point markers with Studio's transform tools uses Studio's native undo history.

## Shared editing

Group folders, point markers, and edge guides are stored as Workspace instances with attributes describing their relationships. This is the shared source of truth rather than plugin-local tables. The plugin reconstructs its state when loaded, so groups survive widget close/reopen and plugin reload, and edits made by another Team Create collaborator are observed through the shared instances. Polygon fills and generated extrusion previews are rebuilt from saved geometry when the plugin reloads.

Point markers are ordinary anchored Parts. Moving a marker with Studio's transform tools updates its connected edge guides and polygon fill for all collaborators. An extrusion is invalidated when a point moves and must be generated again.

Generated meshes are stored in `Workspace.DistrictMapGenerated`. Exported asset-backed MeshParts are stored in `Workspace.DistrictMapExported` and remain in the place when the plugin is closed. Preview geometry remains under each group folder in `Workspace.DistrictMapperPreview`.

## Geometry

The outline triangulator supports simple concave polygons. Crossing edges, branches, disconnected outlines, and degenerate footprints are rejected rather than generating invalid geometry. Mesh generation uses `AssetService:CreateEditableMesh()` and `AssetService:CreateMeshPartAsync(Content.fromObject(editableMesh))`. Studio's EditableMesh permissions and API availability still apply.
