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
		local vertices = {}
		local sign = if localNormal.X >= 0 then 1 else -1
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Include
		params.FilterDescendantsInstances = { part }
		local radius = math.max(part.Size.Y, part.Size.Z) / 2
		local planes = {}
		for index = 0, 191 do
			local angle = index / 192 * math.pi * 2
			local radial = Vector3.new(0, math.cos(angle), math.sin(angle))
			local origin = part.CFrame:PointToWorldSpace(radial * radius * 2)
			local direction = part.CFrame:VectorToWorldSpace(-radial * radius * 4)
			local hit = workspace:Raycast(origin, direction, params)
			if hit then
				local normal = part.CFrame:VectorToObjectSpace(hit.Normal)
				local duplicate = false
				for _, plane in planes do
					if plane.normal:Dot(normal) > 0.9999 then
						duplicate = true
						break
					end
				end
				if not duplicate then
					local point = part.CFrame:PointToObjectSpace(hit.Position)
					table.insert(planes, { normal = Vector3.new(0, normal.Y, normal.Z).Unit, distance = normal.Y * point.Y + normal.Z * point.Z })
				end
			end
		end
		table.sort(planes, function(first, second)
			return math.atan2(first.normal.Z, first.normal.Y) < math.atan2(second.normal.Z, second.normal.Y)
		end)
		if #planes < 3 then
			for index = 0, 23 do
				local angle = index / 24 * math.pi * 2
				table.insert(vertices, part.CFrame:PointToWorldSpace(Vector3.new(sign * part.Size.X / 2, math.cos(angle) * part.Size.Y / 2, math.sin(angle) * part.Size.Z / 2)))
			end
			return vertices
		end
		for index, first in planes do
			local second = planes[index % #planes + 1]
			local determinant = first.normal.Y * second.normal.Z - first.normal.Z * second.normal.Y
			if math.abs(determinant) > 0.0001 then
				local y = (first.distance * second.normal.Z - first.normal.Z * second.distance) / determinant
				local z = (first.normal.Y * second.distance - first.distance * second.normal.Y) / determinant
				table.insert(vertices, part.CFrame:PointToWorldSpace(Vector3.new(sign * part.Size.X / 2, y, z)))
			end
		end
		return if #vertices >= 3 then vertices else nil
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
	if not selected or selectedDot < 0.9 then
		return nil
	end
	local result = {}
	for _, vertex in selected do
		table.insert(result, part.CFrame:PointToWorldSpace(vertex))
	end
	return result
end

local function getSurfaceLoops(part, worldNormal)
	if isCylinder(part) then
		local localNormal = part.CFrame:VectorToObjectSpace(worldNormal)
		local function makeRing(x)
			local vertices = getSurfacePolygon(part, part.CFrame.RightVector * (if x >= 0 then 1 else -1))
			if not vertices then
				return {}
			end
			return vertices
		end
		if math.abs(localNormal.X) > 0.85 then
			return {
				{
					vertices = makeRing((if localNormal.X >= 0 then 1 else -1) * part.Size.X / 2),
					normal = part.CFrame.RightVector * (if localNormal.X >= 0 then 1 else -1),
				},
			}
		end
		return nil
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
	local targetLength = edge.length
	if axis == "X" then
		size = Vector3.new(targetLength, size.Y, size.Z)
	else
		size = Vector3.new(size.X, targetLength, size.Z)
	end
	clone.Size = size
	local halfHeight = if axis == "X" then size.Y / 2 else size.X / 2
	local position = (edge.first + edge.second) / 2 - outward * (size.Z / 2) + normal * halfHeight
	clone.CFrame = getFenceFrame(position, edge.tangent, outward, normal, axis)
	clone.CanQuery = false
	clone.Archivable = false
	clone.Parent = getPreviewFolder()
	table.insert(previewParts, clone)
end

local function makeTrim(edge, inward, normal, part)
	local clone = clonePart(part)
	local size
	local localTangent = part.CFrame:VectorToObjectSpace(edge.tangent)
	local lengthAxis = if math.abs(localTangent.X) >= math.abs(localTangent.Z) then "X" else "Z"
	local length = edge.length - 2 * inset
	local sourceTangent = part.CFrame:VectorToObjectSpace(edge.tangent)
	if math.abs(sourceTangent.Z) > math.abs(sourceTangent.X) then
		length -= 2 * width
	end
	if length <= 0.001 then
		return
	end
	local edgeCenter = (edge.first + edge.second) / 2 + inward * (inset + width / 2) + normal * (height / 2)
	if lengthAxis == "X" then
		size = Vector3.new(length, height, width)
	else
		size = Vector3.new(width, height, length)
	end
	clone.Size = size
	local baseFrame = part.CFrame
	local surfaceAlignment = CFrame.identity
	if isWedge(part) or isCornerWedge(part) then
		local targetUp = normal
		local targetRight = edge.tangent
		local targetBack = targetRight:Cross(targetUp).Unit
		if lengthAxis == "X" then
			surfaceAlignment = CFrame.fromMatrix(Vector3.zero, targetRight, targetUp, targetBack)
		else
			surfaceAlignment = CFrame.fromMatrix(Vector3.zero, targetBack, targetUp, -targetRight)
		end
		baseFrame = CFrame.new(part.Position) * surfaceAlignment.Rotation
	end
	clone.CFrame = CFrame.new(edgeCenter) * baseFrame.Rotation
	if deletingInwardTextures then
		removeInwardTextures(clone, inward)
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
					local center = getCentroid(loop.vertices)
					for _, edge in getEdges(loop.vertices) do
						local outward, inward = getOutward(edge, center, loop.normal)
						if outward and inward then
							if mode == "fence" then
								makeFence(edge, outward, loop.normal)
								previewSources[previewParts[#previewParts]] = part.Parent
							else
								makeTrim(edge, inward, loop.normal, part)
							end
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
