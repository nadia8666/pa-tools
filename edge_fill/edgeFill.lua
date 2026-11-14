local ChangeHistoryService = game:GetService("ChangeHistoryService")
local Selection = game:GetService("Selection")
local RunService = game:GetService("RunService")

if not RunService:IsEdit() then
	return
end

local COLORS = {
	bottom = Color3.fromRGB(22, 23, 30),
	panel = Color3.fromRGB(22, 23, 27),
	panelDark = Color3.fromRGB(22, 23, 32),
	stroke = Color3.fromRGB(78, 82, 108),
	text = Color3.fromRGB(230, 232, 240),
	sub = Color3.fromRGB(140, 145, 168),
	ok = Color3.fromRGB(80, 200, 120),
	bad = Color3.fromRGB(235, 90, 90),
}

local toolbar = shared.paTools
while not (toolbar and toolbar.ready and type(toolbar.addButton) == "function") do
	task.wait()
	toolbar = shared.paTools
end

local widget = plugin:CreateDockWidgetPluginGuiAsync(
	"edgeFill",
	DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Right, true, false, 300, 440, 260, 320)
)
widget.Title = "edgeFill"

local mouse = plugin:GetMouse()
local mode = "fence"
local updateModeVisibility
local refreshPreview
local sourcePart
local referencePart
local surfaceNormal
local surfaceLoops
local previewFolder
local previewParts = {}
local connections = {}
local placing = false
local deletingInwardTextures = false
local inset = 0
local width = 2
local height = 2

local function connect(signal, callback)
	local connection = signal:Connect(callback)
	table.insert(connections, connection)
	return connection
end

local function create(className, properties, parent)
	local instance = Instance.new(className)
	for key, value in properties do
		instance[key] = value
	end
	instance.Parent = parent
	return instance
end

local root = create("ScrollingFrame", {
	Size = UDim2.fromScale(1, 1),
	BackgroundColor3 = COLORS.bottom,
	BorderSizePixel = 0,
	CanvasSize = UDim2.new(),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	ScrollingDirection = Enum.ScrollingDirection.Y,
	ScrollBarThickness = 5,
	ScrollBarImageColor3 = COLORS.sub,
}, widget)
create("UIPadding", {
	PaddingTop = UDim.new(0, 12),
	PaddingBottom = UDim.new(0, 12),
	PaddingLeft = UDim.new(0, 12),
	PaddingRight = UDim.new(0, 12),
}, root)
create("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }, root)

local function makeLabel(text, heightValue, order, parent)
	return create("TextLabel", {
		Size = UDim2.new(1, 0, 0, heightValue),
		BackgroundTransparency = 1,
		Font = Enum.Font.Gotham,
		TextSize = 13,
		TextColor3 = COLORS.text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = true,
		Text = text,
		LayoutOrder = order,
	}, parent or root)
end

local function makeButton(text, order, callback, parent)
	local button = create("TextButton", {
		Size = UDim2.new(1, 0, 0, 34),
		BackgroundColor3 = COLORS.panel,
		BorderSizePixel = 0,
		Font = Enum.Font.GothamMedium,
		TextSize = 13,
		TextColor3 = COLORS.text,
		Text = text,
		LayoutOrder = order,
	}, parent or root)
	create("UICorner", { CornerRadius = UDim.new(0, 6) }, button)
	create("UIStroke", { Color = COLORS.stroke, Thickness = 1, Transparency = 0.35 }, button)
	button.Activated:Connect(callback)
	return button
end

local function makeInput(labelText, initialValue, order)
	local label = makeLabel(labelText, 18, order)
	local input = create("TextBox", {
		Size = UDim2.new(1, 0, 0, 32),
		BackgroundColor3 = COLORS.panelDark,
		BorderSizePixel = 0,
		Font = Enum.Font.Code,
		TextSize = 14,
		TextColor3 = COLORS.text,
		PlaceholderColor3 = COLORS.sub,
		Text = tostring(initialValue),
		ClearTextOnFocus = false,
		LayoutOrder = order + 1,
	}, root)
	create("UICorner", { CornerRadius = UDim.new(0, 6) }, input)
	return input, label
end

local statusLabel = makeLabel("Fence: choose a reference part. Trim: click a building surface.", 38, 1)
local modeButton
local referenceButton
local insetInput
local widthInput
local heightInput
local insetLabel
local widthLabel
local heightLabel
local textureButton
modeButton = makeButton("Mode: Fence", 2, function()
	mode = if mode == "fence" then "trim" else "fence"
	if mode == "trim" and sourcePart then
		height = sourcePart.Size.Y
		heightInput.Text = tostring(height)
	end
	modeButton.Text = "Mode: " .. (mode == "fence" and "Fence" or "Trim")
	updateModeVisibility()
	refreshPreview()
end)

local function setStatus(message, color)
	statusLabel.Text = message
	statusLabel.TextColor3 = color or COLORS.text
end

local function clearPreview()
	for _, part in previewParts do
		part:Destroy()
	end
	table.clear(previewParts)
end

local function getPreviewFolder()
	local camera = workspace.CurrentCamera
	if not camera then
		return nil
	end
	local folder = camera:FindFirstChild("EdgeFillPreview")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "EdgeFillPreview"
		folder.Archivable = false
		folder.Parent = camera
	end
	previewFolder = folder
	return folder
end

local function clonePart(part)
	local wasArchivable = part.Archivable
	part.Archivable = true
	local ok, clone = pcall(function()
		return part:Clone()
	end)
	part.Archivable = wasArchivable
	if not ok or not clone then
		error("Could not clone " .. part:GetFullName())
	end
	return clone
end

local function faceNormal(vertices, shapeCenter)
	local normal = (vertices[2] - vertices[1]):Cross(vertices[3] - vertices[1]).Unit
	local center = Vector3.zero
	for _, vertex in vertices do
		center += vertex
	end
	center /= #vertices
	if normal:Dot(center - shapeCenter) < 0 then
		normal = -normal
	end
	return normal
end

local function makeFaces(part)
	local half = part.Size / 2
	local x, y, z = half.X, half.Y, half.Z
	local faces = {}
	local function add(vertices)
		table.insert(faces, vertices)
	end
	if part:IsA("WedgePart") then
		add({ Vector3.new(-x, -y, -z), Vector3.new(x, -y, -z), Vector3.new(x, -y, z), Vector3.new(-x, -y, z) })
		add({ Vector3.new(-x, -y, z), Vector3.new(-x, y, -z), Vector3.new(x, y, -z), Vector3.new(x, -y, z) })
		add({ Vector3.new(-x, -y, -z), Vector3.new(x, -y, -z), Vector3.new(x, y, -z), Vector3.new(-x, y, -z) })
		add({ Vector3.new(-x, -y, -z), Vector3.new(-x, -y, z), Vector3.new(-x, y, -z) })
		add({ Vector3.new(x, -y, -z), Vector3.new(x, y, -z), Vector3.new(x, -y, z) })
	elseif part:IsA("CornerWedgePart") then
		add({ Vector3.new(-x, -y, -z), Vector3.new(x, -y, -z), Vector3.new(x, -y, z), Vector3.new(-x, -y, z) })
		add({ Vector3.new(-x, -y, -z), Vector3.new(-x, -y, z), Vector3.new(-x, y, -z) })
		add({ Vector3.new(-x, -y, -z), Vector3.new(-x, y, -z), Vector3.new(x, -y, -z) })
		add({ Vector3.new(-x, -y, z), Vector3.new(x, -y, z), Vector3.new(-x, y, -z) })
		add({ Vector3.new(x, -y, z), Vector3.new(x, -y, -z), Vector3.new(-x, y, -z) })
	else
		add({ Vector3.new(-x, -y, -z), Vector3.new(x, -y, -z), Vector3.new(x, -y, z), Vector3.new(-x, -y, z) })
		add({ Vector3.new(-x, y, -z), Vector3.new(-x, y, z), Vector3.new(x, y, z), Vector3.new(x, y, -z) })
		add({ Vector3.new(-x, -y, -z), Vector3.new(-x, -y, z), Vector3.new(-x, y, z), Vector3.new(-x, y, -z) })
		add({ Vector3.new(x, -y, -z), Vector3.new(x, y, -z), Vector3.new(x, y, z), Vector3.new(x, -y, z) })
		add({ Vector3.new(-x, -y, -z), Vector3.new(-x, y, -z), Vector3.new(x, y, -z), Vector3.new(x, -y, -z) })
		add({ Vector3.new(-x, -y, z), Vector3.new(x, -y, z), Vector3.new(x, y, z), Vector3.new(-x, y, z) })
	end
	return faces
end

local function getSurfacePolygon(part, worldNormal)
	if part:IsA("Part") and part.Shape == Enum.PartType.Cylinder then
		local localNormal = part.CFrame:VectorToObjectSpace(worldNormal)
		if math.abs(localNormal.X) < 0.85 then
			return nil
		end
		local vertices = {}
		local sign = if localNormal.X >= 0 then 1 else -1
		for index = 0, 31 do
			local angle = index / 32 * math.pi * 2
			table.insert(
				vertices,
				part.CFrame:PointToWorldSpace(
					Vector3.new(
						sign * part.Size.X / 2,
						math.cos(angle) * part.Size.Y / 2,
						math.sin(angle) * part.Size.Z / 2
					)
				)
			)
		end
		return vertices
	end
	local localNormal = part.CFrame:VectorToObjectSpace(worldNormal)
	local faces = makeFaces(part)
	local shapeCenter = Vector3.zero
	local uniqueVertices = {}
	for _, vertices in faces do
		for _, vertex in vertices do
			local key = tostring(vertex)
			if not uniqueVertices[key] then
				uniqueVertices[key] = vertex
				shapeCenter += vertex
			end
		end
	end
	local vertexCount = 0
	for _ in uniqueVertices do
		vertexCount += 1
	end
	shapeCenter /= math.max(vertexCount, 1)
	local selected
	local selectedDot = -math.huge
	for _, vertices in faces do
		local normal = faceNormal(vertices, shapeCenter)
		local dot = normal:Dot(localNormal)
		if dot > selectedDot then
			selectedDot = dot
			selected = vertices
		end
	end
	if not selected then
		return nil
	end
	local result = {}
	for _, vertex in selected do
		table.insert(result, part.CFrame:PointToWorldSpace(vertex))
	end
	return result
end

local function getSurfaceLoops(part, worldNormal)
	if part:IsA("Part") and part.Shape == Enum.PartType.Cylinder then
		local localNormal = part.CFrame:VectorToObjectSpace(worldNormal)
		local axis = part.CFrame.RightVector
		local loops = {}
		local function makeRing(x)
			local vertices = {}
			for index = 0, 31 do
				local angle = index / 32 * math.pi * 2
				table.insert(
					vertices,
					part.CFrame:PointToWorldSpace(
						Vector3.new(x, math.cos(angle) * part.Size.Y / 2, math.sin(angle) * part.Size.Z / 2)
					)
				)
			end
			return vertices
		end
		if math.abs(localNormal.X) > 0.85 then
			return {
				{
					vertices = makeRing((if localNormal.X >= 0 then 1 else -1) * part.Size.X / 2),
					normal = axis * (if localNormal.X >= 0 then 1 else -1),
				},
			}
		end
		for _, sign in { -1, 1 } do
			table.insert(loops, { vertices = makeRing(sign * part.Size.X / 2), normal = axis })
		end
		return loops
	end
	local vertices = getSurfacePolygon(part, worldNormal)
	if not vertices then
		return nil
	end
	return { { vertices = vertices, normal = worldNormal } }
end

local function getCentroid(vertices)
	local center = Vector3.zero
	for _, vertex in vertices do
		center += vertex
	end
	return center / #vertices
end

local function getEdges(vertices)
	local edges = {}
	for index, first in vertices do
		local second = vertices[index % #vertices + 1]
		local delta = second - first
		if delta.Magnitude > 0.001 then
			table.insert(edges, {
				first = first,
				second = second,
				tangent = delta.Unit,
				length = delta.Magnitude,
			})
		end
	end
	return edges
end

local function getOutward(edge, center, normal)
	local midpoint = (edge.first + edge.second) / 2
	local inward = center - midpoint
	inward -= normal * inward:Dot(normal)
	if inward.Magnitude < 0.001 then
		return nil
	end
	return -inward.Unit, inward.Unit
end

local function getFenceFrame(position, tangent, outward, normal, lengthAxis)
	if lengthAxis == "Y" then
		return CFrame.fromMatrix(position, tangent:Cross(-outward).Unit, tangent, -outward)
	end
	return CFrame.fromMatrix(position, normal:Cross(-outward).Unit, normal, -outward)
end

local function removeInwardTextures(clone, inward)
	local localInward = clone.CFrame:VectorToObjectSpace(inward)
	for _, child in clone:GetChildren() do
		if child:IsA("Texture") or child:IsA("Decal") then
			local faceVector = Vector3.FromNormalId(child.Face)
			if faceVector:Dot(localInward) > 0.5 then
				child:Destroy()
			end
		end
	end
end

local function getLengthAxis(part)
	if part.Size.X >= part.Size.Y and part.Size.X >= part.Size.Z then
		return "X"
	elseif part.Size.Y >= part.Size.Z then
		return "Y"
	end
	return "Z"
end

local function makeFence(edge, outward, normal)
	local clone = clonePart(referencePart)
	local axis = getLengthAxis(referencePart)
	local size = clone.Size
	if axis == "Z" then
		size = Vector3.new(size.Z, size.Y, size.X)
		axis = "X"
	end
	local overlap = math.max(0.02, math.min(size.X, size.Y, size.Z) * 0.025)
	local targetLength = edge.length + overlap * 2
	if axis == "X" then
		size = Vector3.new(targetLength, size.Y, size.Z)
	else
		size = Vector3.new(size.X, targetLength, size.Z)
	end
	clone.Size = size
	local position = (edge.first + edge.second) / 2
	clone.CFrame = getFenceFrame(position, edge.tangent, outward, normal, axis)
	clone.CanQuery = false
	clone.Parent = getPreviewFolder()
	table.insert(previewParts, clone)
end

local function makeTrim(edge, inward, normal)
	local clone = clonePart(sourcePart)
	local size
	local localTangent = sourcePart.CFrame:VectorToObjectSpace(edge.tangent)
	local lengthAxis = if math.abs(localTangent.X) >= math.abs(localTangent.Z) then "X" else "Z"
	local length = edge.length
	local sourceTangent = sourcePart.CFrame:VectorToObjectSpace(edge.tangent)
	if math.abs(sourceTangent.Z) > math.abs(sourceTangent.X) then
		length -= 2 * (width + inset)
	end
	if length <= 0.001 then
		return
	end
	local edgeCenter = (edge.first + edge.second) / 2 - inward * (inset + width / 2)
	if lengthAxis == "X" then
		size = Vector3.new(length, height, width)
	else
		size = Vector3.new(width, height, length)
	end
	clone.Size = size
	local baseFrame = sourcePart.CFrame
	local surfaceAlignment = CFrame.identity
	if sourcePart:IsA("WedgePart") then
		local targetUp = normal
		local targetRight = edge.tangent
		local targetBack = targetRight:Cross(targetUp).Unit
		if lengthAxis == "X" then
			surfaceAlignment = CFrame.fromMatrix(Vector3.zero, targetRight, targetUp, targetBack)
		else
			surfaceAlignment = CFrame.fromMatrix(Vector3.zero, targetBack, targetUp, -targetRight)
		end
		baseFrame = CFrame.new(sourcePart.Position) * surfaceAlignment.Rotation
	end
	clone.CFrame = CFrame.new(edgeCenter) * baseFrame.Rotation
	if deletingInwardTextures then
		removeInwardTextures(clone, inward)
	end
	clone.CanQuery = false
	clone.Parent = getPreviewFolder()
	table.insert(previewParts, clone)
end

local function buildPreview()
	clearPreview()
	if not sourcePart or (mode == "fence" and not referencePart) or not surfaceLoops or not surfaceNormal then
		return
	end
	if
		mode == "trim"
		and not (sourcePart:IsA("WedgePart") or sourcePart:IsA("Part") and sourcePart.Shape == Enum.PartType.Block)
	then
		setStatus("Trim supports block and wedge surfaces.", COLORS.bad)
		return
	end
	local ok, err = pcall(function()
		for _, loop in surfaceLoops do
			local center = getCentroid(loop.vertices)
			for _, edge in getEdges(loop.vertices) do
				local outward, inward = getOutward(edge, center, loop.normal)
				if outward and inward then
					if mode == "fence" then
						makeFence(edge, outward, loop.normal)
					else
						makeTrim(edge, inward, surfaceNormal)
					end
				end
			end
		end
	end)
	if not ok then
		clearPreview()
		setStatus("Preview failed: " .. tostring(err), COLORS.bad)
	else
		setStatus(string.format("%d edge pieces previewed. Adjust settings, then apply.", #previewParts), COLORS.ok)
	end
end

local function parseNumber(input, fallback, allowNegative)
	local value = tonumber(input.Text)
	if not value or value ~= value or value == math.huge or value == -math.huge then
		return fallback
	end
	if not allowNegative then
		value = math.max(0, value)
	end
	return value
end

refreshPreview = function()
	if not sourcePart or not surfaceLoops then
		return
	end
	if mode == "fence" and not referencePart then
		clearPreview()
		setStatus("Select a fence reference part to preview.", COLORS.sub)
		return
	end
	inset = parseNumber(insetInput, inset, false)
	width = math.max(0.001, parseNumber(widthInput, width))
	height = math.max(0.001, parseNumber(heightInput, height))
	buildPreview()
end

updateModeVisibility = function()
	local trim = mode == "trim"
	referenceButton.Visible = not trim
	insetInput.Visible = trim
	widthInput.Visible = trim
	heightInput.Visible = trim
	insetLabel.Visible = trim
	widthLabel.Visible = trim
	heightLabel.Visible = trim
	textureButton.Visible = trim
end

local function chooseReference()
	if mode ~= "fence" then
		setStatus("Trim uses the clicked building part as its source.", COLORS.sub)
		return
	end
	for _, instance in Selection:Get() do
		if instance:IsA("BasePart") then
			referencePart = instance
			referenceButton.Text = "Fence Part: " .. instance.Name
			refreshPreview()
			return
		end
	end
	setStatus("Select a BasePart in Explorer or the viewport first.", COLORS.bad)
end

local function beginPlacement()
	placing = true
	plugin:Activate(true)
	setStatus("Click a surface to preview its edge pieces.")
end

local function selectSurface()
	local ray = workspace:Raycast(mouse.UnitRay.Origin, mouse.UnitRay.Direction * 1000)
	if not ray or not ray.Instance:IsA("BasePart") then
		return
	end
	local part = ray.Instance
	local supported = part:IsA("WedgePart")
		or part:IsA("CornerWedgePart")
		or part:IsA("Part") and (part.Shape == Enum.PartType.Block or part.Shape == Enum.PartType.Cylinder)
	if not supported then
		setStatus("Fence supports blocks, wedges, corner wedges, and cylinders.", COLORS.bad)
		return
	end
	local loops = getSurfaceLoops(part, ray.Normal)
	if not loops or #loops == 0 or #loops[1].vertices < 3 then
		setStatus("This surface is not supported.", COLORS.bad)
		return
	end
	if mode == "trim" and not (part:IsA("WedgePart") or part:IsA("Part") and part.Shape == Enum.PartType.Block) then
		setStatus("Trim supports block and wedge surfaces only.", COLORS.bad)
		return
	end
	sourcePart = part
	surfaceLoops = loops
	surfaceNormal = loops[1].normal
	if mode == "trim" then
		height = sourcePart.Size.Y
		heightInput.Text = tostring(height)
	end
	refreshPreview()
end

local function apply()
	if not sourcePart or (mode == "fence" and not referencePart) or not surfaceLoops or #previewParts == 0 then
		setStatus("Select a supported surface and preview edge pieces before applying.", COLORS.bad)
		return
	end
	if not sourcePart.Parent or (mode == "fence" and not referencePart.Parent) then
		setStatus("The source or reference part no longer exists.", COLORS.bad)
		return
	end
	local recording = ChangeHistoryService:TryBeginRecording("EdgeFill_Apply", "Apply Edge Fill")
	if not recording then
		setStatus("Could not begin undo recording. Try again when Studio is not playing.", COLORS.bad)
		return
	end
	local outputs = {}
	local ok, err = pcall(function()
		for _, preview in previewParts do
			local clone = clonePart(preview)
			clone.CanQuery = if mode == "fence" then referencePart.CanQuery else sourcePart.CanQuery
			clone.Parent = sourcePart.Parent
			table.insert(outputs, clone)
		end
	end)
	if not ok then
		for _, clone in outputs do
			clone:Destroy()
		end
		ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Cancel)
		setStatus("Apply failed: " .. tostring(err), COLORS.bad)
		return
	end
	ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
	Selection:Set(outputs)
	setStatus(string.format("Applied %d edge pieces.", #outputs), COLORS.ok)
end

referenceButton = makeButton("Select Fence Part", 3, chooseReference)
makeButton("Select Surface", 4, beginPlacement)
insetInput, insetLabel = makeInput("Inset", 0, 5)
widthInput, widthLabel = makeInput("Width", 2, 7)
heightInput, heightLabel = makeInput("Height", 2, 9)
textureButton = makeButton("Delete Inward Textures: Off", 11, function()
	deletingInwardTextures = not deletingInwardTextures
	textureButton.Text = "Delete Inward Textures: " .. (deletingInwardTextures and "On" or "Off")
	refreshPreview()
end)
makeButton("Apply", 12, apply)

for _, input in { insetInput, widthInput, heightInput } do
	connect(input:GetPropertyChangedSignal("Text"), function()
		if input:IsFocused() then
			refreshPreview()
		end
	end)
	connect(input.FocusLost, refreshPreview)
end

connect(mouse.Button1Down, function()
	if placing and widget.Enabled then
		placing = false
		selectSurface()
	end
end)

connect(plugin.Deactivation, function()
	if placing then
		placing = false
		setStatus("Surface selection paused because another Studio tool was activated.")
	end
end)

local toggleButton
local function reloadButtons()
	toolbar = shared.paTools
	toggleButton =
		toolbar.addButton("edgeFill", "Create fences or trim along a surface perimeter", "rbxassetid://4458901886")
	toolbar.setButtonHandler("edgeFill", function()
		widget.Enabled = not widget.Enabled
		toggleButton:SetActive(widget.Enabled)
	end)
end

local toolbarCallbacks = shared.paToolbarCallbacks
if not toolbarCallbacks then
	toolbarCallbacks = {}
	shared.paToolbarCallbacks = toolbarCallbacks
end
toolbarCallbacks.edgeFill = reloadButtons
reloadButtons()

connect(widget:GetPropertyChangedSignal("Enabled"), function()
	toggleButton:SetActive(widget.Enabled)
	if not widget.Enabled then
		placing = false
		clearPreview()
	else
		plugin:Activate(true)
	end
end)

connect(plugin.Unloading, function()
	toolbarCallbacks.edgeFill = nil
	toolbar.removeButtonHandler("edgeFill")
	clearPreview()
	if previewFolder then
		previewFolder:Destroy()
	end
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
	plugin:Deactivate()
end)

updateModeVisibility()
toggleButton:SetActive(widget.Enabled)
