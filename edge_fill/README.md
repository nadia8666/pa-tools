# edge fill

Edge Fill creates fence segments or trim pieces around a clicked surface perimeter. Fence mode uses a separately selected reference BasePart. Trim mode clones the clicked building part itself, preserving its properties and texture orientation. Select a surface to preview the generated pieces, adjust trim settings, then choose **Apply** to create the pieces as one undoable operation.

Fence mode uses the reference part's longest axis as its segment length, its middle axis as height (along the surface normal) and its shortest axis as thickness, with the front face pointing outward. Segments are full edge length and overlap at corners. Cylinder end caps are treated as 24-sided polygons (`CYLINDER_SIDES` in the script). Trim mode supports block and wedge surfaces, keeps the source part's rotation (tilted the minimum amount to the surface normal) so textures continue seamlessly, shortens pieces at corners so they never overlap, and exposes inset, width, height, and inward-facing texture/decal removal settings.

Generated parts are parented beside the source surface part. Preview parts are temporary and are not included in the applied operation.
