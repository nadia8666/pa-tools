# hole cutter

Hole Cutter uses the shared `PA Tools` toolbar to mark groups of cuttable BaseParts, place and duplicate cutter parts, apply all cutters to all parts in a group, and merge aligned block parts.

Select any number of parts and choose **Mark Cuttable** to assign a new `HoleCutterGroupId` GUID attribute. Choose **Add Cutter** and click one of the marked parts to create an archivable cutter under the current camera. Duplicate and move or rotate cutters as needed. Every cutter carrying the same group ID participates in the next **Apply Holes** operation. The group ID attribute can also be copied to additional parts.

Cutter validity is checked once per second when a target or cutter transform or size changes. Blue indicates unchecked or checking, green indicates a valid subtraction, and red indicates a failed subtraction. Applying a group stages every result before changing any source part, so a failed subtraction leaves the original geometry untouched. Successful group cuts are committed as one undoable operation.

Install by running the VS Code task **plugins: install**.
