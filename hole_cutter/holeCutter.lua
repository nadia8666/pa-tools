local ChangeHistoryService = game:GetService("ChangeHistoryService")
local Selection = game:GetService("Selection")
local HttpService = game:GetService("HttpService")
local GeometryService = game:GetService("GeometryService")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

if not RunService:IsEdit() then
	return
end

local GROUP_ATTRIBUTE = "HoleCutterGroupId"
local CUTTER_ATTRIBUTE = "HoleCutterIsCutter"
local CUTTER_NAME = "HoleCutter"
local DEFAULT_CUTTER_SIZE = Vector3.new(2, 2, 2)
local DEFAULT_COLOR = Color3.fromRGB(65, 135, 255)
local VALID_COLOR = Color3.fromRGB(75, 220, 125)
local INVALID_COLOR = Color3.fromRGB(235, 75, 75)

local toolbar = shared.paTools
while
	not (
		toolbar
		and toolbar.ready
		and type(toolbar.addButton) == "function"
		and type(toolbar.setButtonHandler) == "function"
		and type(toolbar.removeButtonHandler) == "function"
	)
do
	task.wait()
	toolbar = shared.paTools
end
toolbar.addButton("Mark Cuttable", "Assign a shared hole-cutter group to the selected parts", "rbxassetid://1507949215")
toolbar.addButton("Add Cutter", "Place a cutter for the current hole-cutter group", "rbxassetid://1507949215")
toolbar.addButton("Apply Holes", "Subtract every cutter in the group from every marked part", "rbxassetid://1507949215")
toolbar.addButton("Merge Parts", "Merge selected parts along their aligned axes", "rbxassetid://1507949215")

local mouse = plugin:GetMouse()
local currentGroupId
local placing = false
local checking = false
local lastValiditySignature
local validityValid
local clientFolder
local surfaceHighlight
local connections = {}

local function getCamera()
	return workspace.CurrentCamera or workspace:FindFirstChildOfClass("Camera")
end

local function generateClientFolder()
	local camera = getCamera()
	if not camera then
		return false
	end
	clientFolder = camera:FindFirstChild("HoleCutterClientTemp")
	if not clientFolder then
		clientFolder = Instance.new("Folder")
		clientFolder.Name = "HoleCutterClientTemp"
		clientFolder.Archivable = true
		clientFolder.Parent = camera
	end
	surfaceHighlight = clientFolder:FindFirstChild("SurfaceHighlight")
	if not surfaceHighlight then
		surfaceHighlight = Instance.new("SurfaceSelection")
		surfaceHighlight.Name = "SurfaceHighlight"
		surfaceHighlight.Color3 = Color3.new(1, 0.3, 0.3)
		surfaceHighlight.Transparency = 0.5
		surfaceHighlight.Archivable = false
		surfaceHighlight.Parent = clientFolder
	end
	return true
end

local function getParts(groupId)
	local targets = {}
	local cutters = {}
	local camera = getCamera()
	for _, instance in workspace:GetDescendants() do
		if instance:IsA("BasePart") and instance:GetAttribute(GROUP_ATTRIBUTE) == groupId then
			if instance:GetAttribute(CUTTER_ATTRIBUTE) == true and camera and instance:IsDescendantOf(camera) then
				table.insert(cutters, instance)
			elseif
				instance:GetAttribute(CUTTER_ATTRIBUTE) ~= true and (not camera or not instance:IsDescendantOf(camera))
			then
				table.insert(targets, instance)
			end
		end
	end
	return targets, cutters
end

local function getGroupFromSelection()
	for _, instance in Selection:Get() do
		if instance:IsA("BasePart") then
			local groupId = instance:GetAttribute(GROUP_ATTRIBUTE)
			if groupId then
				return groupId
			end
		end
	end
	return nil
end

local function markCuttable()
	local selected = {}
	local camera = getCamera()
	for _, instance in Selection:Get() do
		if instance:IsA("BasePart") and (not camera or not instance:IsDescendantOf(camera)) then
			table.insert(selected, instance)
		end
	end
	if #selected == 0 then
		warn("Select one or more BaseParts to mark as cuttable.")
		return
	end
	local groupId = HttpService:GenerateGUID(false)
	local recording = ChangeHistoryService:TryBeginRecording("HoleCutter_MarkGroup", "Mark Cuttable")
	if not recording then
		return
	end
	for _, part in selected do
		part:SetAttribute(GROUP_ATTRIBUTE, groupId)
		part:SetAttribute(CUTTER_ATTRIBUTE, nil)
	end
	ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
	currentGroupId = groupId
	lastValiditySignature = nil
end

local function cloneAppearance(instance)
	local archivable = instance.Archivable
	instance.Archivable = true
	local ok, clone = pcall(function()
		return instance:Clone()
	end)
	instance.Archivable = archivable
	if not ok then
		error(clone)
	end
	if not clone then
		error("Could not clone appearance child: " .. instance:GetFullName())
	end
	return clone
end

local function copyProperties(source, destination)
	local properties = {
		"Color",
		"Material",
		"MaterialVariant",
		"Transparency",
		"Reflectance",
		"Anchored",
		"CanCollide",
		"CanTouch",
		"CanQuery",
		"CastShadow",
		"Massless",
		"RootPriority",
		"CollisionGroup",
		"CustomPhysicalProperties",
		"TopSurface",
		"BottomSurface",
		"LeftSurface",
		"RightSurface",
		"FrontSurface",
		"BackSurface",
	}
	for _, property in properties do
		pcall(function()
			destination[property] = source[property]
		end)
	end
	for name, value in source:GetAttributes() do
		destination:SetAttribute(name, value)
	end
	for _, tag in CollectionService:GetTags(source) do
		CollectionService:AddTag(destination, tag)
	end
	for _, child in source:GetChildren() do
		if child:IsA("Texture") or child:IsA("Decal") then
			local clone = cloneAppearance(child)
			clone.Parent = destination
		end
	end
end

local CopyProperties = copyProperties

local function ArePropertiesEqual(first, second)
	local properties = {
		"Color",
		"Material",
		"MaterialVariant",
		"Transparency",
		"Reflectance",
		"Anchored",
		"CanCollide",
		"CastShadow",
		"Massless",
		"RootPriority",
		"TopSurface",
		"BottomSurface",
		"LeftSurface",
		"RightSurface",
		"FrontSurface",
		"BackSurface",
	}
	for _, property in properties do
		local firstOk, firstValue = pcall(function()
			return first[property]
		end)
		local secondOk, secondValue = pcall(function()
			return second[property]
		end)
		if firstOk and secondOk and firstValue ~= secondValue then
			return false
		end
	end
	if first:GetAttribute(GROUP_ATTRIBUTE) ~= second:GetAttribute(GROUP_ATTRIBUTE) then
		return false
	end
	return true
end

local function destroyParts(parts)
	for _, part in parts do
		if part then
			part:Destroy()
		end
	end
end

local function subtract(target, cutters)
	local results = GeometryService:SubtractAsync(target, cutters)
	if type(results) ~= "table" or #results == 0 then
		error("the cutter arrangement produced no geometry")
	end
	for _, result in results do
		if not result:IsA("BasePart") then
			error("the geometry service returned an unsupported result")
		end
		result.Archivable = true
		copyProperties(target, result)
		result.CollisionFidelity = Enum.CollisionFidelity.Tunable
		result.CollisionPrecision = 1
		result.Name = target.Name
	end
	return results
end

local function signatureOf(targets, cutters)
	local entries = {}
	for _, part in targets do
		table.insert(entries, part:GetFullName() .. tostring(part.CFrame) .. tostring(part.Size))
	end
	for _, part in cutters do
		table.insert(entries, part:GetFullName() .. tostring(part.CFrame) .. tostring(part.Size))
	end
	table.sort(entries)
	return table.concat(entries, "|")
end

local function setCutterColor(cutters, color)
	for _, cutter in cutters do
		cutter.Color = color
	end
end

local function validateGroup(groupId, force)
	if checking or not groupId then
		return false
	end
	local targets, cutters = getParts(groupId)
	if #targets == 0 or #cutters == 0 then
		setCutterColor(cutters, INVALID_COLOR)
		validityValid = false
		return false
	end
	local signature = signatureOf(targets, cutters)
	if not force and signature == lastValiditySignature then
		return validityValid == true
	end
	checking = true
	setCutterColor(cutters, DEFAULT_COLOR)
	local staged = {}
	local ok, err = pcall(function()
		for _, target in targets do
			for _, result in subtract(target, cutters) do
				table.insert(staged, result)
			end
		end
	end)
	local unchangedTargets, unchangedCutters = getParts(groupId)
	local unchanged = signature == signatureOf(unchangedTargets, unchangedCutters)
	destroyParts(staged)
	if unchanged then
		lastValiditySignature = signature
		validityValid = ok
		setCutterColor(cutters, if ok then VALID_COLOR else INVALID_COLOR)
	else
		lastValiditySignature = nil
		validityValid = nil
		setCutterColor(cutters, DEFAULT_COLOR)
	end
	checking = false
	if not ok then
		warn("Hole cutter validation failed: " .. tostring(err))
	end
	return ok and unchanged
end

local function captureStates(parts)
	local states = {}
	for _, part in parts do
		states[part] = {
			parent = part.Parent,
			cframe = part.CFrame,
			size = part.Size,
		}
	end
	return states
end

local function statesMatch(states)
	for part, state in states do
		if part.Parent ~= state.parent or part.CFrame ~= state.cframe or part.Size ~= state.size then
			return false
		end
	end
	return true
end

local function applyCuts()
	local groupId = currentGroupId or getGroupFromSelection()
	if not groupId then
		warn("Mark cuttable parts or select a part that already has a hole-cutter group.")
		return
	end
	local targets, cutters = getParts(groupId)
	if #targets == 0 or #cutters == 0 then
		warn("The current group needs at least one marked part and one cutter.")
		return
	end
	if not validateGroup(groupId, true) then
		warn("The cutter arrangement is invalid. No parts were changed.")
		return
	end

	local recording = ChangeHistoryService:TryBeginRecording("HoleCutter_CutGroup", "Apply Holes")
	if not recording then
		return
	end

	local states = captureStates(targets)
	local cutterStates = captureStates(cutters)
	local staged = {}
	local ok, err = pcall(function()
		for _, target in targets do
			local results = subtract(target, cutters)
			table.insert(staged, { source = target, parent = target.Parent, results = results })
		end
		local latestTargets, latestCutters = getParts(groupId)
		if
			not statesMatch(states)
			or not statesMatch(cutterStates)
			or signatureOf(latestTargets, latestCutters) ~= signatureOf(targets, cutters)
		then
			error("the cuttable group changed while geometry was being calculated")
		end
	end)
	if not ok then
		for _, entry in staged do
			destroyParts(entry.results)
		end
		ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Cancel)
		setCutterColor(cutters, INVALID_COLOR)
		validityValid = false
		warn("Hole cutting failed. No parts were changed: " .. tostring(err))
		return
	end

	local function transferChildren(source, results)
		local childStates = {}
		local constraintStates = {}
		local objectValueStates = {}
		local modelStates = {}
		for _, child in source:GetChildren() do
			if not child:IsA("Decal") and not child:IsA("Texture") then
				table.insert(childStates, {
					instance = child,
					parent = child.Parent,
					worldCFrame = child:IsA("Attachment") and source.CFrame * child.CFrame or nil,
					cframe = child:IsA("Attachment") and child.CFrame or nil,
				})
			end
		end
		for _, instance in game:GetDescendants() do
			if instance:IsA("JointInstance") and (instance.Part0 == source or instance.Part1 == source) then
				table.insert(constraintStates, {
					instance = instance,
					part0 = instance.Part0,
					part1 = instance.Part1,
					c0 = instance.C0,
					c1 = instance.C1,
				})
			elseif
				(instance:IsA("WeldConstraint") or instance:IsA("NoCollisionConstraint"))
				and (instance.Part0 == source or instance.Part1 == source)
			then
				table.insert(constraintStates, { instance = instance, part0 = instance.Part0, part1 = instance.Part1 })
			elseif instance:IsA("ObjectValue") and instance.Value == source then
				table.insert(objectValueStates, { instance = instance, value = instance.Value })
			elseif instance:IsA("Model") and instance.PrimaryPart == source then
				table.insert(modelStates, { instance = instance, primaryPart = instance.PrimaryPart })
			end
		end
		local function nearestResult(position)
			local nearest = results[1]
			local distance = (nearest.Position - position).Magnitude
			for index = 2, #results do
				local candidate = results[index]
				local candidateDistance = (candidate.Position - position).Magnitude
				if candidateDistance < distance then
					nearest = candidate
					distance = candidateDistance
				end
			end
			return nearest
		end
		local function restore()
			for _, state in childStates do
				state.instance.Parent = state.parent
				if state.cframe then
					state.instance.CFrame = state.cframe
				end
			end
			for _, state in constraintStates do
				state.instance.Part0 = state.part0
				state.instance.Part1 = state.part1
				if state.c0 then
					state.instance.C0 = state.c0
					state.instance.C1 = state.c1
				end
			end
			for _, state in objectValueStates do
				state.instance.Value = state.value
			end
			for _, state in modelStates do
				state.instance.PrimaryPart = state.primaryPart
			end
		end
		local ok, err = pcall(function()
			for _, state in childStates do
				local destination = state.worldCFrame and nearestResult(state.worldCFrame.Position) or results[1]
				state.instance.Parent = destination
				if state.worldCFrame then
					state.instance.CFrame = destination.CFrame:ToObjectSpace(state.worldCFrame)
				end
			end
			for _, state in constraintStates do
				local instance = state.instance
				if instance:IsA("JointInstance") then
					if state.part0 == source then
						local worldFrame = source.CFrame * state.c0
						instance.Part0 = nearestResult(worldFrame.Position)
						instance.C0 = instance.Part0.CFrame:ToObjectSpace(worldFrame)
					end
					if state.part1 == source then
						local worldFrame = source.CFrame * state.c1
						instance.Part1 = nearestResult(worldFrame.Position)
						instance.C1 = instance.Part1.CFrame:ToObjectSpace(worldFrame)
					end
				else
					if state.part0 == source then
						instance.Part0 = nearestResult(source.Position)
					end
					if state.part1 == source then
						instance.Part1 = nearestResult(source.Position)
					end
				end
			end
			for _, state in objectValueStates do
				state.instance.Value = results[1]
			end
			for _, state in modelStates do
				state.instance.PrimaryPart = results[1]
			end
		end)
		if not ok then
			restore()
			error(err)
		end
		return restore
	end

	local outputs = {}
	local childRestorers = {}
	local committed, commitError = pcall(function()
		for _, entry in staged do
			for _, result in entry.results do
				result.Parent = entry.parent
				table.insert(outputs, result)
			end
			table.insert(childRestorers, transferChildren(entry.source, entry.results))
			entry.source.Parent = nil
		end
	end)
	if not committed then
		for index = #childRestorers, 1, -1 do
			childRestorers[index]()
		end
		for _, entry in staged do
			entry.source.Parent = entry.parent
		end
		destroyParts(outputs)
		for _, entry in staged do
			for _, result in entry.results do
				if not table.find(outputs, result) then
					result:Destroy()
				end
			end
		end
		ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Cancel)
		warn("Hole cutting could not be committed. Original parts were restored: " .. tostring(commitError))
		return
	end

	ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
	Selection:Set(outputs)
	lastValiditySignature = nil
	validityValid = nil
end

local function normalId(part, worldNormal)
	local normal = part.CFrame:VectorToObjectSpace(worldNormal)
	local x, y, z = math.abs(normal.X), math.abs(normal.Y), math.abs(normal.Z)
	if x > y and x > z then
		return normal.X > 0 and Enum.NormalId.Right or Enum.NormalId.Left
	elseif y > x and y > z then
		return normal.Y > 0 and Enum.NormalId.Top or Enum.NormalId.Bottom
	end
	return normal.Z > 0 and Enum.NormalId.Back or Enum.NormalId.Front
end

local function createCutter(hitPosition, hitNormal)
	if not generateClientFolder() then
		return
	end
	local recording = ChangeHistoryService:TryBeginRecording("HoleCutter_Add", "Add Hole Cutter")
	if not recording then
		return
	end
	local cutter = Instance.new("Part")
	cutter.Name = CUTTER_NAME
	cutter.Archivable = true
	cutter.Size = DEFAULT_CUTTER_SIZE
	cutter.Color = DEFAULT_COLOR
	cutter.Transparency = 0.5
	cutter.Anchored = true
	cutter.CanCollide = false
	cutter.CanTouch = false
	cutter.CanQuery = false
	cutter.CastShadow = false
	cutter.TopSurface = Enum.SurfaceType.Smooth
	cutter.BottomSurface = Enum.SurfaceType.Smooth
	cutter.CFrame = CFrame.lookAt(hitPosition, hitPosition + hitNormal)
	cutter:SetAttribute(GROUP_ATTRIBUTE, currentGroupId)
	cutter:SetAttribute(CUTTER_ATTRIBUTE, true)
	cutter.Parent = clientFolder
	ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
	Selection:Set({ cutter })
	lastValiditySignature = nil
end

local function beginPlacement()
	currentGroupId = currentGroupId or getGroupFromSelection()
	if not currentGroupId then
		warn("Mark cuttable parts or select a part from an existing group before adding cutters.")
		return
	end
	if not generateClientFolder() then
		warn("The current camera is unavailable.")
		return
	end
	placing = true
	plugin:Activate(true)
	table.insert(
		connections,
		mouse.Move:Connect(function()
			if not placing then
				return
			end
			local ray = workspace:Raycast(mouse.UnitRay.Origin, mouse.UnitRay.Direction * 1000)
			if
				ray
				and ray.Instance:IsA("BasePart")
				and ray.Instance:GetAttribute(GROUP_ATTRIBUTE) == currentGroupId
			then
				surfaceHighlight.Adornee = ray.Instance
				surfaceHighlight.TargetSurface = normalId(ray.Instance, ray.Normal)
			else
				surfaceHighlight.Adornee = nil
			end
		end)
	)
	table.insert(
		connections,
		mouse.Button1Down:Connect(function()
			if not placing then
				return
			end
			local ray = workspace:Raycast(mouse.UnitRay.Origin, mouse.UnitRay.Direction * 1000)
			if
				ray
				and ray.Instance:IsA("BasePart")
				and ray.Instance:GetAttribute(GROUP_ATTRIBUTE) == currentGroupId
			then
				createCutter(ray.Position, ray.Normal)
				placing = false
				surfaceHighlight.Adornee = nil
				for _, connection in connections do
					connection:Disconnect()
				end
				table.clear(connections)
			end
		end)
	)
end

local function MergeSelectedParts()
	local selected = Selection:Get()
	local parts = {}
	for _, v in ipairs(selected) do
		if v:IsA("Part") and v.Shape == Enum.PartType.Block then
			table.insert(parts, v)
		end
	end

	if #parts < 2 then
		warn("Select at least 2 axis-aligned Block Parts to merge.")
		return
	end

	local recording = ChangeHistoryService:TryBeginRecording("HoleCutter_Merge", "Merge Parts")
	if not recording then
		return
	end

	local mergedAny = true
	while mergedAny do
		mergedAny = false

		local bestPair = nil
		local bestVol = -1
		local bestUnionSize = nil
		local bestUnionCFrame = nil

		-- Greedily find the pair of parts that produces the largest valid combined volume
		for i = 1, #parts do
			for j = i + 1, #parts do
				local p1 = parts[i]
				local p2 = parts[j]

				if not ArePropertiesEqual(p1, p2) or p1.Parent ~= p2.Parent then
					continue
				end

				-- Ensure orientations perfectly match
				if p1.CFrame.RightVector:Dot(p2.CFrame.RightVector) < 0.9999999 then
					continue
				end
				if p1.CFrame.UpVector:Dot(p2.CFrame.UpVector) < 0.9999999 then
					continue
				end
				if p1.CFrame.LookVector:Dot(p2.CFrame.LookVector) < 0.9999999 then
					continue
				end

				local size1 = p1.Size
				local size2 = p2.Size

				local min1 = -size1 / 2
				local max1 = size1 / 2

				local rel = p1.CFrame:ToObjectSpace(p2.CFrame)
				local min2 = rel.Position - size2 / 2
				local max2 = rel.Position + size2 / 2

				-- Ensure they form a perfect AABB box together by abutting accurately on exactly one axis
				local dx = math.abs(min1.X - min2.X) < 0.005 and math.abs(max1.X - max2.X) < 0.005
				local dy = math.abs(min1.Y - min2.Y) < 0.005 and math.abs(max1.Y - max2.Y) < 0.005
				local dz = math.abs(min1.Z - min2.Z) < 0.005 and math.abs(max1.Z - max2.Z) < 0.005

				local abutX = dy and dz and (math.abs(max1.X - min2.X) < 0.005 or math.abs(max2.X - min1.X) < 0.005)
				local abutY = dx and dz and (math.abs(max1.Y - min2.Y) < 0.005 or math.abs(max2.Y - min1.Y) < 0.005)
				local abutZ = dx and dy and (math.abs(max1.Z - min2.Z) < 0.005 or math.abs(max2.Z - min1.Z) < 0.005)

				if abutX or abutY or abutZ then
					local unionMin =
						Vector3.new(math.min(min1.X, min2.X), math.min(min1.Y, min2.Y), math.min(min1.Z, min2.Z))
					local unionMax =
						Vector3.new(math.max(max1.X, max2.X), math.max(max1.Y, max2.Y), math.max(max1.Z, max2.Z))
					local unionSize = unionMax - unionMin
					local unionVol = unionSize.X * unionSize.Y * unionSize.Z

					if unionVol > bestVol then
						bestVol = unionVol
						bestPair = { i, j }
						bestUnionSize = unionSize
						bestUnionCFrame = p1.CFrame * CFrame.new((unionMin + unionMax) / 2)
					end
				end
			end
		end

		if bestPair then
			local i, j = bestPair[1], bestPair[2]
			local p1 = parts[i]
			local p2 = parts[j]

			local newPart = Instance.new("Part")
			newPart.Archivable = true
			newPart.Size = bestUnionSize
			newPart.CFrame = bestUnionCFrame
			newPart.Parent = p1.Parent
			CopyProperties(p1, newPart)
			for _, child in ipairs(p2:GetChildren()) do
				if child:IsA("Texture") or child:IsA("Decal") then
					local clone = cloneAppearance(child)
					clone.Parent = newPart
				end
			end

			-- Copy all remaining children (Scripts, Attachments, etc.) that CopyProperties didn't cover
			for _, child in ipairs(p1:GetChildren()) do
				if not child:IsA("Texture") and not child:IsA("Decal") then
					local clone = child:Clone()
					if clone then
						clone.Parent = newPart
					end
				end
			end

			p1.Parent = nil
			p2.Parent = nil

			-- Remove the old parts, append the new one, and look for merges again
			table.remove(parts, math.max(i, j))
			table.remove(parts, math.min(i, j))
			table.insert(parts, newPart)

			mergedAny = true
		end
	end

	Selection:Set(parts)
	ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
end

toolbar.setButtonHandler("Mark Cuttable", markCuttable)
toolbar.setButtonHandler("Add Cutter", beginPlacement)
toolbar.setButtonHandler("Apply Holes", applyCuts)
toolbar.setButtonHandler("Merge Parts", MergeSelectedParts)

Selection.SelectionChanged:Connect(function()
	local selectedGroup = getGroupFromSelection()
	if selectedGroup ~= currentGroupId then
		currentGroupId = selectedGroup
		lastValiditySignature = nil
		validityValid = nil
		if not currentGroupId then
			local camera = getCamera()
			if camera then
				for _, instance in camera:GetDescendants() do
					if instance:IsA("BasePart") and instance:GetAttribute(CUTTER_ATTRIBUTE) == true then
						instance.Color = DEFAULT_COLOR
					end
				end
			end
		end
	end
end)

task.spawn(function()
	while true do
		task.wait(1)
		local groupId = currentGroupId or getGroupFromSelection()
		if groupId then
			validateGroup(groupId, false)
		end
	end
end)

plugin.Unloading:Connect(function()
	toolbar.removeButtonHandler("Mark Cuttable")
	toolbar.removeButtonHandler("Add Cutter")
	toolbar.removeButtonHandler("Apply Holes")
	toolbar.removeButtonHandler("Merge Parts")
	placing = false
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
	if surfaceHighlight then
		surfaceHighlight.Adornee = nil
		surfaceHighlight:Destroy()
	end
end)

generateClientFolder()
