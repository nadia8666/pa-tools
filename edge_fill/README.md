# edge fill

Edge Fill creates fence segments or trim pieces around a clicked surface perimeter. Fence mode uses a separately selected reference BasePart. Trim mode clones the clicked building part itself, preserving its properties and texture orientation. Select a surface to preview the generated pieces, adjust trim settings, then choose **Apply** to create the pieces as one undoable operation.

Fence mode uses the reference part's longest axis as its segment length and points its LookVector outward. Segments overlap slightly at corners to prevent gaps. Cylinder end faces and curved side boundaries are approximated with 32 segments. Trim mode supports block and wedge surfaces, preserves the source building part's local texture orientation, shortens alternating edges to prevent corner overlaps, and exposes inset, width, height, and inward-facing texture/decal removal settings.

Generated parts are parented beside the source surface part. Preview parts are temporary and are not included in the applied operation.
