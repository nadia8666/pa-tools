local ChangeHistoryService = game:GetService("ChangeHistoryService")
local CollectionService = game:GetService("CollectionService")
local EncodingService = game:GetService("EncodingService")
local HttpService = game:GetService("HttpService")
local CoreGui = game:GetService("CoreGui")
local Selection = game:GetService("Selection")
local RunService = game:GetService("RunService")

if not RunService:IsEdit() then
	return
end

local FOLDER_NAME = "WorldSelectorClientTemp"
local BOX_TAG = "WorldSelectorBox"
local BOX_ATTRIBUTE = "WorldSelectorBox"
local BOX_NAME = "WorldSelectorBox"
local BUTTON_ID = "worldSelector"
local GUI_NAME = "WorldSelectorGui"
local DEBOUNCE = 0.2
local CHUNK_SIZE = 400
local MAX_HIGHLIGHTS = 225
local BOX_COLOR = Color3.fromRGB(235, 65, 65)
local HIGHLIGHT_COLOR = Color3.fromRGB(235, 65, 65)
local CONFLICT_COLOR = Color3.fromRGB(235, 65, 65)

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

toolbar.addButton(BUTTON_ID, "Select or compare instances within 3D bounds", "rbxassetid://1507949215")

local connections = {}
local boxConnections = {}
local folderConnections = {}
local guiConnections = {}
local cameraConnection
local folder
local gui
local codeBox
local lastCodeText = ""
local progressLabel
local currentHighlights = {}
local refreshRevision = 0
local boundsChangeRevision = 0
local isImporting = false
local isGeneratingCode = false
local isClosing = false
local comparisonMode = false

local function connect(signal, callback)
	local connection = signal:Connect(callback)
	table.insert(connections, connection)
	return connection
end

local function getCamera()
	return workspace.CurrentCamera
end

local function getFolder()
	local camera = getCamera()
	local folderInstance = camera and camera:FindFirstChild(FOLDER_NAME)
	return folderInstance and folderInstance:IsA("Folder") and folderInstance or nil
end

local function getBoxes()
	local result = {}
	if not folder or not folder.Parent then
		return result
	end
	for _, child in folder:GetChildren() do
		if child:IsA("BasePart") and child:GetAttribute(BOX_ATTRIBUTE) == true then
			table.insert(result, child)
		end
	end
	return result
end

local function destroyHighlights()
	for _, adornment in currentHighlights do
		adornment:Destroy()
	end
	table.clear(currentHighlights)
end

local function updateProgress(message)
	if progressLabel and progressLabel.Parent then
		progressLabel.Text = message
	end
end

local function createAdornment(className, adornee)
	local adornment = Instance.new(className) :: any
	adornment.Name = "WorldSelectorAdornment"
	adornment.Archivable = false
	adornment.Adornee = adornee
	if className == "Highlight" then
		adornment.FillColor = HIGHLIGHT_COLOR
		adornment.OutlineColor = HIGHLIGHT_COLOR
		adornment.FillTransparency = 0.35
		adornment.OutlineTransparency = 0.1
		adornment.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	else
		adornment.Color3 = CONFLICT_COLOR
		adornment.Transparency = 0.35
		adornment.SurfaceTransparency = 1
		adornment.LineThickness = 0.05
		pcall(function()
			adornment.AlwaysOnTop = true
		end)
	end
	adornment.Parent = gui
	table.insert(currentHighlights, adornment)
	return adornment
end

local function getTopLevelSelection(part)
	local selectedModel
	local ancestor = part.Parent
	while ancestor and ancestor ~= workspace do
		if ancestor:IsA("Model") then
			selectedModel = ancestor
		end
		ancestor = ancestor.Parent
	end
	return selectedModel or part
end

local function getWorkspaceParts(revision)
	local parts = {}
	local pending = { workspace }
	local checked = 0
	while #pending > 0 do
		local parent = table.remove(pending)
		for _, instance in parent:GetChildren() do
			checked += 1
			if not instance:IsA("Camera") then
				if instance:IsA("BasePart") then
					table.insert(parts, instance)
				end
				table.insert(pending, instance)
			end
			if checked % CHUNK_SIZE == 0 then
				if revision ~= refreshRevision then
					return nil
				end
				updateProgress(string.format("Collecting Workspace instances: %d", checked))
				task.wait()
			end
		end
	end
	if revision ~= refreshRevision then
		return nil
	end
	return parts
end
local function intersects(firstCFrame, firstSize, secondCFrame, secondSize)
	local firstHalf = { firstSize.X * 0.5, firstSize.Y * 0.5, firstSize.Z * 0.5 }
	local secondHalf = { secondSize.X * 0.5, secondSize.Y * 0.5, secondSize.Z * 0.5 }
	local firstRight = firstCFrame.RightVector
	local firstUp = firstCFrame.UpVector
	local firstBack = firstCFrame.LookVector
	local secondRight = secondCFrame.RightVector
	local secondUp = secondCFrame.UpVector
	local secondBack = secondCFrame.LookVector
	local firstAxes = { firstRight, firstUp, firstBack }
	local secondAxes = { secondRight, secondUp, secondBack }
	local rotation = {}
	local absoluteRotation = {}
	for i = 1, 3 do
		rotation[i] = {}
		absoluteRotation[i] = {}
		for j = 1, 3 do
			local value = firstAxes[i]:Dot(secondAxes[j])
			rotation[i][j] = value
			absoluteRotation[i][j] = math.abs(value) + 1e-6
		end
	end
	local offset = secondCFrame.Position - firstCFrame.Position
	local translated = {
		offset:Dot(firstRight),
		offset:Dot(firstUp),
		offset:Dot(firstBack),
	}
	for i = 1, 3 do
		local radiusFirst = firstHalf[i]
		local radiusSecond = secondHalf[1] * absoluteRotation[i][1]
			+ secondHalf[2] * absoluteRotation[i][2]
			+ secondHalf[3] * absoluteRotation[i][3]
		if math.abs(translated[i]) > radiusFirst + radiusSecond then
			return false
		end
	end
	for j = 1, 3 do
		local radiusFirst = firstHalf[1] * absoluteRotation[1][j]
			+ firstHalf[2] * absoluteRotation[2][j]
			+ firstHalf[3] * absoluteRotation[3][j]
		local radiusSecond = secondHalf[j]
		local projected =
			math.abs(translated[1] * rotation[1][j] + translated[2] * rotation[2][j] + translated[3] * rotation[3][j])
		if projected > radiusFirst + radiusSecond then
			return false
		end
	end
	for i = 1, 3 do
		for j = 1, 3 do
			local firstNext = i % 3 + 1
			local firstLast = (i + 1) % 3 + 1
			local secondNext = j % 3 + 1
			local secondLast = (j + 1) % 3 + 1
			local radiusFirst = firstHalf[firstNext] * absoluteRotation[firstLast][j]
				+ firstHalf[firstLast] * absoluteRotation[firstNext][j]
			local radiusSecond = secondHalf[secondNext] * absoluteRotation[i][secondLast]
				+ secondHalf[secondLast] * absoluteRotation[i][secondNext]
			local projected = math.abs(
				translated[firstLast] * rotation[firstNext][j] - translated[firstNext] * rotation[firstLast][j]
			)
			if projected > radiusFirst + radiusSecond then
				return false
			end
		end
	end
	return true
end

local function getWorldAabb(cframe, size)
	local half = size * 0.5
	local right = cframe.RightVector
	local up = cframe.UpVector
	local back = cframe.LookVector
	local extents = Vector3.new(
		math.abs(right.X) * half.X + math.abs(up.X) * half.Y + math.abs(back.X) * half.Z,
		math.abs(right.Y) * half.X + math.abs(up.Y) * half.Y + math.abs(back.Y) * half.Z,
		math.abs(right.Z) * half.X + math.abs(up.Z) * half.Y + math.abs(back.Z) * half.Z
	)
	return cframe.Position, extents
end

local function aabbIntersects(firstPosition, firstExtents, secondPosition, secondExtents)
	local offset = secondPosition - firstPosition
	return math.abs(offset.X) <= firstExtents.X + secondExtents.X + 1e-6
		and math.abs(offset.Y) <= firstExtents.Y + secondExtents.Y + 1e-6
		and math.abs(offset.Z) <= firstExtents.Z + secondExtents.Z + 1e-6
end

local function findIntersections(boxes, parts, revision)
	local matched = {}
	local matchedParts = {}
	local totalChecks = #boxes * #parts
	local checked = 0
	for _, box in boxes do
		if not box.Parent then
			return nil
		end
		local boxPosition, boxExtents = getWorldAabb(box.CFrame, box.Size)
		for _, part in parts do
			checked += 1
			if part:IsDescendantOf(workspace) and not matchedParts[part] then
				local partPosition, partExtents = getWorldAabb(part.CFrame, part.Size)
				if
					aabbIntersects(boxPosition, boxExtents, partPosition, partExtents)
					and intersects(box.CFrame, box.Size, part.CFrame, part.Size)
				then
					matchedParts[part] = true
					table.insert(matched, part)
				end
			end
			if checked % CHUNK_SIZE == 0 then
				if revision ~= refreshRevision then
					return nil
				end
				updateProgress(string.format("Checking bounds: %d / %d", checked, totalChecks))
				task.wait()
			end
		end
	end
	if revision ~= refreshRevision then
		return nil
	end
	return matched
end

local function makeSelection(matched)
	local selected = {}
	local included = {}
	for _, part in matched do
		if not part:IsDescendantOf(workspace) then
			continue
		end
		local target = getTopLevelSelection(part)
		if not included[target] then
			included[target] = true
			table.insert(selected, target)
		end
	end
	return selected
end

local function showHighlights(matched)
	destroyHighlights()
	local targets = makeSelection(matched)
	if #targets < MAX_HIGHLIGHTS then
		for _, target in targets do
			createAdornment("Highlight", target)
		end
	else
		for _, part in matched do
			createAdornment("SelectionBox", part)
		end
	end
end

local function encodeBoxes(boxes)
	local entries = {}
	for _, box in boxes do
		local components = { box.CFrame:GetComponents() }
		table.insert(entries, {
			cframe = components,
			size = { box.Size.X, box.Size.Y, box.Size.Z },
		})
	end
	local json = HttpService:JSONEncode({ boxes = entries })
	local compressed = EncodingService:CompressBuffer(buffer.fromstring(json), Enum.CompressionAlgorithm.Zstd, 5)
	return buffer.tostring(EncodingService:Base64Encode(compressed))
end

local function decodeBase64(code)
	code = code:gsub("%s", "")
	if #code == 0 or #code % 4 ~= 0 then
		error("The code contains invalid Base64 data.")
	end
	local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	local values = {}
	for index = 1, #alphabet do
		values[alphabet:sub(index, index)] = index - 1
	end
	local bytes = {}
	for index = 1, #code, 4 do
		local first = values[code:sub(index, index)]
		local second = values[code:sub(index + 1, index + 1)]
		local thirdCharacter = code:sub(index + 2, index + 2)
		local fourthCharacter = code:sub(index + 3, index + 3)
		local third = values[thirdCharacter]
		local fourth = values[fourthCharacter]
		local isFinal = index + 3 == #code
		if first == nil or second == nil or (third == nil and thirdCharacter ~= "=") or (fourth == nil and fourthCharacter ~= "=") then
			error("The code contains invalid Base64 data.")
		end
		if thirdCharacter == "=" then
			if fourthCharacter ~= "=" or not isFinal or second % 16 ~= 0 then
				error("The code contains invalid Base64 data.")
			end
		elseif fourthCharacter == "=" then
			if not isFinal or third % 4 ~= 0 then
				error("The code contains invalid Base64 data.")
			end
		end
		table.insert(bytes, first * 4 + math.floor(second / 16))
		if thirdCharacter ~= "=" then
			table.insert(bytes, second % 16 * 16 + math.floor(third / 4))
		end
		if fourthCharacter ~= "=" then
			table.insert(bytes, third % 4 * 64 + fourth)
		end
	end
	local decoded = buffer.create(#bytes)
	for index, value in bytes do
		buffer.writeu8(decoded, index - 1, value)
	end
	return decoded
end

local function decodeBoxes(code)
	local normalizedCode = code:gsub("%s", "")
	local success, decoded = pcall(EncodingService.Base64Decode, EncodingService, buffer.fromstring(normalizedCode))
	if not success then
		decoded = decodeBase64(normalizedCode)
	end
	local decompressedSize = EncodingService:GetDecompressedBufferSize(decoded, Enum.CompressionAlgorithm.Zstd)
	if not decompressedSize then
		error("The code contains invalid compressed data.")
	end
	local decompressed = EncodingService:DecompressBuffer(decoded, Enum.CompressionAlgorithm.Zstd)
	local payload = HttpService:JSONDecode(buffer.tostring(decompressed))
	if type(payload) ~= "table" or type(payload.boxes) ~= "table" or #payload.boxes == 0 then
		error("The code does not contain any valid bounds.")
	end
	local boxes = {}
	for _, entry in payload.boxes do
		if
			type(entry) ~= "table"
			or type(entry.cframe) ~= "table"
			or #entry.cframe ~= 12
			or type(entry.size) ~= "table"
			or #entry.size ~= 3
		then
			error("The code contains an invalid box.")
		end
		local values = {}
		for index = 1, 12 do
			local value = entry.cframe[index]
			if
				type(value) ~= "number"
				or value ~= value
				or math.abs(value) == math.huge
				or (index >= 4 and math.abs(value) > 1.001)
			then
				error("The code contains an invalid transform.")
			end
			values[index] = value
		end
		local firstRow = Vector3.new(values[4], values[5], values[6])
		local secondRow = Vector3.new(values[7], values[8], values[9])
		local thirdRow = Vector3.new(values[10], values[11], values[12])
		if
			math.abs(firstRow.Magnitude - 1) > 1e-3
			or math.abs(secondRow.Magnitude - 1) > 1e-3
			or math.abs(thirdRow.Magnitude - 1) > 1e-3
			or math.abs(firstRow:Dot(secondRow)) > 1e-3
			or math.abs(firstRow:Dot(thirdRow)) > 1e-3
			or math.abs(secondRow:Dot(thirdRow)) > 1e-3
			or firstRow:Cross(secondRow):Dot(thirdRow) < 0.999
		then
			error("The code contains an invalid rotation.")
		end
		for index = 1, 3 do
			local value = entry.size[index]
			if type(value) ~= "number" or value ~= value or value <= 0 or math.abs(value) == math.huge then
				error("The code contains an invalid size.")
			end
		end
		local cframe = CFrame.new(table.unpack(values))
		local position = cframe.Position
		if
			math.abs(position.X) == math.huge
			or math.abs(position.Y) == math.huge
			or math.abs(position.Z) == math.huge
		then
			error("The code contains an invalid position.")
		end
		local size = Vector3.new(entry.size[1], entry.size[2], entry.size[3])
		if
			size.X <= 0
			or size.Y <= 0
			or size.Z <= 0
			or math.abs(size.X) == math.huge
			or math.abs(size.Y) == math.huge
			or math.abs(size.Z) == math.huge
		then
			error("The code contains an invalid size.")
		end
		table.insert(boxes, {
			cframe = cframe,
			size = size,
		})
	end
	return boxes
end

local function updateCode()
	if not codeBox or not codeBox.Parent or codeBox:IsFocused() or isGeneratingCode or isImporting then
		return
	end
	local boxes = getBoxes()
	if #boxes == 0 then
		codeBox.Text = ""
		lastCodeText = ""
		return
	end
	local ok, result = pcall(encodeBoxes, boxes)
	if ok then
		isGeneratingCode = true
		codeBox.Text = result
		lastCodeText = result
		isGeneratingCode = false
	else
		warn("World Selector could not encode the bounds: " .. tostring(result))
	end
end

local function clearBoxConnections()
	for box, connectionsForBox in boxConnections do
		for _, connection in connectionsForBox do
			connection:Disconnect()
		end
		boxConnections[box] = nil
	end
end

local function clearFolderConnections()
	for _, connection in folderConnections do
		connection:Disconnect()
	end
	table.clear(folderConnections)
end

local function connectFolder(signal, callback)
	local connection = signal:Connect(callback)
	table.insert(folderConnections, connection)
	return connection
end

local function connectGui(signal, callback)
	local connection = signal:Connect(callback)
	table.insert(guiConnections, connection)
	return connection
end

local function refreshImportedHighlights()
	refreshRevision += 1
	local revision = refreshRevision
	local boxes = getBoxes()
	if #boxes == 0 then
		destroyHighlights()
		updateProgress("No bounds")
		return
	end
	updateProgress("Scanning Workspace...")
	task.spawn(function()
		local parts = getWorkspaceParts(revision)
		if not parts then
			return
		end
		local matched = findIntersections(boxes, parts, revision)
		if not matched or revision ~= refreshRevision then
			return
		end
		showHighlights(matched)
		updateProgress(string.format("%d intersecting instances", #makeSelection(matched)))
	end)
end

local function watchBoxes()
	clearBoxConnections()
	for _, box in getBoxes() do
		local function changed()
			boundsChangeRevision += 1
			refreshRevision += 1
			local currentRevision = boundsChangeRevision
			task.delay(DEBOUNCE, function()
				if currentRevision ~= boundsChangeRevision or not box.Parent then
					return
				end
				updateCode()
				if comparisonMode then
					refreshImportedHighlights()
				else
					updateProgress("Bounds updated")
				end
			end)
		end
		boxConnections[box] = {
			box:GetPropertyChangedSignal("CFrame"):Connect(changed),
			box:GetPropertyChangedSignal("Size"):Connect(changed),
		}
	end
end

local function createBox(cframe, size)
	local box = Instance.new("Part")
	box.Name = BOX_NAME
	box.Archivable = true
	box.Size = size or Vector3.one
	box.CFrame = cframe
	box.Color = BOX_COLOR
	box.Material = Enum.Material.Neon
	box.Transparency = 0.5
	box.Anchored = true
	box.CanCollide = false
	box.CanTouch = false
	box.CanQuery = false
	box.CastShadow = false
	box.TopSurface = Enum.SurfaceType.Smooth
	box.BottomSurface = Enum.SurfaceType.Smooth
	box:SetAttribute(BOX_ATTRIBUTE, true)
	CollectionService:AddTag(box, BOX_TAG)
	box.Parent = folder
	return box
end

local function replaceBoxes(definitions)
	local recording =
		ChangeHistoryService:TryBeginRecording("WorldSelector_ImportBounds", "Import World Selector Bounds")
	if not recording then
		warn("World Selector could not begin an import recording.")
		return false
	end
	local created = {}
	local createdSet = {}
	local ok, err = pcall(function()
		for _, definition in definitions do
			local box = createBox(definition.cframe, definition.size)
			table.insert(created, box)
			createdSet[box] = true
		end
	end)
	if not ok then
		for _, box in created do
			box:Destroy()
		end
		ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Cancel)
		error(err)
	end
	for _, child in folder:GetChildren() do
		if child:IsA("BasePart") and child:GetAttribute(BOX_ATTRIBUTE) == true and not createdSet[child] then
			child:Destroy()
		end
	end
	ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
	watchBoxes()
	return true
end

local function selectContents()
	if not folder or not folder.Parent then
		return
	end
	local boxes = getBoxes()
	if #boxes == 0 then
		warn("World Selector needs at least one bounds box.")
		return
	end
	comparisonMode = false
	destroyHighlights()
	refreshRevision += 1
	local revision = refreshRevision
	updateProgress("Scanning Workspace...")
	task.spawn(function()
		local parts = getWorkspaceParts(revision)
		if not parts then
			return
		end
		local matched = findIntersections(boxes, parts, revision)
		if not matched or revision ~= refreshRevision then
			return
		end
		Selection:Set(makeSelection(matched))
		if codeBox then
			local ok, encoded = pcall(encodeBoxes, boxes)
			if ok then
				isGeneratingCode = true
				codeBox.TextEditable = false
				codeBox.Text = encoded
				lastCodeText = encoded
				isGeneratingCode = false
			else
				warn("World Selector could not encode the bounds: " .. tostring(encoded))
			end
		end
		destroyHighlights()
		updateProgress(string.format("Selected %d instances", #Selection:Get()))
	end)
end

local function importFromText()
	if not codeBox or not folder or isImporting then
		return
	end
	local text = codeBox.Text
	if text == "" then
		return
	end
	local previousComparisonMode = comparisonMode
	comparisonMode = false
	refreshRevision += 1
	isImporting = true
	local ok, definitions = pcall(decodeBoxes, text)
	if not ok then
		comparisonMode = previousComparisonMode
		isImporting = false
		updateProgress("Invalid bounds code")
		warn("World Selector could not import bounds: " .. tostring(definitions))
		return
	end
	local replaced, result = pcall(replaceBoxes, definitions)
	if not replaced or not result then
		comparisonMode = previousComparisonMode
		isImporting = false
		updateProgress("Unable to replace bounds")
		warn("World Selector could not replace bounds: " .. tostring(result))
		return
	end
	codeBox.TextEditable = true
	comparisonMode = true
	isImporting = false
	destroyHighlights()
	refreshImportedHighlights()
	updateCode()
end

local function createGui()
	if gui and gui.Parent then
		return
	end
	lastCodeText = ""
	gui = Instance.new("ScreenGui")
	gui.Name = GUI_NAME
	gui.Archivable = false
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 1000
	gui.IgnoreGuiInset = true
	gui.Parent = CoreGui

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 1)
	panel.Position = UDim2.new(0.5, 0, 1, -20)
	panel.Size = UDim2.fromOffset(440, 94)
	panel.BackgroundColor3 = Color3.fromRGB(22, 23, 30)
	panel.BorderSizePixel = 0
	panel.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = panel

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(78, 82, 108)
	stroke.Transparency = 0.35
	stroke.Thickness = 1
	stroke.Parent = panel

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 10)
	padding.PaddingBottom = UDim.new(0, 10)
	padding.PaddingLeft = UDim.new(0, 10)
	padding.PaddingRight = UDim.new(0, 10)
	padding.Parent = panel

	local field = Instance.new("TextBox")
	field.Name = "BoundsCode"
	field.Size = UDim2.new(1, -42, 0, 46)
	field.Position = UDim2.fromOffset(0, 0)
	field.BackgroundColor3 = Color3.fromRGB(16, 17, 23)
	field.BorderSizePixel = 0
	field.ClearTextOnFocus = false
	field.MultiLine = true
	field.TextWrapped = true
	field.TextXAlignment = Enum.TextXAlignment.Left
	field.TextYAlignment = Enum.TextYAlignment.Center
	field.Font = Enum.Font.Code
	field.TextSize = 12
	field.TextColor3 = Color3.fromRGB(230, 232, 240)
	field.PlaceholderColor3 = Color3.fromRGB(140, 145, 168)
	field.PlaceholderText = "Paste bounds code here, or select bounds to export"
	field.Text = ""
	field.TextEditable = true
	field.Parent = panel
	codeBox = field

	local fieldCorner = Instance.new("UICorner")
	fieldCorner.CornerRadius = UDim.new(0, 5)
	fieldCorner.Parent = field

	local clear = Instance.new("TextButton")
	clear.Name = "ClearHighlights"
	clear.Size = UDim2.fromOffset(32, 46)
	clear.Position = UDim2.new(1, -32, 0, 0)
	clear.BackgroundColor3 = Color3.fromRGB(40, 42, 58)
	clear.BorderSizePixel = 0
	clear.Text = "×"
	clear.Font = Enum.Font.Gotham
	clear.TextSize = 22
	clear.TextColor3 = Color3.fromRGB(230, 232, 240)
	clear.Parent = panel

	local clearCorner = Instance.new("UICorner")
	clearCorner.CornerRadius = UDim.new(0, 5)
	clearCorner.Parent = clear

	local status = Instance.new("TextLabel")
	status.Name = "Progress"
	status.Size = UDim2.new(1, 0, 0, 20)
	status.Position = UDim2.fromOffset(0, 54)
	status.BackgroundTransparency = 1
	status.Font = Enum.Font.Gotham
	status.TextSize = 11
	status.TextXAlignment = Enum.TextXAlignment.Left
	status.TextColor3 = Color3.fromRGB(140, 145, 168)
	status.Text = "Bounds ready"
	status.Parent = panel
	progressLabel = status

	connectGui(clear.MouseButton1Click, function()
		if comparisonMode then
			refreshRevision += 1
		end
		destroyHighlights()
		updateProgress("Highlights cleared")
	end)
	connectGui(field.FocusLost, function()
		if isGeneratingCode or isImporting then
			return
		end
		if not field.TextEditable then
			updateCode()
		elseif field.Text ~= lastCodeText then
			importFromText()
		else
			updateCode()
		end
	end)
end

local function closeGui()
	for _, connection in guiConnections do
		connection:Disconnect()
	end
	table.clear(guiConnections)
	destroyHighlights()
	if gui then
		gui:Destroy()
	end
	gui = nil
	codeBox = nil
	lastCodeText = ""
	progressLabel = nil
end

local function createFolder()
	local camera = getCamera()
	if not camera then
		warn("World Selector requires an active CurrentCamera.")
		return false
	end
	local existingFolder = camera:FindFirstChild(FOLDER_NAME)
	if existingFolder then
		if existingFolder:IsA("Folder") then
			folder = existingFolder
			return true
		end
		warn("World Selector found an incompatible object using its folder name.")
		return false
	end
	local recording =
		ChangeHistoryService:TryBeginRecording("WorldSelector_CreateBounds", "Create World Selector Bounds")
	if not recording then
		warn("World Selector could not begin a bounds recording.")
		return false
	end
	local ok, box = pcall(function()
		folder = Instance.new("Folder")
		folder.Name = FOLDER_NAME
		folder.Archivable = true
		folder.Parent = camera
		return createBox(CFrame.new(camera.CFrame.Position + camera.CFrame.LookVector * 5), Vector3.one)
	end)
	if not ok then
		if folder then
			folder:Destroy()
		end
		folder = nil
		ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Cancel)
		warn("World Selector could not create bounds: " .. tostring(box))
		return false
	end
	ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
	Selection:Set({ box })
	return true
end

local function bindFolder(existingFolder)
	clearFolderConnections()
	folder = existingFolder
	local boundFolder = existingFolder
	createGui()
	watchBoxes()
	if #getBoxes() > 0 then
		updateCode()
	end
	connectFolder(boundFolder.AncestryChanged, function()
		if folder == boundFolder and not boundFolder:IsDescendantOf(game) and not isClosing then
			isClosing = true
			refreshRevision += 1
			boundsChangeRevision += 1
			clearFolderConnections()
			clearBoxConnections()
			closeGui()
			folder = nil
			comparisonMode = false
			isClosing = false
		end
	end)
	connectFolder(boundFolder.ChildAdded, function(child)
		if
			folder == boundFolder
			and not isImporting
			and child:IsA("BasePart")
			and child:GetAttribute(BOX_ATTRIBUTE) == true
		then
			refreshRevision += 1
			watchBoxes()
			updateCode()
			if comparisonMode then
				refreshImportedHighlights()
			else
				updateProgress("Bounds updated")
			end
		end
	end)
	connectFolder(boundFolder.ChildRemoved, function(child)
		if
			folder == boundFolder
			and not isImporting
			and child:IsA("BasePart")
			and child:GetAttribute(BOX_ATTRIBUTE) == true
		then
			refreshRevision += 1
			watchBoxes()
			updateCode()
			if #getBoxes() == 0 then
				destroyHighlights()
				updateProgress("No bounds")
			elseif comparisonMode then
				refreshImportedHighlights()
			else
				updateProgress("Bounds updated")
			end
		end
	end)
end

local function watchCurrentCamera()
	if cameraConnection then
		cameraConnection:Disconnect()
		cameraConnection = nil
	end
	local camera = getCamera()
	if camera then
		cameraConnection = camera.ChildAdded:Connect(function(child)
			if child:IsA("Folder") and child.Name == FOLDER_NAME and (not folder or not folder.Parent) then
				bindFolder(child)
			end
		end)
	end
end

local existingFolder = getFolder()
if existingFolder then
	bindFolder(existingFolder)
end
watchCurrentCamera()

connect(workspace:GetPropertyChangedSignal("CurrentCamera"), function()
	refreshRevision += 1
	watchCurrentCamera()
	local currentCamera = getCamera()
	local currentFolder = getFolder()
	if currentFolder and currentFolder ~= folder then
		local previousFolder = folder
		comparisonMode = false
		if codeBox then
			codeBox.TextEditable = true
		end
		destroyHighlights()
		bindFolder(currentFolder)
		if previousFolder and previousFolder.Parent then
			previousFolder:Destroy()
		end
	elseif folder and folder.Parent and currentCamera and folder.Parent ~= currentCamera then
		if not currentCamera:FindFirstChild(FOLDER_NAME) then
			folder.Parent = currentCamera
		end
	end
end)

toolbar.setButtonHandler(BUTTON_ID, function()
	if not folder or not folder.Parent then
		if not createFolder() then
			return
		end
		bindFolder(folder)
		return
	end
	selectContents()
end)

connect(plugin.Unloading, function()
	toolbar.removeButtonHandler(BUTTON_ID)
	refreshRevision += 1
	boundsChangeRevision += 1
	clearFolderConnections()
	clearBoxConnections()
	if cameraConnection then
		cameraConnection:Disconnect()
		cameraConnection = nil
	end
	isClosing = true
	if folder then
		folder:Destroy()
		folder = nil
	end
	closeGui()
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
end)
