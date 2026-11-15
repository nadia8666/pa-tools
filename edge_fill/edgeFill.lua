local ChangeHistoryService = game:GetService("ChangeHistoryService")
local Selection = game:GetService("Selection")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

if not RunService:IsEdit() then
	return
end

local COLORS = {
	top = Color3.fromRGB(32, 34, 48),
	bottom = Color3.fromRGB(16, 17, 23),
	panel = Color3.fromRGB(40, 42, 58),
	panelDark = Color3.fromRGB(22, 23, 32),
	stroke = Color3.fromRGB(78, 82, 108),
	text = Color3.fromRGB(230, 232, 240),
	sub = Color3.fromRGB(140, 145, 168),
	accent = Color3.fromRGB(88, 140, 255),
	accentDark = Color3.fromRGB(58, 98, 210),
	ok = Color3.fromRGB(80, 200, 120),
	warn = Color3.fromRGB(235, 180, 60),
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
local selectedSurfaces = {}
local previewSources = {}
local multiSelecting = false
local surfaceHighlight
local referencePart
local surfaceNormal
local surfaceLocalNormal
local surfaceLoops
local surfaceConnections = {}
local previewFolder
local previewParts = {}
local connections = {}
local placing = false
local deletingInwardTextures = false
local inset = 0
local width = 2
local height = 2
local CYLINDER_SIDES = 24
local CYLINDER_ANGLES = {}
for index = 0, CYLINDER_SIDES - 1 do
	table.insert(CYLINDER_ANGLES, index / CYLINDER_SIDES * math.pi * 2)
end

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

local page = create("Frame", {
	Size = UDim2.fromScale(1, 1),
	BackgroundColor3 = Color3.new(0.098039, 0.101961, 0.105882),
	BorderSizePixel = 0,
}, widget)
local scroller = create("ScrollingFrame", {
	Size = UDim2.fromScale(1, 1),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	CanvasSize = UDim2.new(),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	ScrollingDirection = Enum.ScrollingDirection.Y,
	ScrollBarThickness = 4,
	ScrollBarImageColor3 = COLORS.stroke,
}, page)
create("UIPadding", {
	PaddingTop = UDim.new(0, 10),
	PaddingBottom = UDim.new(0, 10),
	PaddingLeft = UDim.new(0, 10),
	PaddingRight = UDim.new(0, 10),
}, scroller)
create("UIListLayout", { Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder }, scroller)

local root = create("Frame", {
	Size = UDim2.new(1, 0, 0, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundColor3 = Color3.new(0.086275, 0.090196, 0.105882),
	BackgroundTransparency = 0.2,
	BorderSizePixel = 0,
	LayoutOrder = 1,
}, scroller)
create("UICorner", { CornerRadius = UDim.new(0, 10) }, root)
create("UIStroke", { Color = COLORS.stroke, Thickness = 1, Transparency = 0.5 }, root)
create("UIPadding", {
	PaddingTop = UDim.new(0, 10),
	PaddingBottom = UDim.new(0, 10),
	PaddingLeft = UDim.new(0, 10),
	PaddingRight = UDim.new(0, 10),
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
	create("UIStroke", { Color = COLORS.stroke, Thickness = 1, Transparency = 0.65 }, input)
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
	table.clear(previewSources)
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

local function isWedge(part)
	return part:IsA("WedgePart") or part:IsA("Part") and part.Shape == Enum.PartType.Wedge
end

local function isCornerWedge(part)
	return part:IsA("CornerWedgePart") or part:IsA("Part") and part.Shape == Enum.PartType.CornerWedge
end

local function isCylinder(part)
	return part:IsA("Part") and part.Shape == Enum.PartType.Cylinder
end

local function makeFaces(part)
	local half = part.Size / 2
	local x, y, z = half.X, half.Y, half.Z
	local faces = {}
	local function add(vertices)
		if isWedge(part) or isCornerWedge(part) then
			for index, vertex in vertices do
				vertices[index] = Vector3.new(vertex.X, vertex.Y, -vertex.Z)
			end
		end
		table.insert(faces, vertices)
	end
	if isWedge(part) then
		add({ Vector3.new(-x, -y, -z), Vector3.new(x, -y, -z), Vector3.new(x, -y, z), Vector3.new(-x, -y, z) })
		add({ Vector3.new(-x, -y, z), Vector3.new(-x, y, -z), Vector3.new(x, y, -z), Vector3.new(x, -y, z) })
		add({ Vector3.new(-x, -y, -z), Vector3.new(x, -y, -z), Vector3.new(x, y, -z), Vector3.new(-x, y, -z) })
		add({ Vector3.new(-x, -y, -z), Vector3.new(-x, -y, z), Vector3.new(-x, y, -z) })
		add({ Vector3.new(x, -y, -z), Vector3.new(x, y, -z), Vector3.new(x, -y, z) })
	elseif isCornerWedge(part) then
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
	if isCylinder(part) then
		local localNormal = part.CFrame:VectorToObjectSpace(worldNormal)
		if math.abs(localNormal.X) < 0.85 then
			return nil
		end
		local sign = if localNormal.X >= 0 then 1 else -1
		local half = part.Size / 2
		local vertices = {}
		for _, angle in CYLINDER_ANGLES do
			table.insert(vertices, part.CFrame:PointToWorldSpace(Vector3.new(sign * half.X, math.cos(angle) * half.Y, math.sin(angle) * half.Z)))
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
	local selectedDot = 0.75
	for _, vertices in faces do
		local dot = faceNormal(vertices, shapeCenter):Dot(localNormal)
		if dot > selectedDot then
			selectedDot = dot
			selected = vertices
		end
	end
	if not selected then
		return nil
	end
	local result = {}
	for index, vertex in selected do
		result[index] = part.CFrame:PointToWorldSpace(vertex)
	end
	return result
end

local function getSurfaceLoops(part, worldNormal)
	local vertices = getSurfacePolygon(part, worldNormal)
	if not vertices then
		return nil
	end
	local normal = (vertices[2] - vertices[1]):Cross(vertices[3] - vertices[1]).Unit
	if normal:Dot(worldNormal) < 0 then
		normal = -normal
	end
	return { { vertices = vertices, normal = normal } }
end

local function getCentroid(vertices)
	local center = Vector3.zero
	for _, vertex in vertices do
		center += vertex
	end
	return center / #vertices
end

local function getEdges(vertices, normal)
	local center = getCentroid(vertices)
	local edges = {}
	for index, first in vertices do
		local second = vertices[index % #vertices + 1]
		local delta = second - first
		if delta.Magnitude > 0.001 then
			local tangent = delta.Unit
			local inward = normal:Cross(tangent).Unit
			if inward:Dot(center - (first + second) / 2) < 0 then
				inward = -inward
			end
			table.insert(edges, {
				first = first,
				second = second,
				tangent = tangent,
				inward = inward,
				length = delta.Magnitude,
				trimStart = 0,
				trimEnd = 0,
			})
		end
	end
	return edges
end

local function assignCornerTrims(edges)
	local count = #edges
	for index, edge in edges do
		local nextEdge = edges[index % count + 1]
		local cosAngle = -edge.tangent:Dot(nextEdge.tangent)
		local sinAngle = math.sqrt(math.max(0, 1 - cosAngle * cosAngle))
		if sinAngle > 0.01 then
			local offset = if cosAngle > 0 then inset + width else inset
			local owned = (inset + offset * cosAngle) / sinAngle
			local yielded = (inset + width + offset * cosAngle) / sinAngle
			if cosAngle < 0 then
				yielded = math.min(yielded, math.max(0, ((inset + width) * sinAngle - owned) / -cosAngle))
			end
			if index % 2 == 1 then
				edge.trimEnd = owned
				nextEdge.trimStart = yielded
			else
				edge.trimEnd = yielded
				nextEdge.trimStart = owned
			end
		end
	end
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

local function setComponent(size, index, value)
	local components = { size.X, size.Y, size.Z }
	components[index] = value
	return Vector3.new(components[1], components[2], components[3])
end

local function rotationBetween(from, to)
	local axis = from:Cross(to)
	if axis.Magnitude < 0.000001 then
		return CFrame.identity
	end
	return CFrame.fromAxisAngle(axis.Unit, math.acos(math.clamp(from:Dot(to), -1, 1)))
end

local function makeFence(edge, normal)
	local clone = clonePart(referencePart)
	local size = clone.Size
	local sizes = { size.X, size.Y, size.Z }
	local order = { 1, 2, 3 }
	table.sort(order, function(first, second)
		if sizes[first] == sizes[second] then
			return first < second
		end
		return sizes[first] > sizes[second]
	end)
	local lengthIndex, heightIndex, thicknessIndex = order[1], order[2], order[3]
	local function getThickness(tangent)
		local columns = {}
		columns[lengthIndex] = tangent
		columns[heightIndex] = normal
		if thicknessIndex == 3 then
			return columns[1]:Cross(columns[2])
		elseif thicknessIndex == 1 then
			return columns[2]:Cross(columns[3])
		end
		return columns[3]:Cross(columns[1])
	end
	local tangent = edge.tangent
	local thickness = getThickness(tangent)
	if thickness:Dot(edge.inward) < 0 then
		tangent = -tangent
		thickness = -thickness
	end
	local columns = {}
	columns[lengthIndex] = tangent
	columns[heightIndex] = normal
	columns[thicknessIndex] = thickness
	local midpoint = (edge.first + edge.second) / 2
	local center = midpoint + normal * (sizes[heightIndex] / 2) + edge.inward * (sizes[thicknessIndex] / 2)
	clone.Size = setComponent(size, lengthIndex, edge.length)
	clone.CFrame = CFrame.fromMatrix(center, columns[1], columns[2], columns[3])
	clone.CanQuery = false
	clone.Archivable = false
	clone.Parent = getPreviewFolder()
	table.insert(previewParts, clone)
end

local function makeTrim(edge, normal, part)
	local length = edge.length - edge.trimStart - edge.trimEnd
	if length <= 0.001 then
		return
	end
	local source = clonePart(part)
	local clone = Instance.new("Part")
	for _, property in {
		"Anchored",
		"CanCollide",
		"CanTouch",
		"CanQuery",
		"CastShadow",
		"Color",
		"CollisionGroup",
		"CustomPhysicalProperties",
		"Material",
		"MaterialVariant",
		"Massless",
		"Reflectance",
		"Transparency",
	} do
		clone[property] = source[property]
	end
	for _, child in source:GetChildren() do
		child.Parent = clone
	end
	source:Destroy()
	local base = part.CFrame.Rotation
	local axes = { base.XVector, base.YVector, base.ZVector }
	local heightIndex, heightDot = 1, -1
	for index, axis in axes do
		local dot = math.abs(axis:Dot(normal))
		if dot > heightDot then
			heightIndex, heightDot = index, dot
		end
	end
	local lengthIndex, lengthDot = 1, -1
	for index, axis in axes do
		if index ~= heightIndex then
			local dot = math.abs(axis:Dot(edge.tangent))
			if dot > lengthDot then
				lengthIndex, lengthDot = index, dot
			end
		end
	end
	local widthIndex = 6 - heightIndex - lengthIndex
	local up = axes[heightIndex] * (if axes[heightIndex]:Dot(normal) >= 0 then 1 else -1)
	local rotation = rotationBetween(up, normal) * base
	local lengthAxis = ({ rotation.XVector, rotation.YVector, rotation.ZVector })[lengthIndex]
	local flat = lengthAxis - normal * lengthAxis:Dot(normal)
	if flat.Magnitude > 0.001 then
		local target = edge.tangent * (if flat:Dot(edge.tangent) >= 0 then 1 else -1)
		rotation = CFrame.fromAxisAngle(normal, math.atan2(normal:Dot(flat:Cross(target)), flat:Dot(target))) * rotation
	end
	local size = Vector3.zero
	size = setComponent(size, heightIndex, height)
	size = setComponent(size, lengthIndex, length)
	size = setComponent(size, widthIndex, width)
	local center = edge.first
		+ edge.tangent * (edge.trimStart + length / 2)
		+ edge.inward * (inset + width / 2)
		+ normal * (height / 2)
	clone.Size = size
	clone.CFrame = CFrame.new(center) * rotation
	if deletingInwardTextures then
		removeInwardTextures(clone, edge.inward)
	end
	clone.CanQuery = false
	clone.Archivable = false
	clone.Parent = getPreviewFolder()
	table.insert(previewParts, clone)
	previewSources[clone] = part.Parent
end

local function buildPreview()
	clearPreview()
	if #selectedSurfaces == 0 or (mode == "fence" and not referencePart) then
		return
	end
	local ok, err = pcall(function()
		for _, surface in selectedSurfaces do
			local part = surface.part
			if part.Parent then
				for _, loop in surface.loops do
					local edges = getEdges(loop.vertices, loop.normal)
					if mode == "trim" then
						assignCornerTrims(edges)
					end
					for _, edge in edges do
						if mode == "fence" then
							makeFence(edge, loop.normal)
							previewSources[previewParts[#previewParts]] = part.Parent
						else
							makeTrim(edge, loop.normal, part)
						end
					end
				end
			end
		end
	end)
	if not ok then
		clearPreview()
		setStatus("Preview failed: " .. tostring(err), COLORS.bad)
	else
		setStatus(string.format("%d edge pieces previewed across %d surfaces. Adjust settings, then apply.", #previewParts, #selectedSurfaces), COLORS.ok)
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

local refreshSurface = function()
	for _, surface in selectedSurfaces do
		if surface.part.Parent then
			surface.normal = surface.part.CFrame:VectorToWorldSpace(surface.localNormal).Unit
			surface.loops = getSurfaceLoops(surface.part, surface.normal)
		else
			surface.loops = nil
		end
	end
end

refreshPreview = function()
	if #selectedSurfaces == 0 then
		return
	end
	refreshSurface()
	for _, surface in selectedSurfaces do
		if not surface.loops or #surface.loops == 0 then
			clearPreview()
			setStatus("A selected surface is no longer valid.", COLORS.bad)
			return
		end
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

local function getSurfaceNormalId(part, worldNormal)
	local normal = part.CFrame:VectorToObjectSpace(worldNormal)
	local x, y, z = math.abs(normal.X), math.abs(normal.Y), math.abs(normal.Z)
	if x > y and x > z then
		return if normal.X > 0 then Enum.NormalId.Right else Enum.NormalId.Left
	elseif y > x and y > z then
		return if normal.Y > 0 then Enum.NormalId.Top else Enum.NormalId.Bottom
	end
	return if normal.Z > 0 then Enum.NormalId.Back else Enum.NormalId.Front
end

local function updateSurfaceHighlight()
	if not placing then
		return
	end
	local ray = workspace:Raycast(mouse.UnitRay.Origin, mouse.UnitRay.Direction * 1000)
	if ray and ray.Instance:IsA("BasePart") then
		local part = ray.Instance
		local supported = isWedge(part)
			or isCornerWedge(part)
			or part:IsA("Part") and (part.Shape == Enum.PartType.Block or isCylinder(part))
		local loops = if supported then getSurfaceLoops(part, ray.Normal) else nil
		if loops and #loops > 0 and (mode ~= "trim" or isWedge(part) or isCornerWedge(part) or part:IsA("Part") and part.Shape == Enum.PartType.Block) then
			surfaceHighlight.Adornee = part
			surfaceHighlight.TargetSurface = getSurfaceNormalId(part, ray.Normal)
			return
		end
	end
	surfaceHighlight.Adornee = nil
end

local function beginPlacement()
	local folder = getPreviewFolder()
	if not folder then
		setStatus("The current camera is unavailable.", COLORS.bad)
		return
	end
	if not surfaceHighlight then
		surfaceHighlight = Instance.new("SurfaceSelection")
		surfaceHighlight.Name = "SurfaceHighlight"
		surfaceHighlight.Color3 = Color3.new(1, 0.3, 0.3)
		surfaceHighlight.Transparency = 0.5
		surfaceHighlight.Archivable = false
		surfaceHighlight.Parent = folder
	end
	table.clear(selectedSurfaces)
	sourcePart = nil
	for _, connection in surfaceConnections do
		connection:Disconnect()
	end
	table.clear(surfaceConnections)
	clearPreview()
	multiSelecting = false
	placing = true
	plugin:Activate(true)
	updateSurfaceHighlight()
	setStatus("Click a surface. Hold Shift while clicking to select multiple surfaces.")
end

local function selectSurface()
	local ray = workspace:Raycast(mouse.UnitRay.Origin, mouse.UnitRay.Direction * 1000)
	if not ray or not ray.Instance:IsA("BasePart") then
		return false
	end
	local part = ray.Instance
	local supported = isWedge(part)
		or isCornerWedge(part)
		or part:IsA("Part") and (part.Shape == Enum.PartType.Block or isCylinder(part))
	if not supported then
		setStatus("Supported surfaces: block, wedge, corner wedge, and cylinder end caps.", COLORS.bad)
		return false
	end
	if mode == "trim" and not (part:IsA("Part") and part.Shape == Enum.PartType.Block or isWedge(part) or isCornerWedge(part)) then
		setStatus("Trim supports block, wedge, and corner wedge surfaces only.", COLORS.bad)
		return false
	end
	local localNormal = part.CFrame:VectorToObjectSpace(ray.Normal)
	local normal = part.CFrame:VectorToWorldSpace(localNormal).Unit
	local loops = getSurfaceLoops(part, normal)
	if not loops or #loops == 0 or #loops[1].vertices < 3 then
		setStatus("This face is not supported. Only cylinder end caps can be selected.", COLORS.bad)
		return false
	end
	for _, surface in selectedSurfaces do
		if surface.part == part and surface.localNormal:Dot(localNormal) > 0.99 then
			setStatus("That surface is already selected.", COLORS.warn)
			return false
		end
	end
	table.insert(selectedSurfaces, {
		part = part,
		localNormal = localNormal,
		normal = normal,
		loops = loops,
	})
	sourcePart = selectedSurfaces[1].part
	for _, property in { "Size", "CFrame" } do
		table.insert(surfaceConnections, part:GetPropertyChangedSignal(property):Connect(refreshPreview))
	end
	refreshPreview()
	return true
end

local function apply()
	if #selectedSurfaces == 0 or (mode == "fence" and not referencePart) or #previewParts == 0 then
		setStatus("Select supported surfaces and preview edge pieces before applying.", COLORS.bad)
		return
	end
	if (mode == "fence" and not referencePart.Parent) then
		setStatus("The reference part no longer exists.", COLORS.bad)
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
			clone.Parent = previewSources[preview] or sourcePart.Parent
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
	clearPreview()
	sourcePart = nil
	table.clear(selectedSurfaces)
	referencePart = nil
	for _, connection in surfaceConnections do
		connection:Disconnect()
	end
	table.clear(surfaceConnections)
	referenceButton.Text = "Select Fence Part"
	Selection:Set({})
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

connect(mouse.Move, updateSurfaceHighlight)

connect(mouse.Button1Down, function()
	if placing and widget.Enabled then
		local shiftHeld = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
		if not multiSelecting and not shiftHeld then
			table.clear(selectedSurfaces)
			for _, connection in surfaceConnections do
				connection:Disconnect()
			end
			table.clear(surfaceConnections)
		end
		local selected = selectSurface()
		if not selected then
			return
		end
		if shiftHeld then
			multiSelecting = true
			setStatus(string.format("%d surfaces selected. Release Shift to finish selection.", #selectedSurfaces), COLORS.ok)
		else
			placing = false
			if surfaceHighlight then
				surfaceHighlight.Adornee = nil
			end
		end
	end
end)

connect(UserInputService.InputEnded, function(input)
	if multiSelecting and (input.KeyCode == Enum.KeyCode.LeftShift or input.KeyCode == Enum.KeyCode.RightShift) then
		local leftHeld = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
		local rightHeld = UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
		if not leftHeld and not rightHeld then
			multiSelecting = false
			placing = false
			if surfaceHighlight then
				surfaceHighlight.Adornee = nil
			end
			refreshPreview()
			setStatus(string.format("%d surfaces selected. Adjust settings, then apply.", #selectedSurfaces), COLORS.ok)
		end
	end
end)

connect(plugin.Deactivation, function()
	if placing then
		placing = false
		multiSelecting = false
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
		multiSelecting = false
		if surfaceHighlight then
			surfaceHighlight.Adornee = nil
		end
		clearPreview()
	else
		plugin:Activate(true)
	end
end)

connect(plugin.Unloading, function()
	toolbarCallbacks.edgeFill = nil
	toolbar.removeButtonHandler("edgeFill")
	placing = false
	multiSelecting = false
	if surfaceHighlight then
		surfaceHighlight.Adornee = nil
		surfaceHighlight:Destroy()
	end
	clearPreview()
	for _, connection in surfaceConnections do
		connection:Disconnect()
	end
	table.clear(surfaceConnections)
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
