local AssetService = game:GetService("AssetService")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local Selection = game:GetService("Selection")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

if not RunService:IsEdit() then
	return
end

local MAX_MESH_SIZE = 2048

local COLORS = {
	top = Color3.fromRGB(32, 34, 48),
	bottom = Color3.fromRGB(22, 23, 30),
	panel = Color3.fromRGB(22, 23, 27),
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
local toggleButton

local widgetInfo = DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Right, true, false, 300, 520, 260, 360)
local widget = plugin:CreateDockWidgetPluginGuiAsync("districtMapper", widgetInfo)
widget.Title = "districtMapper"

local previewFolder
local outputFolder
local exportFolder

local mouse = plugin:GetMouse()
local activeGroup = nil
local groups = {}
local selectedPoints = {}
local selectedSectionId
local selectedSections = {}
local selectedDistrictName
local districtButton
local assignDistrictButton
local placingPoints = false
local pointRadius = 3.6
local pointColor = Color3.fromRGB(255, 190, 70)
local edgeColor = Color3.fromRGB(95, 105, 130)
local selectedPointColor = Color3.fromRGB(100, 255, 150)
local selectedEdgeColor = Color3.fromRGB(255, 190, 70)
local groupColor = Color3.fromRGB(85, 170, 255)
local fillMeshes = {}
local runtimeExtrusions = {}
local updatePolygon
local reextrudeSection
local refreshGroups
local scheduleGroupRefresh
local observedMarkers = {}
local connections = {}
local updatingFills = {}
local pendingPolygonUpdates = {}
local pendingGroupRefreshes = {}
local observedAttributes = {}
local observedGroupFolders = {}

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
	CanvasSize = UDim2.fromOffset(0, 0),
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

create("UIListLayout", {
	Padding = UDim.new(0, 8),
	SortOrder = Enum.SortOrder.LayoutOrder,
}, root)

local function makeLabel(text, height, order, parent)
	return create("TextLabel", {
		Size = UDim2.new(1, 0, 0, height),
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
		AutoButtonColor = true,
		LayoutOrder = order,
	}, parent or root)
	create("UICorner", { CornerRadius = UDim.new(0, 6) }, button)
	create("UIStroke", { Color = COLORS.stroke, Thickness = 1, Transparency = 0.35 }, button)
	button.Activated:Connect(callback)
	return button
end

local function makeInput(placeholder, order, parent)
	return create("TextBox", {
		Size = UDim2.new(1, 0, 0, 32),
		BackgroundColor3 = COLORS.panelDark,
		BorderSizePixel = 0,
		Font = Enum.Font.Code,
		TextSize = 14,
		TextColor3 = COLORS.text,
		PlaceholderColor3 = COLORS.sub,
		PlaceholderText = placeholder,
		Text = "",
		ClearTextOnFocus = false,
		LayoutOrder = order,
	}, parent or root)
end

local function makePanel(order)
	local panel = create("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = COLORS.panel,
		BackgroundTransparency = 0.2,
		BorderSizePixel = 0,
		LayoutOrder = order,
	}, root)
	create("UICorner", { CornerRadius = UDim.new(0, 8) }, panel)
	create("UIStroke", { Color = COLORS.stroke, Thickness = 1, Transparency = 0.45 }, panel)
	create("UIPadding", {
		PaddingTop = UDim.new(0, 8),
		PaddingBottom = UDim.new(0, 8),
		PaddingLeft = UDim.new(0, 8),
		PaddingRight = UDim.new(0, 8),
	}, panel)
	create("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, panel)
	return panel
end

local statusLabel = makeLabel("Create a group to begin.", 38, 1)
local groupNameInput
local pointButton
local linkButton
local extrudeButton
local exportButton
local heightInput
local groupButtons = {}
local groupList
local clearSelection

local function updateStatus(message)
	statusLabel.Text = message
end

local function recordAction(name, callback)
	local recording = ChangeHistoryService:TryBeginRecording(name, name)
	if not recording then
		updateStatus("Could not begin undo recording. Try again when Studio is not playing.")
		return
	end
	local ok, result = pcall(callback)
	ChangeHistoryService:FinishRecording(
		recording,
		if ok then Enum.FinishRecordingOperation.Commit else Enum.FinishRecordingOperation.Cancel
	)
	if not ok then
		updateStatus(name .. " failed: " .. tostring(result))
	end
end

local function updateButtons()
	pointButton.Text = placingPoints and "Stop placing points" or "Add points"
	linkButton.Text = "Link selected points (" .. #selectedPoints .. ")"
	districtButton.Text = "Selected: " .. (selectedDistrictName or "none")
	assignDistrictButton.Active = next(selectedSections) ~= nil and selectedDistrictName ~= nil
	assignDistrictButton.BackgroundColor3 = assignDistrictButton.Active and COLORS.accentDark or COLORS.panelDark
	extrudeButton.Active = next(selectedSections) ~= nil
	extrudeButton.BackgroundColor3 = extrudeButton.Active and COLORS.accentDark or COLORS.panelDark
	extrudeButton.TextColor3 = extrudeButton.Active and Color3.fromRGB(245, 246, 250) or COLORS.sub
	for _, button in groupButtons do
		button:Destroy()
	end
	table.clear(groupButtons)
	local districtFolder = ReplicatedStorage:FindFirstChild("Districts")
	local districts = districtFolder and districtFolder:GetChildren() or {}
	table.sort(districts, function(first, second)
		return first.Name < second.Name
	end)
	for index, district in districts do
		local button = makeButton(
			(district.Name == selectedDistrictName and "●  " or "○  ") .. district.Name,
			index,
			function()
				selectedDistrictName = district.Name
				updateStatus("Selected district " .. district.Name .. ". Select a face and assign it.")
				updateButtons()
			end,
			groupList
		)
		button.Size = UDim2.new(1, 0, 0, 30)
		button.TextXAlignment = Enum.TextXAlignment.Left
		button.TextSize = 12
		button.BackgroundColor3 = district.Name == selectedDistrictName and COLORS.accentDark or COLORS.panelDark
		table.insert(groupButtons, button)
	end
	if #districts == 0 then
		local emptyLabel = makeLabel("No districts found in ReplicatedStorage.Districts.", 24, 1, groupList)
		table.insert(groupButtons, emptyLabel)
	end
end

local function createMarker(group, position, index)
	local marker = create("Part", {
		Name = "Point" .. index,
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(pointRadius, pointRadius, pointRadius),
		Position = position,
		Anchored = true,
		CanCollide = false,
		CanTouch = false,
		CanQuery = true,
		Material = Enum.Material.Neon,
		Color = pointColor,
	}, group.preview)
	marker:SetAttribute("DistrictMapperPoint", index)
	marker:SetAttribute("DistrictMapperGroup", group.id)
	return marker
end

local function createEdge(group, firstIndex, secondIndex)
	local key = math.min(firstIndex, secondIndex) .. ":" .. math.max(firstIndex, secondIndex)
	if group.edges[key] then
		return
	end

	local first = group.points[firstIndex]
	local second = group.points[secondIndex]
	local delta = second.position - first.position
	if delta.Magnitude < 0.001 then
		return
	end

	local edge = create("Part", {
		Name = "Edge_" .. key,
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(delta.Magnitude, 1, 1),
		CFrame = CFrame.lookAt((first.position + second.position) / 2, second.position)
			* CFrame.Angles(0, math.pi / 2, 0),
		Anchored = true,
		CanCollide = false,
		CanTouch = false,
		CanQuery = false,
		Material = Enum.Material.Neon,
		Color = edgeColor,
	}, nil)
	edge:SetAttribute("DistrictMapperEdgeA", firstIndex)
	edge:SetAttribute("DistrictMapperEdgeB", secondIndex)
	edge:SetAttribute("DistrictMapperGroup", group.id)
	edge.Parent = group.preview
	group.edges[key] = edge
	group.adjacency[firstIndex] = group.adjacency[firstIndex] or {}
	group.adjacency[secondIndex] = group.adjacency[secondIndex] or {}
	group.adjacency[firstIndex][secondIndex] = true
	group.adjacency[secondIndex][firstIndex] = true
	if updatePolygon then
		updatePolygon(group)
	end
end

local function removeEdge(group, firstIndex, secondIndex)
	local key = math.min(firstIndex, secondIndex) .. ":" .. math.max(firstIndex, secondIndex)
	local edge = group.edges[key]
	if not edge then
		return
	end
	edge:Destroy()
	group.edges[key] = nil
	group.adjacency[firstIndex][secondIndex] = nil
	group.adjacency[secondIndex][firstIndex] = nil
	if updatePolygon then
		updatePolygon(group)
	end
end

clearSelection = function()
	for _, point in selectedPoints do
		if point.marker and point.marker.Parent then
			point.marker.Color = pointColor
		end
	end
	table.clear(selectedPoints)
	updateButtons()
end

local function addPoint(position)
	if not activeGroup then
		updateStatus("Create or select a group before placing points.")
		return
	end
	recordAction("Add district point", function()
		local index = 0
		for pointIndex in activeGroup.points do
			index = math.max(index, pointIndex)
		end
		index += 1
		while activeGroup.preview:FindFirstChild("Point" .. index) do
			index += 1
		end
		local marker = createMarker(activeGroup, position, index)
		activeGroup.points[index] = { position = position, marker = marker }
		activeGroup.adjacency[index] = {}
		updatePolygon(activeGroup)
		updateStatus("Added point " .. index .. ". Select points in order and link them.")
	end)
end

local function onSelectionChanged()
	local instances = Selection:Get()
	local selectedInstances = {}
	for _, instance in instances do
		selectedInstances[instance] = true
	end

	local ordered = {}
	local added = {}
	table.clear(selectedSections)
	selectedSectionId = nil
	for _, selected in selectedPoints do
		local marker = selected.point.marker
		if selectedInstances[marker] then
			for _, group in groups do
				if group.id == selected.group.id then
					local point = group.points[selected.index]
					if point then
						table.insert(ordered, { group = group, index = selected.index, point = point })
						added[marker] = true
					end
					break
				end
			end
		end
	end

	for _, instance in instances do
		local sectionId = instance:GetAttribute("DistrictMapperFill")
		if sectionId then
			local groupId = instance:GetAttribute("DistrictMapperGroup")
			for _, group in groups do
				if group.id == groupId then
					selectedSections[groupId .. ":" .. sectionId] = { group = group, sectionId = sectionId }
					selectedSectionId = selectedSectionId or sectionId
					activeGroup = group
					break
				end
			end
		end
		if not added[instance] then
			local index = instance:GetAttribute("DistrictMapperPoint")
			local groupId = instance:GetAttribute("DistrictMapperGroup")
			if index and groupId then
				for _, group in groups do
					if group.id == groupId then
						local point = group.points[index]
						if point then
							table.insert(ordered, { group = group, index = index, point = point })
							added[instance] = true
						end
						break
					end
				end
			end
		end
	end

	clearSelection()
	for _, group in groups do
		for _, point in group.points do
			point.marker.Color = pointColor
		end
	end
	for _, selected in ordered do
		table.insert(selectedPoints, selected)
		selected.point.marker.Color = selectedPointColor
	end
	for _, group in groups do
		for _, edge in group.edges do
			edge.Color = selectedInstances[edge] and selectedEdgeColor or edgeColor
		end
	end
	updateButtons()
end

local function getBoundaries(group)
	local boundaries = {}
	local visitedEdges = {}
	local pointIndices = {}
	local boundaryError
	for index in group.points do
		table.insert(pointIndices, index)
	end
	table.sort(pointIndices)
	local neighbors = {}
	for _, index in pointIndices do
		neighbors[index] = {}
		for neighbor in group.adjacency[index] or {} do
			local first = group.points[index].position
			local second = group.points[neighbor].position
			local angle = math.atan2(second.Z - first.Z, second.X - first.X)
			table.insert(neighbors[index], { index = neighbor, angle = angle })
		end
		table.sort(neighbors[index], function(first, second)
			return first.angle < second.angle
		end)
	end
	for _, startIndex in pointIndices do
		for _, neighbor in neighbors[startIndex] do
			local firstEdge = tostring(startIndex) .. ":" .. tostring(neighbor.index)
			if not visitedEdges[firstEdge] then
				local boundary = {}
				local previous = startIndex
				local current = neighbor.index
				local closed = false
				while true do
					local edgeKey = tostring(previous) .. ":" .. tostring(current)
					if visitedEdges[edgeKey] then
						closed = previous == startIndex and current == neighbor.index
						break
					end
					visitedEdges[edgeKey] = true
					table.insert(boundary, previous)
					local adjacent = neighbors[current]
					local reverseIndex
					for index, candidate in adjacent do
						if candidate.index == previous then
							reverseIndex = index
							break
						end
					end
					if not reverseIndex or #adjacent < 2 then
						break
					end
					local nextIndex = (reverseIndex - 2) % #adjacent + 1
					local nextPoint = adjacent[nextIndex].index
					previous = current
					current = nextPoint
					if previous == startIndex and current == neighbor.index then
						closed = true
						break
					end
					if #boundary > #pointIndices * 2 then
						break
					end
				end
				if closed and #boundary >= 3 then
					local seenPoints = {}
					local isUnique = true
					local area = 0
					for index, pointIndex in boundary do
						if seenPoints[pointIndex] then
							isUnique = false
							break
						end
						seenPoints[pointIndex] = true
						local first = group.points[pointIndex].position
						local second = group.points[boundary[index % #boundary + 1]].position
						area += first.X * second.Z - second.X * first.Z
					end
					if isUnique and area > 0.001 then
						table.insert(boundaries, boundary)
					end
				end
			end
		end
	end
	if #boundaries == 0 then
		boundaryError = "Connect points into closed, non-crossing outlines before filling or extruding."
	end
	table.sort(boundaries, function(first, second)
		return first[1] < second[1]
	end)
	return boundaries, boundaryError
end
local function _getBoundary(group)
	local boundaries, err = getBoundaries(group)
	if not boundaries or #boundaries ~= 1 then
		return nil,
			err
				or (
					#boundaries == 0 and "Connect at least three points into a closed loop."
					or "The group contains multiple sections."
				)
	end
	return boundaries[1]
end

local function cross2(a, b, c)
	return (b.X - a.X) * (c.Y - a.Y) - (b.Y - a.Y) * (c.X - a.X)
end

local function pointInTriangle(point, a, b, c)
	local first = cross2(a, b, point)
	local second = cross2(b, c, point)
	local third = cross2(c, a, point)
	return first > 0.0001 and second > 0.0001 and third > 0.0001
end

local function pointOnSegment(point, first, second)
	if math.abs(cross2(first, second, point)) > 0.0001 then
		return false
	end
	return (point - first):Dot(point - second) <= 0.0001
end

local function segmentsIntersect(a, b, c, d)
	local first = cross2(a, b, c)
	local second = cross2(a, b, d)
	local third = cross2(c, d, a)
	local fourth = cross2(c, d, b)
	return ((first > 0.0001 and second < -0.0001) or (first < -0.0001 and second > 0.0001))
		and ((third > 0.0001 and fourth < -0.0001) or (third < -0.0001 and fourth > 0.0001))
end

local function triangulate(points)
	local projected = {}
	local sourceIndices = {}
	for index, point in points do
		local projectedPoint = Vector2.new(point.X, point.Z)
		if #projected == 0 or (projectedPoint - projected[#projected]).Magnitude > 0.001 then
			table.insert(projected, projectedPoint)
			table.insert(sourceIndices, index)
		end
	end
	if #projected > 1 and (projected[1] - projected[#projected]).Magnitude <= 0.001 then
		table.remove(projected, #projected)
		table.remove(sourceIndices, #sourceIndices)
	end
	local changed = true
	while changed and #projected >= 3 do
		changed = false
		for index = 1, #projected do
			local previous = projected[(index - 2) % #projected + 1]
			local current = projected[index]
			local following = projected[index % #projected + 1]
			local first = current - previous
			local second = following - current
			if math.abs(first.X * second.Y - first.Y * second.X) <= 0.001 and first:Dot(second) >= -0.001 then
				table.remove(projected, index)
				table.remove(sourceIndices, index)
				changed = true
				break
			end
		end
	end
	if #projected < 3 then
		return nil, "The outline has fewer than three unique corners."
	end
	local area = 0
	for i, point in projected do
		local nextPoint = projected[i % #projected + 1]
		area += point.X * nextPoint.Y - nextPoint.X * point.Y
	end
	if math.abs(area) < 0.001 then
		return nil, "The outline has no area."
	end
	for first = 1, #projected do
		local firstNext = first % #projected + 1
		for second = first + 1, #projected do
			local secondNext = second % #projected + 1
			if
				firstNext ~= second
				and secondNext ~= first
				and segmentsIntersect(projected[first], projected[firstNext], projected[second], projected[secondNext])
			then
				return nil, "The outline contains intersecting edges."
			end
		end
	end
	local indices = {}
	for i = 1, #projected do
		indices[i] = i
	end
	if area < 0 then
		local reversed = {}
		for i = #indices, 1, -1 do
			table.insert(reversed, indices[i])
		end
		indices = reversed
	end
	local triangles = {}
	local guard = 0
	while #indices > 3 do
		local clipped = false
		for i = 1, #indices do
			local previous = indices[(i - 2) % #indices + 1]
			local current = indices[i]
			local following = indices[i % #indices + 1]
			local a = projected[previous]
			local b = projected[current]
			local c = projected[following]
			if cross2(a, b, c) > 0.0001 then
				local containsPoint = false
				for _, candidate in indices do
					if candidate ~= previous and candidate ~= current and candidate ~= following then
						local point = projected[candidate]
						if pointInTriangle(point, a, b, c) or pointOnSegment(point, a, c) then
							containsPoint = true
							break
						end
					end
				end
				if not containsPoint then
					table.insert(
						triangles,
						{ sourceIndices[previous], sourceIndices[current], sourceIndices[following] }
					)
					table.remove(indices, i)
					clipped = true
					break
				end
			end
		end
		guard += 1
		if not clipped or guard > #projected * #projected then
			return nil, "Could not triangulate this outline. Check its vertex order and shape."
		end
	end
	table.insert(triangles, { sourceIndices[indices[1]], sourceIndices[indices[2]], sourceIndices[indices[3]] })
	return triangles
end

local function createMeshPart(editableMesh, name, parent, center, canCollide, color)
	local meshPart = AssetService:CreateMeshPartAsync(Content.fromObject(editableMesh), {
		CollisionFidelity = Enum.CollisionFidelity.Tunable,
	})
	if not meshPart then
		error("Roblox could not create a MeshPart from the editable mesh.")
	end
	meshPart.Name = name
	meshPart.CFrame = CFrame.new(center)
	meshPart.Anchored = true
	meshPart.CanCollide = canCollide
	meshPart.CollisionPrecision = 1
	meshPart.CanTouch = false
	meshPart.CanQuery = canCollide
	meshPart.Material = Enum.Material.SmoothPlastic
	meshPart.Color = color or groupColor
	meshPart.Parent = parent
	return meshPart
end

local function getSectionId(boundary)
	local indices = table.clone(boundary)
	table.sort(indices)
	return table.concat(indices, ":")
end

local function getSectionDistricts(group)
	local encoded = group.preview:GetAttribute("DistrictMapperAssignments")
	if not encoded then
		return {}
	end
	local ok, assignments = pcall(function()
		return HttpService:JSONDecode(encoded)
	end)
	return if ok and type(assignments) == "table" then assignments else {}
end

local function setSectionDistrict(group, sectionId, districtName)
	local assignments = getSectionDistricts(group)
	assignments[sectionId] = districtName
	group.preview:SetAttribute("DistrictMapperAssignments", HttpService:JSONEncode(assignments))
end

local function getSectionExtrusionHeights(group)
	local encoded = group.preview:GetAttribute("DistrictMapperExtrusionHeights")
	if not encoded then
		return {}
	end
	local ok, heights = pcall(function()
		return HttpService:JSONDecode(encoded)
	end)
	return if ok and type(heights) == "table" then heights else {}
end

local function setSectionExtrusionHeight(group, sectionId, height)
	local heights = getSectionExtrusionHeights(group)
	if height == nil then
		heights[sectionId] = nil
	else
		heights[sectionId] = height
	end
	group.preview:SetAttribute("DistrictMapperExtrusionHeights", HttpService:JSONEncode(heights))
end

local function getDistrictColor(districtName)
	local districtFolder = ReplicatedStorage:FindFirstChild("Districts")
	local districtData = districtFolder and districtName and districtFolder:FindFirstChild(districtName)
	local primaryColor = districtData and districtData:FindFirstChild("PrimaryColor")
	return if primaryColor and primaryColor:IsA("Color3Value") then primaryColor.Value else groupColor
end

local function getFaceColor(group, sectionId, districtName)
	local offsets
	local encoded = group.preview:GetAttribute("DistrictMapperLightnessOffsets")
	if encoded then
		local ok, result = pcall(function()
			return HttpService:JSONDecode(encoded)
		end)
		offsets = if ok and type(result) == "table" then result else {}
	else
		offsets = {}
	end
	local offset = offsets[sectionId]
	if type(offset) ~= "number" then
		offset = Random.new():NextNumber(-0.12, 0.12)
		offsets[sectionId] = offset
		group.preview:SetAttribute("DistrictMapperLightnessOffsets", HttpService:JSONEncode(offsets))
	end
	local color = getDistrictColor(districtName)
	local hue, saturation, value = color:ToHSV()
	return Color3.fromHSV(hue, saturation, math.clamp(value + offset, 0, 1))
end

updatePolygon = function(group, forceRebuild)
	if updatingFills[group.id] and not forceRebuild then
		return
	end
	updatingFills[group.id] = true
	local boundaries, boundaryError = getBoundaries(group)
	local assignments = getSectionDistricts(group)
	group.closed = #boundaries > 0
	local activeSections = {}
	for _, boundary in boundaries do
		local sectionId = getSectionId(boundary)
		activeSections[sectionId] = true
		local districtName = assignments[sectionId]
		local fillColor = getFaceColor(group, sectionId, districtName)
		local positions = {}
		local signatureParts = { sectionId, districtName or "" }
		for _, index in boundary do
			local position = group.points[index].position
			table.insert(positions, position)
			table.insert(signatureParts, string.format("%.4f,%.4f,%.4f", position.X, position.Y, position.Z))
		end
		local fillSignature = table.concat(signatureParts, "|")
		local existingParts = {}
		local existingSignature
		local extrusionHeight = getSectionExtrusionHeights(group)[sectionId]
		for _, instance in group.preview:GetDescendants() do
			if instance:GetAttribute("DistrictMapperFill") == sectionId then
				table.insert(existingParts, instance)
				existingSignature = existingSignature or instance:GetAttribute("DistrictMapperFillSignature")
				extrusionHeight = extrusionHeight or instance:GetAttribute("DistrictMapperExtrusionHeight")
			end
		end
		if extrusionHeight == nil then
			for _, extrusion in outputFolder:GetChildren() do
				if
					extrusion:GetAttribute("DistrictMapperExtrusion")
					and extrusion:GetAttribute("DistrictMapperGroup") == group.id
					and extrusion:GetAttribute("DistrictMapperSection") == sectionId
				then
					extrusionHeight = extrusion:GetAttribute("DistrictMapperTotalHeight")
					break
				end
			end
		end
		if extrusionHeight ~= nil then
			setSectionExtrusionHeight(group, sectionId, extrusionHeight)
		end
		if not forceRebuild and existingSignature == fillSignature and #existingParts > 0 then
			continue
		end
		local triangles, triangulationError = triangulate(positions)
		if not triangles then
			updateStatus(triangulationError)
			continue
		end
		local center = Vector3.zero
		for _, position in positions do
			center += position
		end
		center /= #positions
		local createdMeshes = {}
		local createdParts = {}
		local ok, result = pcall(function()
			local function getBounds(meshTriangles)
				local minimum = Vector3.new(math.huge, math.huge, math.huge)
				local maximum = Vector3.new(-math.huge, -math.huge, -math.huge)
				for _, triangle in meshTriangles do
					for _, position in triangle do
						minimum = Vector3.new(
							math.min(minimum.X, position.X),
							math.min(minimum.Y, position.Y),
							math.min(minimum.Z, position.Z)
						)
						maximum = Vector3.new(
							math.max(maximum.X, position.X),
							math.max(maximum.Y, position.Y),
							math.max(maximum.Z, position.Z)
						)
					end
				end
				return minimum, maximum
			end
			local function clipTriangle(triangle, axis, split, keepBelow)
				local clipped = {}
				for index, current in triangle do
					local previous = triangle[(index - 2) % #triangle + 1]
					local currentValue = current[axis]
					local previousValue = previous[axis]
					local currentInside = keepBelow and currentValue <= split or not keepBelow and currentValue >= split
					local previousInside = keepBelow and previousValue <= split
						or not keepBelow and previousValue >= split
					if currentInside ~= previousInside then
						local alpha = (split - previousValue) / (currentValue - previousValue)
						table.insert(clipped, previous:Lerp(current, alpha))
					end
					if currentInside then
						table.insert(clipped, current)
					end
				end
				local resultTriangles = {}
				for index = 2, #clipped - 1 do
					table.insert(resultTriangles, { clipped[1], clipped[index], clipped[index + 1] })
				end
				return resultTriangles
			end
			local function createFillMesh(meshTriangles)
				local minimum, maximum = getBounds(meshTriangles)
				local meshCenter = (minimum + maximum) / 2
				local editableMesh = AssetService:CreateEditableMesh()
				if not editableMesh then
					error("Roblox could not allocate an EditableMesh.")
				end
				table.insert(createdMeshes, editableMesh)
				for _, triangle in meshTriangles do
					local first = editableMesh:AddVertex(triangle[1] + Vector3.new(0, 0.025, 0) - meshCenter)
					local second = editableMesh:AddVertex(triangle[2] + Vector3.new(0, 0.025, 0) - meshCenter)
					local third = editableMesh:AddVertex(triangle[3] + Vector3.new(0, 0.025, 0) - meshCenter)
					editableMesh:AddTriangle(first, third, second)
				end
				local fillPart =
					createMeshPart(editableMesh, "DistrictFill", group.preview, meshCenter, false, fillColor)
				fillPart:SetAttribute("DistrictMapperFill", sectionId)
				fillPart:SetAttribute("DistrictMapperFillSignature", fillSignature)
				fillPart:SetAttribute("DistrictMapperGroup", group.id)
				fillPart:SetAttribute("DistrictMapperExtrusionHeight", extrusionHeight)
				fillPart.CanQuery = true
				if districtName then
					fillPart:SetAttribute("DistrictMapperDistrict", districtName)
				end
				table.insert(createdParts, fillPart)
			end
			local function splitTriangles(meshTriangles, depth)
				local minimum, maximum = getBounds(meshTriangles)
				local extents = maximum - minimum
				local largestExtent = math.max(extents.X, extents.Y, extents.Z)
				if largestExtent <= MAX_MESH_SIZE then
					createFillMesh(meshTriangles)
					return
				end
				if depth >= 16 then
					error("District fill could not be subdivided below the mesh size limit.")
				end
				local axis = if extents.X >= extents.Y and extents.X >= extents.Z
					then "X"
					elseif extents.Y >= extents.Z then "Y"
					else "Z"
				local split = (minimum[axis] + maximum[axis]) / 2
				local below = {}
				local above = {}
				for _, triangle in meshTriangles do
					for _, clippedTriangle in clipTriangle(triangle, axis, split, true) do
						table.insert(below, clippedTriangle)
					end
					for _, clippedTriangle in clipTriangle(triangle, axis, split, false) do
						table.insert(above, clippedTriangle)
					end
				end
				if #below == 0 or #above == 0 then
					error("District fill subdivision did not reduce the mesh extents.")
				end
				splitTriangles(below, depth + 1)
				splitTriangles(above, depth + 1)
			end
			local meshTriangles = {}
			for _, triangle in triangles do
				table.insert(meshTriangles, {
					positions[triangle[1]],
					positions[triangle[2]],
					positions[triangle[3]],
				})
			end
			splitTriangles(meshTriangles, 0)
		end)
		if not ok then
			for _, fillPart in createdParts do
				fillPart:Destroy()
			end
			for _, editableMesh in createdMeshes do
				editableMesh:Destroy()
			end
			updateStatus("District fill failed: " .. tostring(result))
		else
			for _, existingPart in existingParts do
				existingPart:Destroy()
			end
			local previousMeshes = fillMeshes[group.id] and fillMeshes[group.id][sectionId]
			if previousMeshes then
				for _, editableMesh in previousMeshes do
					editableMesh:Destroy()
				end
			end
			fillMeshes[group.id] = fillMeshes[group.id] or {}
			fillMeshes[group.id][sectionId] = createdMeshes
			if reextrudeSection then
				reextrudeSection(group, sectionId)
			end
		end
	end
	if #boundaries > 0 then
		if forceRebuild then
			for _, extrusion in outputFolder:GetChildren() do
				local sectionId = extrusion:GetAttribute("DistrictMapperSection")
				if
					extrusion:GetAttribute("DistrictMapperExtrusion")
					and extrusion:GetAttribute("DistrictMapperGroup") == group.id
					and not activeSections[sectionId]
				then
					local editableMesh = runtimeExtrusions[extrusion]
					if editableMesh then
						editableMesh:Destroy()
						runtimeExtrusions[extrusion] = nil
					end
					extrusion:Destroy()
				end
			end
		end
		for index = #group.outputs, 1, -1 do
			local output = group.outputs[index]
			if not output.Parent or not activeSections[output:GetAttribute("DistrictMapperSection")] then
				table.remove(group.outputs, index)
			end
		end
		for sectionId, meshes in fillMeshes[group.id] or {} do
			if not activeSections[sectionId] then
				for _, editableMesh in meshes do
					editableMesh:Destroy()
				end
				fillMeshes[group.id][sectionId] = nil
			end
		end
		for _, instance in group.preview:GetDescendants() do
			local sectionId = instance:GetAttribute("DistrictMapperFill")
			if sectionId and not activeSections[sectionId] then
				instance:Destroy()
			end
		end
	end
	if boundaryError and #boundaries == 0 then
		updateStatus(boundaryError)
	end
	updatingFills[group.id] = nil
	updateButtons()
end

local function cleanExtrusionPolygon(positions)
	local cleaned = {}
	for _, position in positions do
		if #cleaned == 0 or (position - cleaned[#cleaned]).Magnitude > 0.001 then
			table.insert(cleaned, position)
		end
	end
	if #cleaned > 1 and (cleaned[1] - cleaned[#cleaned]).Magnitude <= 0.001 then
		table.remove(cleaned, #cleaned)
	end
	local changed = true
	while changed and #cleaned >= 3 do
		changed = false
		for index = 1, #cleaned do
			local previous = cleaned[(index - 2) % #cleaned + 1]
			local current = cleaned[index]
			local following = cleaned[index % #cleaned + 1]
			local first = Vector2.new(current.X - previous.X, current.Z - previous.Z)
			local second = Vector2.new(following.X - current.X, following.Z - current.Z)
			if math.abs(first.X * second.Y - first.Y * second.X) <= 0.001 and first:Dot(second) >= -0.001 then
				table.remove(cleaned, index)
				changed = true
				break
			end
		end
	end
	return cleaned
end

local function buildExtrusionMesh(positions, height)
	positions = cleanExtrusionPolygon(positions)
	if #positions < 3 then
		error("The clipped extrusion outline has fewer than three unique corners.")
	end
	local area = 0
	for i, position in positions do
		local nextPosition = positions[i % #positions + 1]
		area += position.X * nextPosition.Z - nextPosition.X * position.Z
	end
	if math.abs(area) < 0.001 then
		error("The clipped extrusion outline has no area.")
	end
	if area < 0 then
		local reversed = {}
		for i = #positions, 1, -1 do
			table.insert(reversed, positions[i])
		end
		positions = reversed
	end
	local triangles, triangulationError = triangulate(positions)
	if not triangles then
		error(triangulationError)
	end
	local center = Vector3.zero
	for _, position in positions do
		center += position
	end
	center /= #positions
	local editableMesh = AssetService:CreateEditableMesh()
	if not editableMesh then
		error("Roblox could not allocate an EditableMesh.")
	end
	local function addFlatTriangle(firstPosition, secondPosition, thirdPosition)
		local first = editableMesh:AddVertex(firstPosition - center)
		local second = editableMesh:AddVertex(secondPosition - center)
		local third = editableMesh:AddVertex(thirdPosition - center)
		editableMesh:AddTriangle(first, second, third)
	end
	for _, triangle in triangles do
		local first = positions[triangle[1]]
		local second = positions[triangle[2]]
		local third = positions[triangle[3]]
		if height > 0 then
			addFlatTriangle(
				first + Vector3.new(0, height, 0),
				third + Vector3.new(0, height, 0),
				second + Vector3.new(0, height, 0)
			)
			addFlatTriangle(first, second, third)
		else
			addFlatTriangle(
				first + Vector3.new(0, height, 0),
				second + Vector3.new(0, height, 0),
				third + Vector3.new(0, height, 0)
			)
			addFlatTriangle(first, third, second)
		end
	end
	for i, position in positions do
		local nextPosition = positions[i % #positions + 1]
		local bottom = position
		local top = position + Vector3.new(0, height, 0)
		local nextBottom = nextPosition
		local nextTop = nextPosition + Vector3.new(0, height, 0)
		if height > 0 then
			addFlatTriangle(bottom, top, nextTop)
			addFlatTriangle(bottom, nextTop, nextBottom)
		else
			addFlatTriangle(bottom, nextBottom, nextTop)
			addFlatTriangle(bottom, nextTop, top)
		end
	end
	return editableMesh, center, positions
end
local function clipExtrusionPolygon(positions, axis, split, keepBelow)
	local clipped = {}
	for index, current in positions do
		local previous = positions[(index - 2) % #positions + 1]
		local currentValue = current[axis]
		local previousValue = previous[axis]
		local currentInside = keepBelow and currentValue <= split or not keepBelow and currentValue >= split
		local previousInside = keepBelow and previousValue <= split or not keepBelow and previousValue >= split
		if currentInside ~= previousInside then
			local alpha = (split - previousValue) / (currentValue - previousValue)
			table.insert(clipped, previous:Lerp(current, alpha))
		end
		if currentInside then
			table.insert(clipped, current)
		end
	end
	return clipped
end

local function extrudeGroup(group, height, targetSectionId)
	if height == 0 then
		return false, "Extrusion height must be non-zero."
	end
	local sectionId = targetSectionId or selectedSectionId
	if not sectionId then
		return false, "Select a district fill before extruding."
	end
	local boundary
	for _, candidate in getBoundaries(group) do
		if getSectionId(candidate) == sectionId then
			boundary = candidate
			break
		end
	end
	if not boundary then
		return false, "The selected fill no longer exists. Rebuild areas and select it again."
	end
	local positions = {}
	for _, index in boundary do
		table.insert(positions, group.points[index].position)
	end
	local districtName = getSectionDistricts(group)[sectionId]
	if not districtName then
		return false, "Assign a district to the selected fill before extruding."
	end
	local minimum = Vector3.new(math.huge, math.huge, math.huge)
	local maximum = Vector3.new(-math.huge, -math.huge, -math.huge)
	for _, position in positions do
		minimum = Vector3.new(
			math.min(minimum.X, position.X),
			math.min(minimum.Y, position.Y),
			math.min(minimum.Z, position.Z)
		)
		maximum = Vector3.new(
			math.max(maximum.X, position.X),
			math.max(maximum.Y, position.Y),
			math.max(maximum.Z, position.Z)
		)
	end
	local chunkSize = MAX_MESH_SIZE
	local created = {}
	local meshes = {}
	local ok, err = pcall(function()
		local firstX = math.floor(minimum.X / chunkSize)
		local lastX = math.floor(maximum.X / chunkSize)
		local firstZ = math.floor(minimum.Z / chunkSize)
		local lastZ = math.floor(maximum.Z / chunkSize)
		local verticalDirection = if height > 0 then 1 else -1
		local verticalChunkCount = math.ceil(math.abs(height) / chunkSize)
		for x = firstX, lastX do
			for z = firstZ, lastZ do
				local clipped = clipExtrusionPolygon(positions, "X", (x + 1) * chunkSize, true)
				clipped = clipExtrusionPolygon(clipped, "X", x * chunkSize, false)
				if #clipped >= 3 then
					clipped = clipExtrusionPolygon(clipped, "Z", (z + 1) * chunkSize, true)
					clipped = clipExtrusionPolygon(clipped, "Z", z * chunkSize, false)
					if #clipped >= 3 then
						for verticalIndex = 0, verticalChunkCount - 1 do
							local verticalOffset = verticalIndex * chunkSize * verticalDirection
							local chunkHeight = verticalDirection
								* math.min(chunkSize, math.abs(height) - verticalIndex * chunkSize)
							local chunkPositions = {}
							for _, position in clipped do
								table.insert(chunkPositions, position + Vector3.new(0, verticalOffset, 0))
							end
							local editableMesh, center
							editableMesh, center, chunkPositions = buildExtrusionMesh(chunkPositions, chunkHeight)
							local meshPart = createMeshPart(
								editableMesh,
								districtName .. "Build",
								nil,
								center,
								true,
								getDistrictColor(districtName)
							)
							meshPart.Name = districtName .. " " .. tostring(#group.outputs + #created + 1)
							meshPart:SetAttribute("DistrictMapperGroup", group.id)
							meshPart:SetAttribute("DistrictMapperExtrusion", true)
							meshPart:SetAttribute("DistrictMapperSection", sectionId)
							meshPart:SetAttribute("DistrictMapperDistrict", districtName)
							meshPart:SetAttribute(
								"DistrictMapperExportKey",
								group.id .. ":" .. sectionId .. ":" .. x .. ":" .. z .. ":" .. verticalIndex
							)
							meshPart:SetAttribute("DistrictMapperExtrusionId", HttpService:GenerateGUID(false))
							meshPart:SetAttribute("DistrictMapperHeight", chunkHeight)
							meshPart:SetAttribute("DistrictMapperTotalHeight", height)
							local serialized = {}
							for _, position in chunkPositions do
								table.insert(serialized, { position.X, position.Y, position.Z })
							end
							meshPart:SetAttribute(
								"DistrictMapperGeometry",
								HttpService:JSONEncode({ positions = serialized })
							)
							meshPart:SetAttribute(
								"DistrictMapperExportSignature",
								HttpService:JSONEncode({
									positions = serialized,
									height = chunkHeight,
									district = districtName,
								})
							)
							meshPart.Parent = outputFolder
							table.insert(created, meshPart)
							table.insert(meshes, editableMesh)
						end
					end
				end
			end
		end
		if #created == 0 then
			error("The selected fill could not be divided into valid extrusion meshes.")
		end
	end)
	if not ok then
		for _, meshPart in created do
			meshPart:Destroy()
		end
		for _, editableMesh in meshes do
			editableMesh:Destroy()
		end
		return false, "Extrusion failed: " .. tostring(err)
	end
	local createdSet = {}
	for _, meshPart in created do
		createdSet[meshPart] = true
	end
	for _, existing in outputFolder:GetChildren() do
		if
			not createdSet[existing]
			and existing:GetAttribute("DistrictMapperExtrusion")
			and existing:GetAttribute("DistrictMapperGroup") == group.id
			and existing:GetAttribute("DistrictMapperSection") == sectionId
		then
			local editableMesh = runtimeExtrusions[existing]
			if editableMesh then
				editableMesh:Destroy()
				runtimeExtrusions[existing] = nil
			end
			existing:Destroy()
		end
	end
	for index = #group.outputs, 1, -1 do
		local output = group.outputs[index]
		if not output.Parent or output:GetAttribute("DistrictMapperSection") == sectionId then
			table.remove(group.outputs, index)
		end
	end
	for _, meshPart in created do
		table.insert(group.outputs, meshPart)
	end
	for index, editableMesh in meshes do
		runtimeExtrusions[created[index]] = editableMesh
	end
	setSectionExtrusionHeight(group, sectionId, height)
	for _, fillPart in group.preview:GetDescendants() do
		if fillPart:GetAttribute("DistrictMapperFill") == sectionId then
			fillPart:SetAttribute("DistrictMapperExtrusionHeight", height)
		end
	end
	return true
end

reextrudeSection = function(group, sectionId)
	local totalHeight = getSectionExtrusionHeights(group)[sectionId]
	if totalHeight == nil then
		for _, fillPart in group.preview:GetDescendants() do
			if fillPart:GetAttribute("DistrictMapperFill") == sectionId then
				totalHeight = fillPart:GetAttribute("DistrictMapperExtrusionHeight")
				if totalHeight ~= nil then
					break
				end
			end
		end
	end
	if totalHeight == nil then
		for _, extrusion in outputFolder:GetChildren() do
			if
				extrusion:GetAttribute("DistrictMapperExtrusion")
				and extrusion:GetAttribute("DistrictMapperGroup") == group.id
				and extrusion:GetAttribute("DistrictMapperSection") == sectionId
			then
				totalHeight = extrusion:GetAttribute("DistrictMapperTotalHeight")
				break
			end
		end
	end
	if totalHeight ~= nil then
		setSectionExtrusionHeight(group, sectionId, totalHeight)
	end
	if totalHeight and totalHeight ~= 0 then
		extrudeGroup(group, totalHeight, sectionId)
	end
end

local function createGroup()
	if not groups[1] then
		updateStatus("No core graph exists. Create the core graph in the workspace before using the mapper.")
		return
	end
	activeGroup = groups[1]
	clearSelection()
	Selection:Set({ activeGroup.preview })
	updateStatus("Using the core graph.")
	updateButtons()
end

local groupsPanel = makePanel(2)
makeLabel("DISTRICTS", 20, 1, groupsPanel)
groupNameInput = makeInput("core", 2, groupsPanel)
groupNameInput.Visible = false
createGroupButton = makeButton("Select core graph", 3, createGroup, groupsPanel)
groupList = create("ScrollingFrame", {
	Size = UDim2.new(1, 0, 0, 108),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	CanvasSize = UDim2.fromOffset(0, 0),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	ScrollBarThickness = 4,
	ScrollBarImageColor3 = COLORS.sub,
	LayoutOrder = 4,
}, groupsPanel)
create("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, groupList)

local districtPanel = makePanel(3)
makeLabel("FACE DISTRICT", 20, 1, districtPanel)
districtButton = makeButton("Select a district from the list", 2, function()
	updateStatus("Choose a district from the DISTRICTS list.")
end, districtPanel)
assignDistrictButton = makeButton("Assign district to selected fills", 3, function()
	if not next(selectedSections) or not selectedDistrictName then
		return
	end
	recordAction("Assign district to faces", function()
		local assigned = 0
		for _, selected in selectedSections do
			local group = selected.group
			local sectionId = selected.sectionId
			setSectionDistrict(group, sectionId, selectedDistrictName)
			local fillColor = getFaceColor(group, sectionId, selectedDistrictName)
			local updated = false
			for _, instance in group.preview:GetDescendants() do
				if instance:GetAttribute("DistrictMapperFill") == sectionId then
					instance:SetAttribute("DistrictMapperDistrict", selectedDistrictName)
					if instance:IsA("BasePart") then
						instance.Color = fillColor
					end
					updated = true
				end
			end
			for _, extrusion in outputFolder:GetChildren() do
				if
					extrusion:GetAttribute("DistrictMapperGroup") == group.id
					and extrusion:GetAttribute("DistrictMapperSection") == sectionId
				then
					extrusion:SetAttribute("DistrictMapperDistrict", selectedDistrictName)
					extrusion.Color = fillColor
				end
			end
			if updated then
				assigned += 1
			end
		end
		updateStatus(
			"Assigned "
				.. selectedDistrictName
				.. " to "
				.. assigned
				.. " selected face"
				.. (assigned == 1 and "" or "s")
				.. "."
		)
		updateButtons()
	end)
end, districtPanel)

local pointPanel = makePanel(4)
makeLabel("OUTLINE", 20, 1, pointPanel)
pointButton = makeButton("Add points", 2, function()
	if not activeGroup then
		createGroup()
	end
	placingPoints = not placingPoints
	plugin:Activate(true)
	updateStatus(
		placingPoints and "Click map surfaces in the 3D viewport to add vertices."
			or "Point placement paused. Select vertices to link them."
	)
	updateButtons()
end, pointPanel)
linkButton = makeButton("Link selected points (0)", 3, function()
	if #selectedPoints < 2 then
		updateStatus("Select at least two points in connection order.")
		return
	end
	local group = selectedPoints[1].group
	if not group or not group.preview or not group.preview.Parent then
		updateStatus("The selected core graph is no longer available.")
		return
	end
	for _, selected in selectedPoints do
		if
			selected.group ~= group
			or not group.points[selected.index]
			or group.points[selected.index].marker ~= selected.point.marker
		then
			updateStatus("Select points from the same core graph.")
			return
		end
	end
	activeGroup = group
	local pairCount = #selectedPoints == 2 and 1 or #selectedPoints
	local allConnected = true
	for i = 1, pairCount do
		local first = selectedPoints[i].index
		local second = selectedPoints[i % #selectedPoints + 1].index
		local key = math.min(first, second) .. ":" .. math.max(first, second)
		if not group.edges[key] then
			allConnected = false
			break
		end
	end
	recordAction(allConnected and "Unlink district points" or "Link district points", function()
		local changed = 0
		for i = 1, pairCount do
			local first = selectedPoints[i].index
			local second = selectedPoints[i % #selectedPoints + 1].index
			if allConnected then
				removeEdge(group, first, second)
			else
				createEdge(group, first, second)
				local key = math.min(first, second) .. ":" .. math.max(first, second)
				if group.edges[key] then
					changed += 1
				end
			end
		end
		clearSelection()
		updateStatus(allConnected and "Removed " .. changed .. " connections." or "Created " .. changed .. " edges.")
	end)
end, pointPanel)
makeButton("Clear point selection", 4, clearSelection, pointPanel)
makeButton("Subdivide selected edge", 5, function()
	if #selectedPoints ~= 2 then
		updateStatus("Select exactly two connected points to subdivide their edge.")
		return
	end
	local first = selectedPoints[1]
	local second = selectedPoints[2]
	local group = first.group
	if
		not group
		or second.group ~= group
		or not group.edges[math.min(first.index, second.index) .. ":" .. math.max(first.index, second.index)]
	then
		updateStatus("Select the two endpoints of an existing edge in the same graph.")
		return
	end
	local firstPoint = group.points[first.index]
	local secondPoint = group.points[second.index]
	if not firstPoint or not secondPoint then
		updateStatus("The selected edge no longer exists.")
		return
	end
	recordAction("Subdivide district edge", function()
		local previousBoundaries = getBoundaries(group)
		local assignments = getSectionDistricts(group)
		local offsetsEncoded = group.preview:GetAttribute("DistrictMapperLightnessOffsets")
		local offsets = {}
		if offsetsEncoded then
			local ok, decoded = pcall(function()
				return HttpService:JSONDecode(offsetsEncoded)
			end)
			if ok and type(decoded) == "table" then
				offsets = decoded
			end
		end
		local inheritedFaces = {}
		for _, boundary in previousBoundaries do
			local containsEdge = false
			for boundaryIndex, pointIndex in boundary do
				local nextIndex = boundary[boundaryIndex % #boundary + 1]
				if
					(pointIndex == first.index and nextIndex == second.index)
					or (pointIndex == second.index and nextIndex == first.index)
				then
					containsEdge = true
					break
				end
			end
			if containsEdge then
				local sectionId = getSectionId(boundary)
				local height = getSectionExtrusionHeights(group)[sectionId]
				for _, fillPart in group.preview:GetDescendants() do
					if fillPart:GetAttribute("DistrictMapperFill") == sectionId then
						height = height or fillPart:GetAttribute("DistrictMapperExtrusionHeight")
						if height ~= nil then
							break
						end
					end
				end
				if height == nil then
					for _, extrusion in outputFolder:GetChildren() do
						if
							extrusion:GetAttribute("DistrictMapperExtrusion")
							and extrusion:GetAttribute("DistrictMapperGroup") == group.id
							and extrusion:GetAttribute("DistrictMapperSection") == sectionId
						then
							height = extrusion:GetAttribute("DistrictMapperTotalHeight")
							break
						end
					end
				end
				if height ~= nil then
					setSectionExtrusionHeight(group, sectionId, height)
				end
				table.insert(inheritedFaces, {
					sectionId = sectionId,
					districtName = assignments[sectionId],
					lightnessOffset = offsets[sectionId],
					height = height,
				})
			end
		end
		local midpoint = (firstPoint.position + secondPoint.position) / 2
		local index = 0
		for pointIndex in group.points do
			index = math.max(index, pointIndex)
		end
		index += 1
		while group.preview:FindFirstChild("Point" .. index) do
			index += 1
		end
		local edgeKey = math.min(first.index, second.index) .. ":" .. math.max(first.index, second.index)
		group.edges[edgeKey]:Destroy()
		group.edges[edgeKey] = nil
		group.adjacency[first.index][second.index] = nil
		group.adjacency[second.index][first.index] = nil
		local marker = createMarker(group, midpoint, index)
		group.points[index] = { position = midpoint, marker = marker }
		group.adjacency[index] = {}
		createEdge(group, first.index, index)
		createEdge(group, index, second.index)
		local newBoundaries = getBoundaries(group)
		assignments = getSectionDistricts(group)
		for _, face in inheritedFaces do
			local matchingBoundary
			for _, boundary in newBoundaries do
				local containsMidpoint = false
				local containsAllOriginalPoints = true
				local boundaryPoints = {}
				for _, pointIndex in boundary do
					boundaryPoints[pointIndex] = true
					containsMidpoint = containsMidpoint or pointIndex == index
				end
				for _, originalIndex in string.gmatch(face.sectionId, "%d+") do
					if not boundaryPoints[tonumber(originalIndex)] then
						containsAllOriginalPoints = false
						break
					end
				end
				if containsMidpoint and containsAllOriginalPoints then
					matchingBoundary = boundary
					break
				end
			end
			if matchingBoundary then
				local newSectionId = getSectionId(matchingBoundary)
				assignments[newSectionId] = face.districtName
				assignments[face.sectionId] = nil
				if face.height ~= nil then
					setSectionExtrusionHeight(group, newSectionId, face.height)
				end
				setSectionExtrusionHeight(group, face.sectionId, nil)
				if face.lightnessOffset ~= nil then
					offsets[newSectionId] = face.lightnessOffset
				end
				offsets[face.sectionId] = nil
				if face.height ~= nil then
					for _, fillPart in group.preview:GetDescendants() do
						if fillPart:GetAttribute("DistrictMapperFill") == newSectionId then
							fillPart:SetAttribute("DistrictMapperExtrusionHeight", face.height)
						end
					end
				end
				for _, extrusion in outputFolder:GetChildren() do
					if
						extrusion:GetAttribute("DistrictMapperExtrusion")
						and extrusion:GetAttribute("DistrictMapperGroup") == group.id
						and extrusion:GetAttribute("DistrictMapperSection") == face.sectionId
					then
						local editableMesh = runtimeExtrusions[extrusion]
						if editableMesh then
							editableMesh:Destroy()
							runtimeExtrusions[extrusion] = nil
						end
						extrusion:Destroy()
					end
				end
			end
		end
		group.preview:SetAttribute("DistrictMapperAssignments", HttpService:JSONEncode(assignments))
		group.preview:SetAttribute("DistrictMapperLightnessOffsets", HttpService:JSONEncode(offsets))
		updatePolygon(group)
		Selection:Set({ marker })
		updateStatus("Subdivided edge with point " .. index .. " and inherited adjacent face settings.")
	end)
end, pointPanel)
makeButton("Rebuild all", 6, function()
	recordAction("Rebuild district areas", function()
		refreshGroups()
		for _, group in groups do
			updatePolygon(group, true)
		end
		updateStatus("Rebuilt all district faces and their existing extrusions from the current graph.")
	end)
end, pointPanel)

local extrusionPanel = makePanel(5)
makeLabel("EXTRUSION", 20, 1, extrusionPanel)
makeLabel("Height (studs)", 18, 2, extrusionPanel)
heightInput = makeInput("100", 3, extrusionPanel)
extrudeButton = makeButton("Extrude selected districts", 4, function()
	if not next(selectedSections) then
		updateStatus("Select at least one district fill before extruding.")
		return
	end
	local height = tonumber(heightInput.Text)
	if not height then
		updateStatus("Enter a numeric extrusion height.")
		return
	end
	recordAction("Extrude selected districts", function()
		local extruded = 0
		local failures = {}
		for _, selected in selectedSections do
			local ok, err = extrudeGroup(selected.group, height, selected.sectionId)
			if ok then
				extruded += 1
			else
				table.insert(failures, selected.sectionId .. ": " .. tostring(err))
			end
		end
		if #failures > 0 then
			updateStatus(
				"Extruded " .. extruded .. " faces; " .. #failures .. " failed: " .. table.concat(failures, " | ")
			)
		else
			updateStatus("Extruded " .. extruded .. " selected face" .. (extruded == 1 and "" or "s") .. ".")
		end
	end)
end, extrusionPanel)
exportButton = makeButton("Export extruded districts", 5, function()
	if exportButton:GetAttribute("Exporting") then
		return
	end
	local pending = {}
	local exportedByKey = {}
	local legacyBySection = {}
	local expectedExports = {}
	local unassigned = 0
	for _, extrusion in outputFolder:GetChildren() do
		if extrusion:IsA("MeshPart") and extrusion:GetAttribute("DistrictMapperExtrusion") then
			local districtName = extrusion:GetAttribute("DistrictMapperDistrict")
			local districtData = ReplicatedStorage:FindFirstChild("Districts")
			if districtName and districtData and districtData:FindFirstChild(districtName) then
				local exportKey = extrusion:GetAttribute("DistrictMapperExportKey")
				if exportKey then
					expectedExports[exportKey] = {
						signature = extrusion:GetAttribute("DistrictMapperExportSignature"),
						district = districtName,
					}
				end
			end
		end
	end
	local function cleanExportFolders()
		for _, districtFolder in exportFolder:GetChildren() do
			local zoneFolder = districtFolder:FindFirstChild("Zone")
			if zoneFolder and zoneFolder:IsA("Folder") then
				for _, instance in zoneFolder:GetChildren() do
					if instance:IsA("BasePart") then
						local exportKey = instance:GetAttribute("DistrictMapperExportKey")
						local expected = exportKey and expectedExports[exportKey]
						local valid = instance:IsA("MeshPart")
							and expected ~= nil
							and instance:GetAttribute("DistrictMapperExportSignature") == expected.signature
							and instance:GetAttribute("DistrictMapperDistrict") == expected.district
							and districtFolder.Name == expected.district
						if not valid then
							instance:Destroy()
						end
					end
				end
			end
		end
	end
	for _, exportedMesh in exportFolder:GetDescendants() do
		local exportKey = exportedMesh:GetAttribute("DistrictMapperExportKey")
		if exportKey then
			exportedByKey[exportKey] = exportedMesh
		elseif
			exportedMesh:GetAttribute("DistrictMapperGroup") and exportedMesh:GetAttribute("DistrictMapperSection")
		then
			local sectionKey = exportedMesh:GetAttribute("DistrictMapperGroup")
				.. ":"
				.. exportedMesh:GetAttribute("DistrictMapperSection")
			legacyBySection[sectionKey] = legacyBySection[sectionKey] or {}
			table.insert(legacyBySection[sectionKey], exportedMesh)
		end
	end
	for _, extrusion in outputFolder:GetChildren() do
		if extrusion:IsA("MeshPart") and extrusion:GetAttribute("DistrictMapperExtrusion") then
			local districtName = extrusion:GetAttribute("DistrictMapperDistrict")
			if
				not districtName
				or not ReplicatedStorage:FindFirstChild("Districts")
				or not ReplicatedStorage.Districts:FindFirstChild(districtName)
			then
				unassigned += 1
			else
				local exportKey = extrusion:GetAttribute("DistrictMapperExportKey")
				local sectionKey = extrusion:GetAttribute("DistrictMapperGroup")
					.. ":"
					.. extrusion:GetAttribute("DistrictMapperSection")
				local existingExport = exportKey and exportedByKey[exportKey]
				if not existingExport and legacyBySection[sectionKey] and #legacyBySection[sectionKey] > 0 then
					existingExport = table.remove(legacyBySection[sectionKey], 1)
				end
				local signature = extrusion:GetAttribute("DistrictMapperExportSignature")
				if not existingExport or existingExport:GetAttribute("DistrictMapperExportSignature") ~= signature then
					table.insert(pending, {
						extrusion = extrusion,
						existingExport = existingExport,
					})
				end
			end
		end
	end
	if #pending == 0 then
		cleanExportFolders()
		updateStatus(
			"Nothing changed to export. Existing zone folders were cleaned. "
				.. unassigned
				.. " extrusion"
				.. (unassigned == 1 and " has" or "s have")
				.. " no valid district assignment."
		)
		return
	end
	exportButton:SetAttribute("Exporting", true)
	exportButton.Text = "Exporting 0/" .. #pending .. "..."
	exportButton.Active = false
	exportButton.AutoButtonColor = false
	updateStatus("Exporting " .. #pending .. " district mesh" .. (#pending == 1 and "" or "es") .. "...")
	task.spawn(function()
		local exported = 0
		local failed = 0
		for index, exportItem in pending do
			local extrusion = exportItem.extrusion
			local existingExport = exportItem.existingExport
			local extrusionId = extrusion:GetAttribute("DistrictMapperExtrusionId")
			local groupId = extrusion:GetAttribute("DistrictMapperGroup")
			local group
			for _, candidate in groups do
				if candidate.id == groupId then
					group = candidate
					break
				end
			end
			local ok, err = pcall(function()
				local geometry = HttpService:JSONDecode(extrusion:GetAttribute("DistrictMapperGeometry") or "{}")
				local positions = {}
				for _, position in geometry.positions or {} do
					table.insert(positions, Vector3.new(position[1], position[2], position[3]))
				end
				if #positions < 3 then
					error("Missing extrusion geometry.")
				end
				local editableMesh =
					buildExtrusionMesh(positions, extrusion:GetAttribute("DistrictMapperHeight") or extrusion.Size.Y)
				local uploadOk, uploadResult, assetId = pcall(function()
					return AssetService:CreateAssetAsync(editableMesh, Enum.AssetType.Mesh, {
						Name = extrusion.Name,
						Description = "District mesh exported from districtMapper",
					})
				end)
				editableMesh:Destroy()
				if not uploadOk or uploadResult ~= Enum.CreateAssetResult.Success or not assetId then
					error(tostring(uploadOk and assetId or uploadResult))
				end
				local assetPart = AssetService:CreateMeshPartAsync(Content.fromAssetId(assetId), {
					CollisionFidelity = Enum.CollisionFidelity.Tunable,
				})
				assetPart.Name = extrusion.Name
				assetPart.CFrame = extrusion.CFrame
				assetPart.Anchored = true
				assetPart.CanCollide = true
				assetPart.CanTouch = false
				assetPart.CanQuery = true
				assetPart.CollisionPrecision = 1
				assetPart.Material = extrusion.Material
				assetPart.Color = extrusion.Color
				assetPart:SetAttribute("DistrictMapperExportSource", extrusionId)
				assetPart:SetAttribute("DistrictMapperExportKey", extrusion:GetAttribute("DistrictMapperExportKey"))
				assetPart:SetAttribute(
					"DistrictMapperExportSignature",
					extrusion:GetAttribute("DistrictMapperExportSignature")
				)
				assetPart:SetAttribute("DistrictMapperAssetId", assetId)
				local districtName = group
						and getSectionDistricts(group)[extrusion:GetAttribute("DistrictMapperSection")]
					or extrusion:GetAttribute("DistrictMapperDistrict")
				local districtData = ReplicatedStorage:FindFirstChild("Districts")
				local district = districtData and districtData:FindFirstChild(districtName)
				if not district then
					error("The extrusion has no valid district assignment.")
				end
				assetPart.Color = getDistrictColor(districtName)
				assetPart:SetAttribute("DistrictMapperGroup", groupId)
				assetPart:SetAttribute("DistrictMapperSection", extrusion:GetAttribute("DistrictMapperSection"))
				assetPart:SetAttribute("DistrictMapperDistrict", districtName)
				local districtFolder = exportFolder:FindFirstChild(districtName)
				if not districtFolder then
					districtFolder = create("Folder", { Name = districtName }, exportFolder)
				end
				local zoneFolder = districtFolder:FindFirstChild("Zone")
				if not zoneFolder then
					zoneFolder = create("Folder", { Name = "Zone" }, districtFolder)
				end
				assetPart.Parent = zoneFolder
				if existingExport and existingExport.Parent then
					existingExport:Destroy()
				end
			end)
			if ok then
				exported += 1
			else
				failed += 1
				updateStatus(
					"Exporting " .. index .. "/" .. #pending .. ": " .. extrusion.Name .. " failed: " .. tostring(err)
				)
			end
			exportButton.Text = "Exporting " .. index .. "/" .. #pending .. "..."
			updateStatus(
				"Exporting district meshes: "
					.. index
					.. "/"
					.. #pending
					.. " processed, "
					.. exported
					.. " uploaded, "
					.. failed
					.. " failed."
			)
			task.wait()
		end
		cleanExportFolders()
		exportButton:SetAttribute("Exporting", false)
		exportButton.Text = "Export extruded districts"
		exportButton.Active = true
		exportButton.AutoButtonColor = true
		updateStatus(
			"Export complete: "
				.. exported
				.. " uploaded, "
				.. failed
				.. " failed, "
				.. unassigned
				.. " without a valid district assignment. Output: "
				.. exportFolder:GetFullName()
				.. "."
		)
	end)
end, extrusionPanel)

statusLabel.Text =
	"Waiting for ServerStorage ObjectValues: DistrictMapperPreview, DistrictMapGenerated, and Districts. Fill all three Value properties to start."

local folderReferences = {
	{
		name = "DistrictMapperPreview",
		assign = function(value)
			previewFolder = value
		end,
	},
	{
		name = "DistrictMapGenerated",
		assign = function(value)
			outputFolder = value
		end,
	},
	{
		name = "Districts",
		assign = function(value)
			exportFolder = value
		end,
	},
}

while true do
	local ready = true
	for _, reference in folderReferences do
		local objectValue = ServerStorage:FindFirstChild(reference.name)
		local value = objectValue and objectValue:IsA("ObjectValue") and objectValue.Value
		if not value then
			ready = false
			break
		end
		reference.assign(value)
	end
	if ready then
		break
	end
	task.wait(0.25)
end

statusLabel.Text = "Connected to all three target folders. District mapper is ready."

scheduleGroupRefresh = function(groupId)
	local revision = (pendingGroupRefreshes[groupId] or 0) + 1
	pendingGroupRefreshes[groupId] = revision
	task.delay(0.5, function()
		if pendingGroupRefreshes[groupId] ~= revision then
			return
		end
		pendingGroupRefreshes[groupId] = nil
		refreshGroups()
		for _, group in groups do
			if group.id == groupId then
				updatePolygon(group)
				break
			end
		end
	end)
end

refreshGroups = function()
	local previousActiveId = activeGroup and activeGroup.id
	local refreshed = {}
	for _, folder in previewFolder:GetChildren() do
		local groupId = folder:GetAttribute("DistrictMapperGroup")
		if folder:IsA("Folder") and groupId then
			if not observedGroupFolders[folder] then
				local function isGraphInstance(instance)
					return instance:GetAttribute("DistrictMapperPoint") ~= nil
						or instance:GetAttribute("DistrictMapperEdgeA") ~= nil
						or instance:GetAttribute("DistrictMapperEdgeB") ~= nil
				end
				observedGroupFolders[folder] = {
					connect(folder.ChildAdded, function(instance)
						task.defer(function()
							if isGraphInstance(instance) then
								scheduleGroupRefresh(groupId)
							end
						end)
					end),
					connect(folder.ChildRemoved, function(instance)
						if isGraphInstance(instance) then
							scheduleGroupRefresh(groupId)
						end
					end),
				}
			end
			local group = {
				id = groupId,
				name = folder.Name,
				points = {},
				edges = {},
				adjacency = {},
				closed = false,
				outputs = {},
				preview = folder,
			}
			for _, instance in folder:GetChildren() do
				local pointIndex = instance:GetAttribute("DistrictMapperPoint")
				local firstIndex = instance:GetAttribute("DistrictMapperEdgeA")
				local secondIndex = instance:GetAttribute("DistrictMapperEdgeB")
				if (pointIndex or firstIndex or secondIndex) and not observedAttributes[instance] then
					observedAttributes[instance] = connect(instance.AttributeChanged, function(attribute)
						if
							attribute == "DistrictMapperPoint"
							or attribute == "DistrictMapperEdgeA"
							or attribute == "DistrictMapperEdgeB"
							or attribute == "DistrictMapperSharedVertex"
							or attribute == "DistrictMapperGroup"
						then
							scheduleGroupRefresh(groupId)
						end
					end)
				end
				if pointIndex and instance:IsA("BasePart") then
					group.points[pointIndex] = { position = instance.Position, marker = instance }
					group.adjacency[pointIndex] = {}
					if not observedMarkers[instance] then
						observedMarkers[instance] = instance:GetPropertyChangedSignal("Position"):Connect(function()
							local currentGroup
							for _, candidate in groups do
								if candidate.id == groupId then
									currentGroup = candidate
									break
								end
							end
							if not currentGroup then
								return
							end
							local point = currentGroup.points[pointIndex]
							if not point then
								return
							end
							point.position = instance.Position
							local sharedVertexId = instance:GetAttribute("DistrictMapperSharedVertex")
							if sharedVertexId then
								for _, sharedGroup in groups do
									for _, sharedPoint in sharedGroup.points do
										if
											sharedPoint.marker ~= instance
											and sharedPoint.marker:GetAttribute("DistrictMapperSharedVertex") == sharedVertexId
											and (sharedPoint.marker.Position - instance.Position).Magnitude > 0.001
										then
											sharedPoint.marker.Position = instance.Position
										end
									end
								end
							end
							for neighborIndex in currentGroup.adjacency[pointIndex] or {} do
								local edge = currentGroup.edges[math.min(pointIndex, neighborIndex) .. ":" .. math.max(
									pointIndex,
									neighborIndex
								)]
								local neighbor = currentGroup.points[neighborIndex]
								if edge and neighbor then
									local delta = neighbor.position - point.position
									if delta.Magnitude > 0.001 then
										edge.Size = Vector3.new(delta.Magnitude, 1, 1)
										edge.CFrame = CFrame.lookAt(
											(point.position + neighbor.position) / 2,
											neighbor.position
										) * CFrame.Angles(0, math.pi / 2, 0)
									end
								end
							end
							if not pendingPolygonUpdates[groupId] then
								pendingPolygonUpdates[groupId] = true
								task.delay(0.12, function()
									pendingPolygonUpdates[groupId] = nil
									for _, candidate in groups do
										if candidate.id == groupId then
											updatePolygon(candidate)
											break
										end
									end
								end)
							end
							updateButtons()
						end)
					end
				end
			end
			for _, instance in folder:GetChildren() do
				local firstIndex = instance:GetAttribute("DistrictMapperEdgeA")
				local secondIndex = instance:GetAttribute("DistrictMapperEdgeB")
				if firstIndex and secondIndex and group.points[firstIndex] and group.points[secondIndex] then
					local key = math.min(firstIndex, secondIndex) .. ":" .. math.max(firstIndex, secondIndex)
					group.edges[key] = instance
					group.adjacency[firstIndex][secondIndex] = true
					group.adjacency[secondIndex][firstIndex] = true
				end
			end
			local boundaries = getBoundaries(group)
			group.closed = #boundaries > 0
			for _, output in outputFolder:GetChildren() do
				if
					output:GetAttribute("DistrictMapperGroup") == group.id
					and output:GetAttribute("DistrictMapperExtrusion")
				then
					table.insert(group.outputs, output)
				end
			end
			table.insert(refreshed, group)
		end
	end
	for marker, connection in observedMarkers do
		if not marker:IsDescendantOf(previewFolder) then
			connection:Disconnect()
			observedMarkers[marker] = nil
		end
	end
	for instance, connection in observedAttributes do
		if not instance:IsDescendantOf(previewFolder) then
			connection:Disconnect()
			observedAttributes[instance] = nil
		end
	end
	for folder, folderConnections in observedGroupFolders do
		if not folder:IsDescendantOf(previewFolder) then
			for _, connection in folderConnections do
				connection:Disconnect()
			end
			observedGroupFolders[folder] = nil
		end
	end
	groups = refreshed
	activeGroup = nil
	for _, group in groups do
		if group.id == previousActiveId then
			activeGroup = group
			break
		end
	end
	activeGroup = activeGroup or groups[1]
	onSelectionChanged()
end

local function onMouseDown()
	if not widget.Enabled then
		return
	end
	local target = mouse.Target
	if
		placingPoints
		and target
		and not target:IsDescendantOf(previewFolder)
		and not target:IsDescendantOf(outputFolder)
		and not target:IsDescendantOf(exportFolder)
	then
		addPoint(mouse.Hit.Position)
	end
end

connect(previewFolder.ChildAdded, function(instance)
	if instance:IsA("Folder") and instance:GetAttribute("DistrictMapperGroup") then
		task.defer(refreshGroups)
	end
end)
connect(previewFolder.ChildRemoved, function(instance)
	if instance:IsA("Folder") and instance:GetAttribute("DistrictMapperGroup") then
		task.defer(refreshGroups)
	end
end)

connect(mouse.Button1Down, onMouseDown)
connect(Selection.SelectionChanged, onSelectionChanged)

local function reloadButtons()
	toolbar = shared.paTools
	toggleButton =
		toolbar.addButton("districtMapper", "Create and extrude district outlines", "rbxassetid://4458901886")
	toolbar.setButtonHandler("districtMapper", function()
		widget.Enabled = not widget.Enabled
		toggleButton:SetActive(widget.Enabled)
	end)
end

local toolbarCallbacks = shared.paToolbarCallbacks
if not toolbarCallbacks then
	toolbarCallbacks = {}
	shared.paToolbarCallbacks = toolbarCallbacks
end

toolbarCallbacks.districtMapper = reloadButtons
reloadButtons()

connect(widget:GetPropertyChangedSignal("Enabled"), function()
	toggleButton:SetActive(widget.Enabled)
	if widget.Enabled then
		plugin:Activate(true)
	else
		placingPoints = false
		plugin:Deactivate()
		updateButtons()
	end
end)

connect(plugin.Deactivation, function()
	if placingPoints then
		placingPoints = false
		updateButtons()
		updateStatus("Point placement paused because another Studio tool was activated.")
	end
end)

connect(plugin.Unloading, function()
	toolbarCallbacks.districtMapper = nil
	toolbar.removeButtonHandler("districtMapper")
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
	for marker, connection in observedMarkers do
		connection:Disconnect()
		observedMarkers[marker] = nil
	end
	plugin:Deactivate()
end)

refreshGroups()
for _, group in groups do
	updatePolygon(group, true)
end
updateButtons()
