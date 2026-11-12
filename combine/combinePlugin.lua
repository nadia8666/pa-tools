local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local Selection = game:GetService("Selection")
local SerializationService = game:GetService("SerializationService")
local EncodingService = game:GetService("EncodingService")
local MaterialService = game:GetService("MaterialService")
local AssetService = game:GetService("AssetService")
local PhysicsService = game:GetService("PhysicsService")
local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

if not RunService:IsEdit() then
	return
end

local workerUrl = "ws://127.0.0.1:34873"
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
local toggleButton =
	toolbar.addButton("Combine", "Combine selected geometry and bake its appearance", "rbxassetid://4458901886")

local widget = plugin:CreateDockWidgetPluginGuiAsync(
	"PACombine",
	DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Right, true, false, 340, 520, 280, 480)
)
widget.Title = "Combine"

local colors = {
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

local function corner(parent, radius)
	local value = Instance.new("UICorner")
	value.CornerRadius = UDim.new(0, radius)
	value.Parent = parent
end

local function stroke(parent, color, transparency)
	local value = Instance.new("UIStroke")
	value.Color = color
	value.Transparency = transparency
	value.Thickness = 1
	value.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	value.Parent = parent
end

local function pad(parent, amount)
	local value = Instance.new("UIPadding")
	value.PaddingTop = UDim.new(0, amount)
	value.PaddingBottom = UDim.new(0, amount)
	value.PaddingLeft = UDim.new(0, amount)
	value.PaddingRight = UDim.new(0, amount)
	value.Parent = parent
end

local function stack(parent, spacing)
	local value = Instance.new("UIListLayout")
	value.SortOrder = Enum.SortOrder.LayoutOrder
	value.Padding = UDim.new(0, spacing)
	value.Parent = parent
end

local root = Instance.new("Frame")
root.Size = UDim2.fromScale(1, 1)
root.BackgroundColor3 = Color3.new(0.098039, 0.101961, 0.105882)
root.BorderSizePixel = 0
root.Parent = widget

local page = Instance.new("ScrollingFrame")
page.Size = UDim2.fromScale(1, 1)
page.BackgroundTransparency = 1
page.BorderSizePixel = 0
page.ScrollBarThickness = 4
page.ScrollBarImageColor3 = colors.stroke
page.AutomaticCanvasSize = Enum.AutomaticSize.Y
page.CanvasSize = UDim2.new()
page.Parent = root
pad(page, 10)
stack(page, 10)

local function makeCard(order)
	local card = Instance.new("Frame")
	card.Size = UDim2.new(1, 0, 0, 0)
	card.AutomaticSize = Enum.AutomaticSize.Y
	card.BackgroundColor3 = Color3.new(0.086275, 0.090196, 0.105882)
	card.BackgroundTransparency = 0.2
	card.BorderSizePixel = 0
	card.LayoutOrder = order
	card.Parent = page
	corner(card, 10)
	stroke(card, colors.stroke, 0.5)
	pad(card, 10)
	stack(card, 6)
	return card
end

local header = makeCard(1)
local operations = makeCard(2)
local settings = makeCard(3)

local function createLabel(text, height, color, order, parent)
	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 0, height)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.Gotham
	label.TextSize = 12
	label.TextColor3 = color
	label.TextWrapped = true
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.Text = text
	label.LayoutOrder = order
	label.Parent = parent
	return label
end

local title = createLabel("Combine", 22, colors.text, 1, header)
title.Font = Enum.Font.GothamBold
title.TextSize = 18

local subtitle = createLabel("Bake selected geometry into optimized MeshParts.", 18, colors.sub, 2, header)

local status = createLabel("Worker disconnected. Start the Combine worker to continue.", 0, colors.sub, 1, operations)
status.AutomaticSize = Enum.AutomaticSize.Y

local errorDetails = Instance.new("TextBox")
errorDetails.Size = UDim2.new(1, 0, 0, 0)
errorDetails.AutomaticSize = Enum.AutomaticSize.Y
errorDetails.BackgroundColor3 = colors.panelDark
errorDetails.BorderSizePixel = 0
errorDetails.Font = Enum.Font.Code
errorDetails.TextSize = 11
errorDetails.TextColor3 = colors.bad
errorDetails.TextWrapped = true
errorDetails.TextXAlignment = Enum.TextXAlignment.Left
errorDetails.TextYAlignment = Enum.TextYAlignment.Top
errorDetails.ClearTextOnFocus = false
errorDetails.MultiLine = true
errorDetails.TextEditable = false
errorDetails.Visible = false
errorDetails.LayoutOrder = 2
errorDetails.Parent = operations
pad(errorDetails, 8)
corner(errorDetails, 6)
stroke(errorDetails, colors.stroke, 0.5)

local selectionStats = createLabel("Selection: 0 instances · 0 geometry parts", 18, colors.text, 2, operations)

local progress = Instance.new("Frame")
progress.Size = UDim2.new(1, 0, 0, 6)
progress.BackgroundColor3 = colors.panelDark
progress.BorderSizePixel = 0
progress.LayoutOrder = 3
progress.Parent = operations
corner(progress, 3)

local progressFill = Instance.new("Frame")
progressFill.Size = UDim2.fromScale(0, 1)
progressFill.BackgroundColor3 = colors.accent
progressFill.BorderSizePixel = 0
progressFill.Parent = progress
corner(progressFill, 3)

local function createButton(text, order)
	local button = Instance.new("TextButton")
	button.Size = UDim2.new(1, 0, 0, 32)
	button.BackgroundColor3 = Color3.new(0.066667, 0.058824, 0.058824)
	button.BorderSizePixel = 0
	button.Font = Enum.Font.GothamBold
	button.TextSize = 13
	button.TextColor3 = colors.text
	button.Text = text
	button.LayoutOrder = order
	button.Parent = operations
	corner(button, 8)
	return button
end

local refreshButton = createButton("Refresh Selection", 4)
local connectButton = createButton("Connect Worker", 5)
local inspectButton = createButton("Bake Selection", 6)
local cancelButton = createButton("Cancel Bake", 7)
cancelButton.Visible = false
inspectButton.BackgroundColor3 = colors.accentDark
inspectButton.TextColor3 = Color3.new(1, 1, 1)

local settingsTitle = createLabel("ADVANCED SETTINGS", 14, colors.sub, 1, settings)
settingsTitle.Font = Enum.Font.GothamBold
settingsTitle.TextSize = 11

createLabel("Maximum triangles per initial asset chunk", 18, colors.sub, 2, settings)
local chunkInput = Instance.new("TextBox")
chunkInput.Size = UDim2.new(1, 0, 0, 32)
chunkInput.BackgroundColor3 = colors.panelDark
chunkInput.BorderSizePixel = 0
chunkInput.Font = Enum.Font.Gotham
chunkInput.TextSize = 13
chunkInput.TextColor3 = colors.text
chunkInput.PlaceholderColor3 = colors.sub
chunkInput.PlaceholderText = "1000–20000"
chunkInput.ClearTextOnFocus = false
chunkInput.Text = "20000"
chunkInput.LayoutOrder = 3
chunkInput.Parent = settings
corner(chunkInput, 8)
stroke(chunkInput, colors.stroke, 0.5)

createLabel(
	"Source textures retain their original dimensions. Oversized GLBs are split automatically after encoding.",
	0,
	colors.sub,
	4,
	settings
).AutomaticSize =
	Enum.AutomaticSize.Y
local maxTrianglesPerChunk = 20000

chunkInput.FocusLost:Connect(function()
	local value = tonumber(chunkInput.Text) or 20000
	value = math.floor(math.clamp(value, 1000, 20000) / 1000 + 0.5) * 1000
	maxTrianglesPerChunk = value
	chunkInput.Text = tostring(value)
end)

local client
local connected = false
local requestId = 0
local pendingRequest
local pendingSelection
local requestState
local setStatus
local progressStages = {
	textures = 1,
	geometry = 2,
	overlays = 3,
	texture_assets = 4,
	splitting = 5,
	publishing = 6,
	geometry_preparation = 6,
	geometry_upload = 7,
	cancelling = 8,
}

local function transitionRequest(nextState)
	if not requestState then
		return false
	end
	local transitions = {
		processing = { response_received = true, cancelling = true, cancelled = true, failed = true },
		response_received = { studio_upload = true, replacing = true, complete = true, failed = true, cancelled = true },
		studio_upload = { replacing = true, failed = true, cancelled = true },
		replacing = { complete = true, failed = true },
		cancelling = { cancelled = true, failed = true },
	}
	if not (transitions[requestState.state] and transitions[requestState.state][nextState]) then
		return false
	end
	requestState.state = nextState
	return true
end

local setErrorDetails

local function finishRequest(state, message, color)
	transitionRequest(state)
	if state == "complete" or state == "cancelled" then
		setErrorDetails(nil)
	end
	pendingRequest = nil
	pendingSelection = nil
	cancelButton.Visible = false
	cancelButton.Active = true
	cancelButton.Text = "Cancel Bake"
	if state == "complete" then
		progressFill.Size = UDim2.fromScale(1, 1)
	end
	if message then
		setStatus(message, color)
	end
end

setStatus = function(message, color)
	status.Text = message
	status.TextColor3 = color or colors.sub
end

setErrorDetails = function(message)
	errorDetails.Text = message
	errorDetails.Visible = message ~= nil and message ~= ""
end

local function countSelection()
	local selected = Selection:Get()
	local geometry = 0
	local descendants = 0
	local unions = 0
	for _, instance in selected do
		if instance:IsA("BasePart") then
			geometry += 1
			if instance:IsA("UnionOperation") then
				unions += 1
			end
		end
		for _, descendant in instance:GetDescendants() do
			descendants += 1
			if descendant:IsA("BasePart") then
				geometry += 1
				if descendant:IsA("UnionOperation") then
					unions += 1
				end
			end
		end
	end
	selectionStats.Text = string.format(
		"Selection: %d roots · %d geometry parts · %d unions · %d descendants",
		#selected,
		geometry,
		unions,
		descendants
	)
	return selected, geometry, descendants
end

local function closeClient()
	if client then
		pcall(function()
			client:Close()
		end)
		client = nil
	end
	connected = false
	pendingRequest = nil
	pendingSelection = nil
	requestState = nil
	progressFill.Size = UDim2.fromScale(0, 1)
	cancelButton.Visible = false
	cancelButton.Active = true
	cancelButton.Text = "Cancel Bake"
	connectButton.Text = "Connect Worker"
end

local function loadOutputUnsafe(assetIds, assetMaterials, assetSources, textureAssets, models)
	local textureAssetsByPage = {}
	local supportedTextureSlots = {
		color = true,
		metalness = true,
		roughness = true,
		normal = true,
		emissive = true,
	}
	for _, binding in textureAssets or {} do
		assert(
			type(binding.page) == "number" and binding.page >= 0 and binding.page % 1 == 0,
			"Worker returned an invalid texture page"
		)
		assert(supportedTextureSlots[binding.slot], "Worker returned an unsupported texture slot")
		assert(
			type(binding.assetId) == "string" and binding.assetId:match("^%d+$"),
			"Worker returned an invalid texture asset ID"
		)
		local page = textureAssetsByPage[binding.page] or {}
		assert(not page[binding.slot], "Worker returned a duplicate texture asset binding")
		page[binding.slot] = binding.assetId
		textureAssetsByPage[binding.page] = page
	end
	assert(#assetIds > 0, "Worker returned no geometry assets")
	assert(assetMaterials and #assetMaterials == #assetIds, "Worker returned incomplete material bindings")
	assert(assetSources and #assetSources == #assetIds, "Worker returned incomplete source assignments")
	for index, assetId in assetIds do
		assert(
			type(assetId) == "string" and assetId:match("^%d+$"),
			string.format("Worker returned an invalid geometry asset ID at index %d", index)
		)
		local binding = assetMaterials[index]
		assert(type(binding) == "table", string.format("Worker omitted material metadata for geometry asset %d", index))
		assert(
			type(binding.material) == "string" and Enum.Material[binding.material],
			string.format("Worker returned an invalid material for geometry asset %d", index)
		)
		assert(
			type(binding.materialVariant) == "string",
			string.format("Worker returned an invalid material variant for geometry asset %d", index)
		)
		assert(
			type(binding.doubleSided) == "boolean",
			string.format("Worker returned invalid double-sided metadata for geometry asset %d", index)
		)
		assert(
			type(binding.reflectance) == "number" and binding.reflectance >= 0 and binding.reflectance <= 1,
			string.format("Worker returned invalid reflectance for geometry asset %d", index)
		)
		assert(
			type(binding.hasMetalness) == "boolean" and type(binding.hasRoughness) == "boolean",
			string.format("Worker returned invalid metallic or roughness metadata for geometry asset %d", index)
		)
		assert(
			not binding.hasMetalness or binding.metallicRoughnessPage ~= nil,
			string.format("Worker omitted the metalness page for geometry asset %d", index)
		)
		assert(
			not binding.hasRoughness or binding.metallicRoughnessPage ~= nil,
			string.format("Worker omitted the roughness page for geometry asset %d", index)
		)
		assert(
			binding.alphaMode == nil or (type(binding.alphaMode) == "string" and Enum.AlphaMode[binding.alphaMode]),
			string.format("Worker returned an invalid alpha mode for geometry asset %d", index)
		)
		assert(
			binding.resampleMode == nil
				or (type(binding.resampleMode) == "string" and Enum.ResamplerMode[binding.resampleMode]),
			string.format("Worker returned an invalid resampling mode for geometry asset %d", index)
		)
		if binding.emissiveTint ~= nil then
			assert(
				type(binding.emissiveTint) == "table" and #binding.emissiveTint == 3,
				string.format("Worker returned an invalid emissive tint for geometry asset %d", index)
			)
			for _, component in binding.emissiveTint do
				assert(
					type(component) == "number" and component >= 0 and component <= 1,
					string.format("Worker returned an invalid emissive tint for geometry asset %d", index)
				)
			end
		end
		assert(
			binding.emissiveStrength == nil
				or (type(binding.emissiveStrength) == "number" and binding.emissiveStrength >= 0),
			string.format("Worker returned an invalid emissive strength for geometry asset %d", index)
		)
		local sourceNames = assetSources[index]
		assert(
			type(sourceNames) == "table" and #sourceNames > 0,
			string.format("Worker omitted source assignments for geometry asset %d", index)
		)
		local seenSources = {}
		for _, sourceName in sourceNames do
			assert(
				type(sourceName) == "string" and sourceName ~= "",
				string.format("Worker returned an invalid source assignment for geometry asset %d", index)
			)
			assert(
				not seenSources[sourceName],
				string.format("Worker returned a duplicate source assignment for geometry asset %d", index)
			)
			seenSources[sourceName] = true
		end
		local texturePage
		for _, page in
			{
				binding.baseColorPage,
				binding.metallicRoughnessPage,
				binding.normalPage,
				binding.emissivePage,
			}
		do
			if page ~= nil then
				assert(
					type(page) == "number" and page >= 0 and page % 1 == 0,
					"Worker returned an invalid material texture page"
				)
				assert(
					texturePage == nil or texturePage == page,
					"Worker returned unsynchronized material texture pages"
				)
				texturePage = page
			end
		end
		if texturePage ~= nil then
			local maps = textureAssetsByPage[texturePage]
			assert(maps, string.format("Worker omitted texture assets for page %d", texturePage))
			if binding.baseColorPage then
				assert(maps.color, string.format("Worker omitted the color map for page %d", texturePage))
			end
			if binding.hasMetalness then
				assert(maps.metalness, string.format("Worker omitted the metalness map for page %d", texturePage))
			end
			if binding.hasRoughness then
				assert(maps.roughness, string.format("Worker omitted the roughness map for page %d", texturePage))
			end
			if binding.normalPage then
				assert(maps.normal, string.format("Worker omitted the normal map for page %d", texturePage))
			end
			if binding.emissivePage then
				assert(maps.emissive, string.format("Worker omitted the emissive map for page %d", texturePage))
			end
		end
	end
	local meshParts = {}
	local sourceAssignments = {}
	local meshPartSources = {}
	local importedModels = {}
	for batchStart = 1, #assetIds, 5 do
		local batchEnd = math.min(batchStart + 4, #assetIds)
		setStatus(
			string.format("Importing geometry assets %d-%d of %d (up to 5 at once).", batchStart, batchEnd, #assetIds)
		)
		local batchResults = {}
		local completed = 0
		for index = batchStart, batchEnd do
			local assetId = assetIds[index]
			task.spawn(function()
				local model
				local failure
				repeat
					local ok, result = pcall(AssetService.LoadAssetAsync, AssetService, tonumber(assetId))
					if ok then
						model = result
						model.Parent = nil
						failure = nil
					else
						failure = tostring(result)
						local normalized = string.lower(failure)
						local rateLimited = string.find(normalized, "429", 1, true)
							or string.find(normalized, "rate limit", 1, true)
							or string.find(normalized, "too many requests", 1, true)
							or string.find(normalized, "throttl", 1, true)
						if rateLimited then
							setStatus(
								"Roblox asset import rate limit reached. Waiting 60 seconds before retrying asset "
									.. assetId
									.. "."
							)
							for remaining = 60, 1, -1 do
								if remaining % 10 == 0 or remaining <= 5 then
									setStatus(
										"Roblox asset import rate limit reached. Retrying asset "
											.. assetId
											.. " in "
											.. remaining
											.. " seconds."
									)
								end
								task.wait(1)
							end
						end
					end
				until model or not failure
				batchResults[index] = { model = model, error = failure }
				completed += 1
			end)
		end
		while completed < batchEnd - batchStart + 1 do
			task.wait()
		end
		local failures = {}
		for index = batchStart, batchEnd do
			local result = batchResults[index]
			local model = result.model
			if model and model:IsA("Model") then
				importedModels[index] = model
				table.insert(models, model)
				model:PivotTo(CFrame.Angles(0, math.pi, 0) * model:GetPivot())
			else
				if model then
					model:Destroy()
				end
				table.insert(
					failures,
					string.format("%s: %s", assetIds[index], result.error or "Roblox did not return a Model asset")
				)
			end
		end
		assert(#failures == 0, "Could not import geometry asset(s): " .. table.concat(failures, "; "))
	end
	for index, assetId in assetIds do
		local model = importedModels[index]
		local materialBinding = assetMaterials and assetMaterials[index]
		local sourceNames = assetSources and assetSources[index] or {}
		local modelMeshParts = {}
		local nestedModels = {}
		for _, descendant in model:GetDescendants() do
			if descendant:IsA("MeshPart") then
				descendant.Anchored = true
				descendant.Color = Color3.new(1, 1, 1)
				descendant.CollisionFidelity = Enum.CollisionFidelity.Tunable
				descendant.CollisionPrecision = 1
				descendant.Parent = model
				if materialBinding then
					descendant.Material = Enum.Material[materialBinding.material]
					descendant.MaterialVariant = materialBinding.materialVariant or ""
					descendant.DoubleSided = materialBinding.doubleSided
					descendant.Reflectance = materialBinding.reflectance or 0
					local texturePage = materialBinding.baseColorPage
						or materialBinding.metallicRoughnessPage
						or materialBinding.normalPage
						or materialBinding.emissivePage
					local maps = texturePage and textureAssetsByPage[texturePage]
					if maps then
						local appearance = Instance.new("SurfaceAppearance")
						local function setMap(property, slot)
							local assetId = maps[slot]
							assert(assetId, string.format("Worker omitted the %s map for page %d", slot, texturePage))
							appearance[property] = Content.fromAssetId(tonumber(assetId))
						end
						if materialBinding.baseColorPage then
							setMap("ColorMapContent", "color")
						end
						if materialBinding.hasMetalness then
							setMap("MetalnessMapContent", "metalness")
						end
						if materialBinding.hasRoughness then
							setMap("RoughnessMapContent", "roughness")
						end
						if materialBinding.normalPage then
							setMap("NormalMapContent", "normal")
						end
						if materialBinding.emissivePage then
							setMap("EmissiveMaskContent", "emissive")
						end
						appearance.AlphaMode = Enum.AlphaMode[materialBinding.alphaMode or "Transparency"]
						appearance.ResampleMode = Enum.ResamplerMode[materialBinding.resampleMode or "Default"]
						if materialBinding.emissiveTint then
							appearance.EmissiveTint = Color3.new(table.unpack(materialBinding.emissiveTint))
						end
						appearance.EmissiveStrength = materialBinding.emissiveStrength or 1
						appearance.Parent = descendant
					end
				end
				table.insert(modelMeshParts, descendant)
				table.insert(meshParts, descendant)
			elseif descendant:IsA("Model") then
				table.insert(nestedModels, descendant)
			end
		end
		for _, nestedModel in nestedModels do
			nestedModel:Destroy()
		end
		assert(#modelMeshParts > 0, "Uploaded asset contains no MeshParts")
		for _, sourceName in sourceNames do
			local assigned = sourceAssignments[sourceName] or {}
			for _, meshPart in modelMeshParts do
				table.insert(assigned, meshPart)
				local meshSources = meshPartSources[meshPart] or {}
				table.insert(meshSources, sourceName)
				meshPartSources[meshPart] = meshSources
			end
			sourceAssignments[sourceName] = assigned
		end
	end
	return models, meshParts, sourceAssignments, meshPartSources
end

local function loadGeometryOutput(geometryAssets, assetMaterials, assetSources, textureAssets)
	pcall(PhysicsService.RegisterCollisionGroup, PhysicsService, "Box")
	print(string.format("[PA Combine] Studio received %d geometry asset(s)", #geometryAssets))
	local textureAssetsByPage = {}
	for _, binding in textureAssets or {} do
		local page = textureAssetsByPage[binding.page] or {}
		page[binding.slot] = binding.assetId
		textureAssetsByPage[binding.page] = page
	end
	assert(#geometryAssets > 0, "Worker returned no geometry assets")
	assert(#assetMaterials == #geometryAssets, "Worker returned incomplete material bindings")
	assert(#assetSources == #geometryAssets, "Worker returned incomplete source assignments")
	local models = {}
	local meshParts = {}
	local sourceAssignments = {}
	local meshPartSources = {}
	local totalAssets = #geometryAssets
	local results = table.create(totalAssets)
	local completed = 0
	for batchStart = 1, totalAssets, 5 do
		local batchEnd = math.min(batchStart + 4, totalAssets)
		setStatus(string.format("Creating geometry assets %d-%d of %d.", batchStart, batchEnd, totalAssets))
		for index = batchStart, batchEnd do
			local geometry = geometryAssets[index]
			geometryAssets[index] = nil
			local boundsMin = { math.huge, math.huge, math.huge }
			local boundsMax = { -math.huge, -math.huge, -math.huge }
			for _, position in geometry.positions do
				for axis = 1, 3 do
					boundsMin[axis] = math.min(boundsMin[axis], position[axis])
					boundsMax[axis] = math.max(boundsMax[axis], position[axis])
				end
			end
			local origin = Vector3.new(
				(boundsMin[1] + boundsMax[1]) * 0.5,
				(boundsMin[2] + boundsMax[2]) * 0.5,
				(boundsMin[3] + boundsMax[3]) * 0.5
			)
			for _, position in geometry.positions do
				position[1] -= origin.X
				position[2] -= origin.Y
				position[3] -= origin.Z
			end
			print(
				string.format(
					"[PA Combine] Starting Studio geometry asset %d/%d (%d vertices, %d triangles)",
					index,
					totalAssets,
					#geometry.positions,
					#geometry.indices / 3
				)
			)
			task.spawn(function()
				local editableMesh
				local model
				local ok, result = pcall(function()
					editableMesh = AssetService:CreateEditableMesh()
					assert(editableMesh, "Studio could not create an EditableMesh")
					local vertexIds = table.create(#geometry.positions)
					local normalIds = table.create(#geometry.normals)
					local uvIds = table.create(#geometry.uvs)
					local colorIds = table.create(#geometry.colors)
					for vertexIndex, position in geometry.positions do
						vertexIds[vertexIndex] =
							editableMesh:AddVertex(Vector3.new(position[1], position[2], position[3]))
					end
					for vertexIndex, normal in geometry.normals do
						normalIds[vertexIndex] = editableMesh:AddNormal(Vector3.new(normal[1], normal[2], normal[3]))
					end
					for vertexIndex, uv in geometry.uvs do
						uvIds[vertexIndex] = editableMesh:AddUV(Vector2.new(uv[1], uv[2]))
					end
					for vertexIndex, color in geometry.colors do
						colorIds[vertexIndex] =
							editableMesh:AddColor(Color3.new(color[1], color[2], color[3]), color[4])
					end
					for indexOffset = 1, #geometry.indices, 3 do
						local first = geometry.indices[indexOffset] + 1
						local second = geometry.indices[indexOffset + 1] + 1
						local third = geometry.indices[indexOffset + 2] + 1
						local faceId = editableMesh:AddTriangle(vertexIds[first], vertexIds[second], vertexIds[third])
						editableMesh:SetFaceNormals(faceId, { normalIds[first], normalIds[second], normalIds[third] })
						editableMesh:SetFaceUVs(faceId, { uvIds[first], uvIds[second], uvIds[third] })
						editableMesh:SetFaceColors(faceId, { colorIds[first], colorIds[second], colorIds[third] })
					end
					print(
						string.format(
							"[PA Combine] EditableMesh %d populated: %d vertices, %d triangles; publishing asset",
							index,
							#geometry.positions,
							#geometry.indices / 3
						)
					)
					local creatorType = game.CreatorType == Enum.CreatorType.Group and Enum.AssetCreatorType.Group
						or Enum.AssetCreatorType.User
					local status, assetId = AssetService:CreateAssetAsync(editableMesh, Enum.AssetType.Mesh, {
						Name = string.format("PA Combine Output %d", index),
						Description = "Combined geometry generated by PA Combine.",
						CreatorId = game.CreatorId,
						CreatorType = creatorType,
					})
					assert(status == Enum.CreateAssetResult.Success, tostring(assetId or status))
					print(
						string.format("[PA Combine] Studio geometry asset %d published as %s", index, tostring(assetId))
					)
					editableMesh:Destroy()
					editableMesh = nil
					local meshPart = AssetService:CreateMeshPartAsync(Content.fromAssetId(assetId), {
						CollisionFidelity = Enum.CollisionFidelity.Tunable,
						RenderFidelity = Enum.RenderFidelity.Precise,
					})
					meshPart.Anchored = true
					meshPart.CFrame = CFrame.new(origin)
					meshPart.Color = Color3.new(1, 1, 1)
					meshPart.CastShadow = true
					local binding = assetMaterials[index]
					meshPart.Transparency = binding.transparency or 0
					if binding.surfaceOverlay and binding.hasColorAlpha then
						meshPart.Transparency = math.max(meshPart.Transparency, 0.02)
					end
					if binding.surfaceOverlay then
						meshPart:SetAttribute("SurfaceOverlay", true)
						meshPart.CollisionFidelity = Enum.CollisionFidelity.Box
						meshPart.CanCollide = false
						meshPart.CanTouch = false
						meshPart.CanQuery = false
					end
					meshPart.Material = Enum.Material[binding.material]
					meshPart.MaterialVariant = binding.materialVariant or ""
					meshPart.DoubleSided = binding.doubleSided
					meshPart.CastShadow = binding.castShadow
					print(string.format("[PA Combine] Studio geometry asset %d created as MeshPart", index))
					meshPart.Reflectance = binding.reflectance or 0
					local texturePage = binding.baseColorPage
						or binding.metallicRoughnessPage
						or binding.normalPage
						or binding.emissivePage
					local maps = texturePage and textureAssetsByPage[texturePage]
					if maps then
						local appearance = Instance.new("SurfaceAppearance")
						local function setMap(property, slot)
							local textureAssetId = maps[slot]
							assert(
								textureAssetId,
								string.format("Worker omitted the %s map for page %d", slot, texturePage)
							)
							appearance[property] = Content.fromAssetId(tonumber(textureAssetId))
						end
						if binding.baseColorPage then
							setMap("ColorMapContent", "color")
						end
						if binding.hasMetalness then
							setMap("MetalnessMapContent", "metalness")
						end
						if binding.hasRoughness then
							setMap("RoughnessMapContent", "roughness")
						end
						if binding.normalPage then
							setMap("NormalMapContent", "normal")
						end
						if binding.emissivePage then
							setMap("EmissiveMaskContent", "emissive")
						end
						appearance.AlphaMode = Enum.AlphaMode[binding.alphaMode or "Transparency"]
						appearance.ResampleMode = Enum.ResamplerMode[binding.resampleMode or "Default"]
						if binding.emissiveTint then
							appearance.EmissiveTint = Color3.new(table.unpack(binding.emissiveTint))
						end
						appearance.EmissiveStrength = binding.emissiveStrength or 1
						appearance.Parent = meshPart
					end
					model = Instance.new("Model")
					model.Name = string.format("PA Combine Output %d", index)
					meshPart.Parent = model
					return meshPart
				end)
				if editableMesh then
					editableMesh:Destroy()
				end
				results[index] = { ok = ok, result = result, model = model }
				completed += 1
				if not ok then
					warn(string.format("[PA Combine] EditableMesh %d failed: %s", index, tostring(result)))
				end
			end)
		end
		while completed < batchEnd do
			task.wait()
		end
	end
	print(
		string.format("[PA Combine] Studio geometry asset creation finished: %d/%d completed", completed, totalAssets)
	)
	local failures = {}
	for index, result in results do
		if not result.ok then
			table.insert(failures, string.format("geometry asset %d: %s", index, tostring(result.result)))
		else
			local model = result.model
			local meshPart = result.result
			table.insert(models, model)
			table.insert(meshParts, meshPart)
			for _, sourceName in assetSources[index] do
				local assigned = sourceAssignments[sourceName] or {}
				table.insert(assigned, meshPart)
				sourceAssignments[sourceName] = assigned
				local meshSources = meshPartSources[meshPart] or {}
				table.insert(meshSources, sourceName)
				meshPartSources[meshPart] = meshSources
			end
		end
	end
	if #failures > 0 then
		for _, model in models do
			model:Destroy()
		end
		error("Could not create geometry asset(s): " .. table.concat(failures, "; "))
	end
	return models, meshParts, sourceAssignments, meshPartSources
end

local function loadOutput(assetIds, assetMaterials, assetSources, textureAssets)
	local models = {}
	local ok, result, meshParts, sourceAssignments, meshPartSources =
		pcall(loadOutputUnsafe, assetIds, assetMaterials, assetSources, textureAssets, models)
	if not ok then
		for _, model in models do
			model.Parent = nil
		end
		error(result)
	end
	return result, meshParts, sourceAssignments, meshPartSources
end

local function getAncestors(instance)
	local ancestors = {}
	while instance do
		table.insert(ancestors, 1, instance)
		instance = instance.Parent
	end
	return ancestors
end

local function getLowestCommonAncestor(instances)
	local paths = {}
	for _, instance in instances do
		table.insert(paths, getAncestors(instance))
	end
	local common
	for index = 1, #paths[1] do
		local candidate = paths[1][index]
		for pathIndex = 2, #paths do
			if paths[pathIndex][index] ~= candidate then
				return common
			end
		end
		common = candidate
	end
	return common
end

local function normalizeSelection(selected)
	local roots = {}
	for _, candidate in selected do
		local nested = false
		for _, other in selected do
			if candidate ~= other and other:IsAncestorOf(candidate) then
				nested = true
				break
			end
		end
		if not nested then
			table.insert(roots, candidate)
		end
	end
	return roots
end

local function cloneInstance(instance)
	local archivable = instance.Archivable
	if not archivable then
		instance.Archivable = true
	end
	local ok, clone = pcall(instance.Clone, instance)
	instance.Archivable = archivable
	if not ok then
		error(clone)
	end
	return clone
end

local function getSourceTargets(source, sourceAssignments, identity)
	local assigned = sourceAssignments[identity]
	assert(assigned and #assigned > 0, string.format("No output geometry was assigned to source %s", source.Name))
	for _, target in assigned do
		assert(
			target and target:IsA("MeshPart"),
			string.format("Source %s has an invalid output geometry assignment", source.Name)
		)
	end
	return assigned
end

local function remapPartReference(constraint, property, sourceTargets)
	local ok, source = pcall(function()
		return constraint[property]
	end)
	local targets = ok and source and sourceTargets[source]
	if not targets or #targets == 0 then
		return
	end
	local frameProperty = property == "Part0" and "C0" or "C1"
	local worldFrame
	if constraint:IsA("JointInstance") then
		local frameOk, localFrame = pcall(function()
			return constraint[frameProperty]
		end)
		if frameOk then
			worldFrame = source.CFrame * localFrame
		end
	end
	local target = getNearestPart(targets, worldFrame and worldFrame.Position or source.Position)
	if not target then
		return
	end
	constraint[property] = target
	if worldFrame then
		constraint[frameProperty] = target.CFrame:ToObjectSpace(worldFrame)
	end
end

local function getReferenceInstances(sourceTargets)
	local instances = {}
	local seen = {}
	local function include(instance)
		if not seen[instance] then
			seen[instance] = true
			table.insert(instances, instance)
		end
	end
	for _, instance in game:GetDescendants() do
		include(instance)
	end
	for _, targets in sourceTargets do
		for _, target in targets do
			include(target)
			for _, descendant in target:GetDescendants() do
				include(descendant)
			end
		end
	end
	return instances
end

local function remapConstraints(sourceTargets)
	for _, instance in getReferenceInstances(sourceTargets) do
		if instance:IsA("JointInstance") or instance:IsA("WeldConstraint") or instance:IsA("NoCollisionConstraint") then
			remapPartReference(instance, "Part0", sourceTargets)
			remapPartReference(instance, "Part1", sourceTargets)
			local part0 = instance.Part0
			local part1 = instance.Part1
			if part0 and part0 == part1 then
				instance.Parent = nil
			end
		end
	end
end

local function remapObjectReferences(sourceTargets)
	for _, instance in getReferenceInstances(sourceTargets) do
		if instance:IsA("ObjectValue") then
			local targets = instance.Value and sourceTargets[instance.Value]
			if targets and targets[1] then
				instance.Value = targets[1]
			end
		elseif instance:IsA("Model") then
			local targets = instance.PrimaryPart and sourceTargets[instance.PrimaryPart]
			if targets and targets[1] then
				instance.PrimaryPart = targets[1]
			end
		end
	end
end

local function applyMergedProperties(sourceTargets, sourceAssemblyAnchored)
	local merged = {}
	for source, targets in sourceTargets do
		for _, target in targets do
			local properties = merged[target]
			if not properties then
				properties = {
					castShadow = false,
					anchored = sourceAssemblyAnchored[source],
					collisionGroup = source.CollisionGroup,
					customPhysicalProperties = source.CustomPhysicalProperties,
					attributes = {},
					attributeConflicts = {},
					tags = {},
				}
				merged[target] = properties
			else
				if properties.collisionGroup ~= source.CollisionGroup then
					properties.collisionGroup = nil
				end
				if properties.customPhysicalProperties ~= source.CustomPhysicalProperties then
					properties.customPhysicalProperties = nil
				end
			end
			properties.castShadow = properties.castShadow or source.CastShadow
			properties.anchored = properties.anchored and sourceAssemblyAnchored[source]
			for name, value in source:GetAttributes() do
				if properties.attributeConflicts[name] then
					continue
				end
				if properties.attributes[name] == nil then
					properties.attributes[name] = value
				elseif properties.attributes[name] ~= value then
					properties.attributes[name] = nil
					properties.attributeConflicts[name] = true
				end
			end
			for _, tag in CollectionService:GetTags(source) do
				properties.tags[tag] = true
			end
		end
	end
	for target, properties in merged do
		target.CanCollide = false
		target.CanTouch = false
		target.CanQuery = false
		target.CastShadow = properties.castShadow
		target.Anchored = properties.anchored
		target.Massless = true
		if properties.collisionGroup then
			target.CollisionGroup = properties.collisionGroup
		end
		if properties.customPhysicalProperties then
			target.CustomPhysicalProperties = properties.customPhysicalProperties
		end
		for name, value in properties.attributes do
			target:SetAttribute(name, value)
		end
		for tag in properties.tags do
			CollectionService:AddTag(target, tag)
		end
	end
end

local appearanceProperties = {
	SurfaceAppearance = {
		"TexturePackContent",
		"ColorMapContent",
		"MetalnessMapContent",
		"NormalMapContent",
		"RoughnessMapContent",
		"EmissiveMaskContent",
		"EmissiveTint",
		"EmissiveStrength",
		"AlphaMode",
		"Color",
		"ResampleMode",
	},
	MaterialVariant = {
		"BaseMaterial",
		"CustomPhysicalProperties",
		"StudsPerTile",
		"MaterialPattern",
		"ColorMapContent",
		"MetalnessMapContent",
		"NormalMapContent",
		"RoughnessMapContent",
		"EmissiveMaskContent",
		"EmissiveTint",
		"EmissiveStrength",
		"AlphaMode",
	},
	Decal = {
		"Texture",
		"ColorMapContent",
		"MetalnessMapContent",
		"NormalMapContent",
		"RoughnessMapContent",
		"EmissiveMaskContent",
		"EmissiveTint",
		"EmissiveStrength",
		"Color3",
		"Transparency",
		"LocalTransparencyModifier",
		"Rotation",
		"Face",
		"ZIndex",
	},
	Texture = {
		"Texture",
		"ColorMapContent",
		"MetalnessMapContent",
		"NormalMapContent",
		"RoughnessMapContent",
		"EmissiveMaskContent",
		"EmissiveTint",
		"EmissiveStrength",
		"Color3",
		"Transparency",
		"LocalTransparencyModifier",
		"Rotation",
		"Face",
		"StudsPerTileU",
		"StudsPerTileV",
		"OffsetStudsU",
		"OffsetStudsV",
		"ZIndex",
	},
}

local function captureAppearanceStates(roots)
	local states = {}
	local seen = {}
	local function capture(instance)
		if seen[instance] then
			return
		end
		seen[instance] = true
		local properties = appearanceProperties[instance.ClassName]
		if not properties then
			return
		end
		local values = {}
		for _, property in properties do
			local ok, value = pcall(function()
				return instance[property]
			end)
			if ok then
				values[property] = value
			end
		end
		table.insert(states, {
			instance = instance,
			parent = instance.Parent,
			className = instance.ClassName,
			properties = values,
		})
	end
	for _, root in roots do
		capture(root)
		for _, descendant in root:GetDescendants() do
			capture(descendant)
			if descendant:IsA("BasePart") and descendant.MaterialVariant ~= "" then
				local variant = MaterialService:GetMaterialVariant(descendant.Material, descendant.MaterialVariant)
				if variant and variant:IsA("MaterialVariant") then
					capture(variant)
				end
			end
		end
		if root:IsA("BasePart") and root.MaterialVariant ~= "" then
			local variant = MaterialService:GetMaterialVariant(root.Material, root.MaterialVariant)
			if variant and variant:IsA("MaterialVariant") then
				capture(variant)
			end
		end
	end
	return states
end

local function validateAppearanceStates(snapshot)
	local current = captureAppearanceStates(snapshot.roots)
	assert(
		#current == #snapshot.appearanceStates,
		"Texture, overlay, or material instances were added or removed while baking"
	)
	local expected = {}
	for _, state in snapshot.appearanceStates do
		expected[state.instance] = state
	end
	for _, state in current do
		local previous = expected[state.instance]
		assert(previous, string.format("Appearance instance %s was added while baking", state.instance:GetFullName()))
		assert(
			state.parent == previous.parent and state.className == previous.className,
			string.format("Appearance instance %s was moved or replaced while baking", state.instance.Name)
		)
		for property, value in previous.properties do
			assert(
				value == state.properties[property],
				string.format("%s.%s changed while baking", state.instance:GetFullName(), property)
			)
		end
		for property, value in state.properties do
			assert(
				value == previous.properties[property],
				string.format("%s.%s changed while baking", state.instance:GetFullName(), property)
			)
		end
	end
end

local function captureHierarchyStates(roots)
	local states = {}
	for _, root in roots do
		states[root] = root.Parent
		for _, descendant in root:GetDescendants() do
			states[descendant] = descendant.Parent
		end
	end
	return states
end

local function validateHierarchyStates(snapshot)
	local current = {}
	for _, root in snapshot.roots do
		current[root] = true
		assert(
			snapshot.hierarchyStates[root] == root.Parent,
			string.format("Selected root %s was moved while baking", root.Name)
		)
		for _, descendant in root:GetDescendants() do
			current[descendant] = true
			assert(
				snapshot.hierarchyStates[descendant] ~= nil,
				string.format("Instance %s was added while baking", descendant.Name)
			)
			assert(
				snapshot.hierarchyStates[descendant] == descendant.Parent,
				string.format("Instance %s was moved while baking", descendant.Name)
			)
		end
	end
	for instance in snapshot.hierarchyStates do
		assert(current[instance], string.format("Instance %s was removed while baking", instance.Name))
	end
end

local function getTagSet(instance)
	local tags = {}
	for _, tag in CollectionService:GetTags(instance) do
		tags[tag] = true
	end
	return tags
end

local function dictionariesMatch(first, second)
	for key, value in first do
		if second[key] ~= value then
			return false
		end
	end
	for key, value in second do
		if first[key] ~= value then
			return false
		end
	end
	return true
end

local function captureReplacementState(snapshot, models, meshParts)
	local state = {
		parents = {},
		names = {},
		models = {},
		constraints = {},
		objectValues = {},
		created = {},
		velocities = {},
		appearanceTransparency = {},
	}
	for instance, parent in snapshot.hierarchyStates do
		state.parents[instance] = parent
		state.names[instance] = instance.Name
		if instance:IsA("Decal") or instance:IsA("Texture") then
			state.appearanceTransparency[instance] = instance.Transparency
		end
		if instance:IsA("Model") then
			state.models[instance] = {
				pivot = instance:GetPivot(),
				primaryPart = instance.PrimaryPart,
			}
		end
	end
	for _, meshPart in meshParts do
		state.parents[meshPart] = meshPart.Parent
		state.names[meshPart] = meshPart.Name
	end
	for _, model in models do
		state.parents[model] = model.Parent
		state.names[model] = model.Name
	end
	local sources = {}
	for _, source in snapshot.geometry do
		sources[source] = true
		state.velocities[source] = {
			linear = source.AssemblyLinearVelocity,
			angular = source.AssemblyAngularVelocity,
		}
	end
	for _, instance in game:GetDescendants() do
		if instance:IsA("JointInstance") or instance:IsA("WeldConstraint") or instance:IsA("NoCollisionConstraint") then
			if sources[instance.Part0] or sources[instance.Part1] then
				state.constraints[instance] = {
					parent = instance.Parent,
					part0 = instance.Part0,
					part1 = instance.Part1,
					c0 = instance:IsA("JointInstance") and instance.C0 or nil,
					c1 = instance:IsA("JointInstance") and instance.C1 or nil,
				}
			end
		elseif instance:IsA("ObjectValue") and sources[instance.Value] then
			state.objectValues[instance] = instance.Value
		elseif instance:IsA("Model") and sources[instance.PrimaryPart] then
			state.models[instance] = state.models[instance]
				or {
					pivot = instance:GetPivot(),
					primaryPart = instance.PrimaryPart,
				}
		end
	end
	return state
end

local function restoreReplacementState(state)
	for _, instance in state.created do
		instance.Parent = nil
	end
	for instance, parent in state.parents do
		instance.Parent = parent
	end
	for instance, name in state.names do
		instance.Name = name
	end
	for instance, transparency in state.appearanceTransparency do
		instance.Transparency = transparency
	end
	for instance, reference in state.objectValues do
		instance.Value = reference
	end
	for instance, properties in state.constraints do
		instance.Part0 = properties.part0
		instance.Part1 = properties.part1
		if instance:IsA("JointInstance") then
			instance.C0 = properties.c0
			instance.C1 = properties.c1
		end
		instance.Parent = properties.parent
	end
	for instance, properties in state.models do
		instance.PrimaryPart = properties.primaryPart
		instance.WorldPivot = properties.pivot
	end
	for instance, velocity in state.velocities do
		instance.AssemblyLinearVelocity = velocity.linear
		instance.AssemblyAngularVelocity = velocity.angular
	end
end

local function replaceSelection(snapshot, models, meshParts, sourceAssignments, meshPartSources)
	assert(snapshot and #snapshot.roots > 0, "The original selection is no longer available")
	assert(#meshParts > 0, "The uploaded assets contain no geometry")
	validateAppearanceStates(snapshot)
	validateHierarchyStates(snapshot)
	for _, sourceState in snapshot.sourceStates do
		local source = sourceState.instance
		assert(
			source.Parent == sourceState.parent,
			string.format("Source %s was moved or removed while baking", source.Name)
		)
		assert(
			source.CFrame == sourceState.cframe and source.Size == sourceState.size,
			string.format("Source %s changed while baking", source.Name)
		)
		assert(
			source.Transparency == sourceState.transparency
				and source.LocalTransparencyModifier == sourceState.localTransparencyModifier,
			string.format("Source %s visibility changed while baking", source.Name)
		)
		assert(
			source.Color == sourceState.color and source.Reflectance == sourceState.reflectance,
			string.format("Source %s appearance changed while baking", source.Name)
		)
		assert(
			source.Material == sourceState.material and source.MaterialVariant == sourceState.materialVariant,
			string.format("Source %s material changed while baking", source.Name)
		)
		assert(
			source.Anchored == sourceState.anchored,
			string.format("Source %s anchoring changed while baking", source.Name)
		)
		assert(
			source.CollisionGroup == sourceState.collisionGroup
				and source.CustomPhysicalProperties == sourceState.customPhysicalProperties,
			string.format("Source %s collision properties changed while baking", source.Name)
		)
		assert(
			source.CanCollide == sourceState.canCollide
				and source.CanTouch == sourceState.canTouch
				and source.CanQuery == sourceState.canQuery,
			string.format("Source %s collision or interaction flags changed while baking", source.Name)
		)
		assert(
			source.Massless == sourceState.massless and source.CastShadow == sourceState.castShadow,
			string.format("Source %s physics or rendering properties changed while baking", source.Name)
		)
		assert(
			dictionariesMatch(source:GetAttributes(), sourceState.attributes),
			string.format("Source %s attributes changed while baking", source.Name)
		)
		assert(
			dictionariesMatch(getTagSet(source), sourceState.tags),
			string.format("Source %s tags changed while baking", source.Name)
		)
		if source:IsA("MeshPart") then
			assert(
				source.MeshContent == sourceState.meshContent
					and source.TextureContent == sourceState.textureContent
					and source.DoubleSided == sourceState.doubleSided,
				string.format("Source %s mesh or texture changed while baking", source.Name)
			)
			assert(
				source.CollisionFidelity == sourceState.meshCollisionFidelity
					and source.CollisionPrecision == sourceState.collisionPrecision
					and source.RenderFidelity == sourceState.meshRenderFidelity,
				string.format("Source %s mesh fidelity changed while baking", source.Name)
			)
		elseif source:IsA("Part") then
			assert(
				source.Shape == sourceState.shape,
				string.format("Source %s shape changed while baking", source.Name)
			)
		elseif source:IsA("UnionOperation") then
			assert(
				source.CollisionFidelity == sourceState.collisionFidelity
					and source.RenderFidelity == sourceState.renderFidelity
					and source.FluidFidelity == sourceState.fluidFidelity,
				string.format("Source %s union fidelity changed while baking", source.Name)
			)
		end
	end
	local roots = snapshot.roots
	local meshPartSet = {}
	for _, meshPart in meshParts do
		meshPartSet[meshPart] = true
	end
	local reverseAssignments = {}
	for _, source in snapshot.geometry do
		local identity = snapshot.sourceIdentity[source]
		local assigned = getSourceTargets(source, sourceAssignments, identity)
		local seenTargets = {}
		for _, target in assigned do
			assert(
				meshPartSet[target],
				string.format("Source %s maps to geometry outside the uploaded output", source.Name)
			)
			assert(
				not seenTargets[target],
				string.format("Source %s has a duplicate output geometry assignment", source.Name)
			)
			seenTargets[target] = true
			local names = reverseAssignments[target] or {}
			names[identity] = true
			reverseAssignments[target] = names
		end
	end
	for meshPart in meshPartSet do
		local sourceNames = meshPartSources[meshPart]
		assert(sourceNames and #sourceNames > 0, "An uploaded MeshPart has no source identity")
		local seenSources = {}
		for _, sourceName in sourceNames do
			assert(
				snapshot.identitySources[sourceName],
				string.format("Uploaded geometry references unknown source %s", sourceName)
			)
			assert(
				not seenSources[sourceName],
				string.format("Uploaded geometry repeats source identity %s", sourceName)
			)
			assert(
				reverseAssignments[meshPart] and reverseAssignments[meshPart][sourceName],
				string.format("Uploaded geometry has an inconsistent source assignment for %s", sourceName)
			)
			seenSources[sourceName] = true
		end
		for sourceName in reverseAssignments[meshPart] or {} do
			assert(
				seenSources[sourceName],
				string.format("Source assignment for %s is missing from uploaded geometry metadata", sourceName)
			)
		end
	end
	for meshPart in meshPartSources do
		assert(meshPartSet[meshPart], "Source metadata references geometry outside the uploaded output")
	end
	local commonParent = #roots == 1 and roots[1].Parent or getLowestCommonAncestor(roots)
	assert(commonParent and commonParent ~= game, "Selected instances must share a container beneath the DataModel")
	local targetPivot
	if #roots == 1 then
		local root = roots[1]
		if root:IsA("Model") then
			targetPivot = root:GetPivot()
		elseif root:IsA("BasePart") then
			targetPivot = root.CFrame
		end
	end
	local outputModel = Instance.new("Model")
	outputModel.Name = #roots == 1 and roots[1].Name or "CombinedGeometry"
	local replacementState = captureReplacementState(snapshot, models, meshParts)
	table.insert(replacementState.created, outputModel)
	local succeeded, result = pcall(function()
		for _, model in models do
			for _, descendant in model:GetDescendants() do
				if descendant:IsA("MeshPart") and meshPartSet[descendant] then
					descendant.Parent = outputModel
				end
			end
			model.Parent = nil
		end
		for _, meshPart in meshParts do
			meshPart.Anchored = true
			if meshPart:GetAttribute("SurfaceOverlay") then
				meshPart.CollisionFidelity = Enum.CollisionFidelity.Box
				meshPart.CanCollide = false
				meshPart.CanTouch = false
				meshPart.CanQuery = false
			else
				meshPart.CollisionFidelity = Enum.CollisionFidelity.Tunable
				meshPart.CollisionPrecision = 1
				assert(
					meshPart.CollisionPrecision == 1,
					string.format("Could not set collision precision to 1 for %s", meshPart.Name)
				)
			end
		end
		outputModel.Parent = commonParent
		if targetPivot then
			outputModel.WorldPivot = targetPivot
		else
			local boundsCFrame = outputModel:GetBoundingBox()
			outputModel.WorldPivot = CFrame.new(boundsCFrame.Position)
		end
		for _, root in roots do
			root.Parent = nil
		end
		return #meshParts
	end)
	if not succeeded then
		local restored, restoreError = pcall(restoreReplacementState, replacementState)
		if not restored then
			error(
				string.format(
					"Replacement failed: %s. Rollback also failed: %s",
					tostring(result),
					tostring(restoreError)
				)
			)
		end
		error(result)
	end
	return result, outputModel, replacementState
end

local function getFirstProcessingError(response)
	for _, errors in
		{
			response.sourceErrors or {},
			response.textureErrors or {},
			response.overlayErrors or {},
		}
	do
		if #errors > 0 then
			return string.format("%s: %s", errors[1].name, errors[1].error)
		end
	end
	return nil
end

local function showPreview(models)
	local output = Instance.new("Model")
	local selectedRoot = pendingSelection and #pendingSelection.roots == 1 and pendingSelection.roots[1]
	output.Name = selectedRoot and selectedRoot.Name or "CombinedGeometry"
	for _, sourceModel in models do
		for _, descendant in sourceModel:GetChildren() do
			if descendant:IsA("MeshPart") then
				descendant.Parent = output
			end
		end
		sourceModel:Destroy()
	end
	local boundsCFrame = output:GetBoundingBox()
	local targetPivot
	if pendingSelection and #pendingSelection.roots == 1 then
		local root = pendingSelection.roots[1]
		if root:IsA("Model") then
			targetPivot = root:GetPivot()
		elseif root:IsA("BasePart") then
			targetPivot = root.CFrame
		end
	end
	output.WorldPivot = targetPivot or CFrame.new(boundsCFrame.Position)
	output.Parent = Workspace
	return output
end

local function onMessage(message)
	print(string.format("[PA Combine] received worker message (%d bytes)", #message))
	local decodeStarted = os.clock()
	local ok, response = pcall(HttpService.JSONDecode, HttpService, message)
	if not ok then
		setStatus("Worker returned an invalid response: " .. tostring(response), colors.bad)
		return
	end
	print(string.format("[PA Combine] decoded worker message in %.3f seconds", os.clock() - decodeStarted))
	if response.id ~= pendingRequest then
		return
	end
	if response.event == "progress" then
		local sequence = response.sequence
		local stageOrder = progressStages[response.stage]
		if
			requestState.state ~= "processing"
			or type(sequence) ~= "number"
			or sequence <= requestState.lastSequence
			or not stageOrder
			or stageOrder < requestState.stageOrder
		then
			return
		end
		requestState.lastSequence = sequence
		requestState.stageOrder = stageOrder
		requestState.progress = math.max(requestState.progress, math.clamp(response.progress or 0, 0, 1))
		requestState.stage = response.stage
		progressFill.Size = UDim2.fromScale(requestState.progress, 1)
		setStatus(response.message or response.stage or "Processing...")
		return
	end
	local responseState = response.ok and "response_received"
		or (requestState.state == "cancelling" and "cancelled" or "failed")
	if not transitionRequest(responseState) then
		return
	end
	cancelButton.Visible = false
	cancelButton.Active = true
	cancelButton.Text = "Cancel Bake"
	if response.textureImages then
		local sourceTextures = {}
		for _, texture in response.textureImages do
			sourceTextures[texture.page] = true
		end
		local sourceTextureCount = 0
		for _ in sourceTextures do
			sourceTextureCount += 1
		end
		local mapAssetCount = #(response.textureAssets or {})
		local tileCount = #(response.textureBindings or {})
		local textureErrors = response.textureErrors or {}
		for _, issue in textureErrors do
			warn(string.format("[PA Combine] texture error: %s [%s]: %s", issue.name, issue.slot, issue.error))
		end
	end
	for _, issue in response.sourceErrors or {} do
		warn(string.format("[PA Combine] source error: %s: %s", issue.name, issue.error))
	end
	for _, issue in response.overlayErrors or {} do
		warn(string.format("[PA Combine] overlay error: %s: %s", issue.name, issue.error))
	end
	if response.mergedVertexCount then
		selectionStats.Text = string.format(
			"Merged %d MeshParts · %d unions · %d primitives · %d vertices · %d triangles",
			response.meshCount or 0,
			response.unionCount or 0,
			response.primitiveCount or 0,
			response.mergedVertexCount,
			response.mergedTriangleCount or 0
		)
	end
	if response.ok then
		local assetIds = response.assetIds or (response.assetId and { response.assetId }) or {}
		local geometryAssets = response.geometryAssets or {}
		print(
			string.format(
				"[PA Combine] worker response contains %d geometry asset(s), ok=%s",
				#geometryAssets,
				tostring(response.ok)
			)
		)
		local outputAssetCount = #geometryAssets > 0 and #geometryAssets or #assetIds
		if outputAssetCount > 0 then
			local failure = response.error or getFirstProcessingError(response)
			if #geometryAssets > 0 then
				print("[PA Combine] beginning Studio geometry upload")
				transitionRequest("studio_upload")
				setStatus("Uploading geometry assets in Studio...")
			end
			local loaded, models, meshParts, sourceAssignments, meshPartSources
			if #geometryAssets > 0 then
				loaded, models, meshParts, sourceAssignments, meshPartSources = pcall(
					loadGeometryOutput,
					geometryAssets,
					response.assetMaterials,
					response.assetSources,
					response.textureAssets
				)
			else
				loaded, models, meshParts, sourceAssignments, meshPartSources =
					pcall(loadOutput, assetIds, response.assetMaterials, response.assetSources, response.textureAssets)
			end
			if not loaded then
				finishRequest(
					"failed",
					string.format(
						"Uploaded %d asset(s) but could not load them: %s",
						outputAssetCount,
						tostring(models)
					),
					colors.bad
				)
				return
			end
			if failure then
				showPreview(models)
				finishRequest(
					"failed",
					string.format(
						"Loaded %d uploaded asset(s) into Workspace.PA Combine Output. Replacement was skipped: %s",
						outputAssetCount,
						failure
					),
					colors.bad
				)
				return
			end
			local recordingService = game:GetService("ChangeHistoryService")
			local recordingId = string.format("PACombineBake_%d", pendingRequest)
			local recordingStarted, recording =
				pcall(recordingService.TryBeginRecording, recordingService, recordingId, "Bake selected geometry")
			if not recordingStarted or not recording then
				showPreview(models)
				finishRequest(
					"failed",
					"Studio could not begin an undo recording"
						.. (recordingStarted and "." or ": " .. tostring(recording)),
					colors.bad
				)
				return
			end
			transitionRequest("replacing")
			local replaced, meshPartCount, finalModel, replacementState = pcall(function()
				local count, output, state =
					replaceSelection(pendingSelection, models, meshParts, sourceAssignments, meshPartSources)
				return count, output, state
			end)
			local finishCallSucceeded, finishError = pcall(function()
				recordingService:FinishRecording(
					recording,
					replaced and Enum.FinishRecordingOperation.Commit or Enum.FinishRecordingOperation.Cancel
				)
			end)
			if not finishCallSucceeded then
				finishError = tostring(finishError)
			end
			if not finishCallSucceeded and replaced then
				local restored, restoreError = pcall(restoreReplacementState, replacementState)
				if not restored then
					finishError = tostring(finishError or "Studio rejected the recording operation")
						.. "; replacement rollback failed: "
						.. tostring(restoreError)
				end
			end
			if not replaced then
				for _, model in models do
					model.Parent = nil
				end
				local detail = string.format(
					"Phase: replaceSelection\nRecording ID: %s\nReplacement error:\n%s\nFinishRecording call succeeded: %s\nFinishRecording error: %s",
					recordingId,
					tostring(meshPartCount),
					tostring(finishCallSucceeded),
					tostring(finishError)
				)
				setErrorDetails(detail)
				finishRequest(
					"failed",
					"Replacement failed before completion. Full error details are shown below.",
					colors.bad
				)
				return
			end
			if not finishCallSucceeded then
				local detail = string.format(
					"Phase: FinishRecording %s\nRecording ID: %s\nReplacement completed: %s\nFinishRecording call succeeded: %s\nStudio error:\n%s",
					replaced and "commit" or "cancel",
					recordingId,
					tostring(replaced),
					tostring(finishCallSucceeded),
					tostring(finishError)
				)
				setErrorDetails(detail)
				finishRequest(
					"failed",
					"Studio could not finalize the replacement undo recording. Full diagnostic details are shown below.",
					colors.bad
				)
				return
			end
			Selection:Set({ finalModel })
			finishRequest(
				"complete",
				string.format(
					"Baked %d MeshParts from %d uploaded asset(s). Use Studio Undo to restore the original selection.",
					meshPartCount,
					outputAssetCount
				),
				colors.ok
			)
			return
		end
		local processingError = getFirstProcessingError(response)
		if processingError then
			finishRequest(
				"failed",
				string.format(
					"%s First issue: %s",
					response.message or "Geometry processing was incomplete.",
					processingError
				),
				colors.bad
			)
		else
			finishRequest(
				"complete",
				response.glbPath
						and string.format(
							"%s GLB: %s (%d bytes)",
							response.message or "Geometry generated.",
							response.glbPath,
							response.glbBytes or 0
						)
					or response.message
					or "Worker request completed.",
				colors.ok
			)
		end
	else
		local assetIds = response.assetIds or (response.assetId and { response.assetId }) or {}
		if requestState.state == "cancelled" then
			finishRequest("cancelled", response.error or "Bake cancelled.", colors.warn)
		elseif #assetIds > 0 then
			local loaded, models =
				pcall(loadOutput, assetIds, response.assetMaterials, response.assetSources, response.textureAssets)
			if loaded then
				showPreview(models)
				finishRequest(
					"failed",
					string.format(
						"Bake stopped after uploading %d geometry asset(s). Partial output is in Workspace.PA Combine Output; the original selection was not changed. %s",
						#assetIds,
						response.error or "The worker did not complete the full output."
					),
					colors.bad
				)
			else
				finishRequest(
					"failed",
					string.format(
						"Bake stopped after uploading %d geometry asset(s), but the partial preview could not be loaded: %s",
						#assetIds,
						tostring(models)
					),
					colors.bad
				)
			end
		else
			local processingError = getFirstProcessingError(response)
			finishRequest(
				"failed",
				(response.error or "Worker request failed.")
					.. (processingError and " First issue: " .. processingError or ""),
				colors.bad
			)
		end
	end
end

local function connectWorker()
	closeClient()
	setStatus("Connecting to local Combine worker...")
	local ok, created = pcall(function()
		return HttpService:CreateWebStreamClient(Enum.WebStreamClientType.WebSocket, { Url = workerUrl })
	end)
	if not ok then
		setStatus("Could not connect: " .. tostring(created), colors.bad)
		return
	end
	client = created
	created.Opened:Connect(function()
		connected = true
		connectButton.Text = "Disconnect Worker"
		setStatus("Connected to Combine worker.", colors.ok)
	end)
	created.MessageReceived:Connect(onMessage)
	created.Closed:Connect(function()
		if client == created then
			client = nil
			connected = false
			pendingRequest = nil
			pendingSelection = nil
			requestState = nil
			progressFill.Size = UDim2.fromScale(0, 1)
			cancelButton.Visible = false
			cancelButton.Active = true
			cancelButton.Text = "Cancel Bake"
			connectButton.Text = "Connect Worker"
			setStatus("Worker disconnected.")
		end
	end)
	created.Error:Connect(function(message)
		if client == created then
			client = nil
			connected = false
			pendingRequest = nil
			pendingSelection = nil
			requestState = nil
			progressFill.Size = UDim2.fromScale(0, 1)
			cancelButton.Visible = false
			cancelButton.Active = true
			cancelButton.Text = "Cancel Bake"
			connectButton.Text = "Connect Worker"
			setStatus("Worker connection error: " .. tostring(message), colors.bad)
		end
	end)
end

local function sendRequest(payload)
	if pendingRequest then
		setStatus("A Combine request is already running.", colors.bad)
		return
	end
	if not connected or not client then
		setStatus("Connect the Combine worker first.", colors.bad)
		return
	end
	requestId += 1
	payload.id = requestId
	pendingRequest = requestId
	requestState = {
		id = requestId,
		state = "processing",
		lastSequence = 0,
		stageOrder = 0,
		progress = 0.08,
	}
	cancelButton.Visible = payload.type == "geometry"
	cancelButton.Active = true
	cancelButton.Text = "Cancel Bake"
	progressFill.Size = UDim2.fromScale(0.08, 1)
	local ok, err = pcall(function()
		client:Send(HttpService:JSONEncode(payload))
	end)
	if not ok then
		pendingRequest = nil
		pendingSelection = nil
		cancelButton.Visible = false
		cancelButton.Active = true
		cancelButton.Text = "Cancel Bake"
		progressFill.Size = UDim2.fromScale(0, 1)
		setStatus("Could not send request: " .. tostring(err), colors.bad)
	end
end

local function getContentUri(content)
	if type(content) == "string" then
		return content ~= "" and content or nil
	end
	local ok, uri = pcall(function()
		if content.SourceType == Enum.ContentSourceType.Uri then
			return content.Uri
		end
		return nil
	end)
	if ok and type(uri) == "string" and uri ~= "" then
		return uri
	end
	return nil
end

local function getPartEmissiveProperties(part)
	local source = part:FindFirstChildOfClass("SurfaceAppearance")
	if source then
		if not getContentUri(source.EmissiveMaskContent) then
			return nil, nil
		end
	elseif part:IsA("BasePart") and part.MaterialVariant ~= "" then
		local variant = MaterialService:GetMaterialVariant(part.Material, part.MaterialVariant)
		if variant and getContentUri(variant.EmissiveMaskContent) then
			source = variant
		end
	end
	if not source then
		return nil, nil
	end
	local ok, tint, strength = pcall(function()
		return source.EmissiveTint, source.EmissiveStrength
	end)
	if not ok or typeof(tint) ~= "Color3" then
		return nil, nil
	end
	return { tint.R, tint.G, tint.B }, strength
end

local function extractSurfaceOverlays(selected, sourceIdentity, sourceAssemblyIdentity)
	local overlays = {}
	local seenInstances = {}
	for _, rootInstance in selected do
		local candidates = { rootInstance }
		for _, descendant in rootInstance:GetDescendants() do
			table.insert(candidates, descendant)
		end
		for _, instance in candidates do
			if not seenInstances[instance] then
				seenInstances[instance] = true
				if instance:IsA("Decal") or instance:IsA("Texture") then
					local owner = instance.Parent
					if owner and owner:IsA("BasePart") and sourceIdentity[owner] then
						local uri = getContentUri(instance.ColorMapContent) or getContentUri(instance.Texture)
						local emissiveUri = getContentUri(instance.EmissiveMaskContent)
						if uri then
							local studsPerTile
							local offset = { 0, 0 }
							if instance:IsA("Texture") then
								studsPerTile = { instance.StudsPerTileU, instance.StudsPerTileV }
								offset = { instance.OffsetStudsU, instance.OffsetStudsV }
							elseif instance.Face.Name == "Right" or instance.Face.Name == "Left" then
								studsPerTile = { owner.Size.Z, owner.Size.Y }
							elseif instance.Face.Name == "Top" or instance.Face.Name == "Bottom" then
								studsPerTile = { owner.Size.X, owner.Size.Z }
							else
								studsPerTile = { owner.Size.X, owner.Size.Y }
							end
							local color = instance.Color3
							local localTransparencyModifier = 0
							pcall(function()
								localTransparencyModifier = instance.LocalTransparencyModifier
							end)
							table.insert(overlays, {
								name = string.format("%s.%s#%d", sourceIdentity[owner], instance.Name, #overlays + 1),
								ownerName = sourceIdentity[owner],
								assemblyId = sourceAssemblyIdentity[owner] or "anchored",
								className = instance.ClassName,
								uri = uri,
								metalnessUri = getContentUri(instance.MetalnessMapContent),
								normalUri = getContentUri(instance.NormalMapContent),
								roughnessUri = getContentUri(instance.RoughnessMapContent),
								emissiveUri = emissiveUri,
								emissiveTint = emissiveUri
									and (function()
										local ok, tint = pcall(function()
											return instance.EmissiveTint
										end)
										return ok and typeof(tint) == "Color3" and { tint.R, tint.G, tint.B } or nil
									end)(),
								emissiveStrength = emissiveUri and (function()
									local ok, strength = pcall(function()
										return instance.EmissiveStrength
									end)
									return ok and strength or nil
								end)(),
								face = instance.Face.Name,
								transparency = 1 - ((1 - instance.Transparency) * (1 - localTransparencyModifier)),
								ownerOpaque = owner.Transparency == 0 and owner.LocalTransparencyModifier == 0,
								baseColor = { owner.Color.R, owner.Color.G, owner.Color.B },
								color = { color.R, color.G, color.B },
								studsPerTile = studsPerTile,
								offset = offset,
								rotation = instance.Rotation,
								size = { owner.Size.X, owner.Size.Y, owner.Size.Z },
								transform = { owner.CFrame:GetComponents() },
								zIndex = instance.ZIndex,
								order = #overlays,
							})
						end
					end
				end
			end
		end
	end
	table.sort(overlays, function(a, b)
		if a.zIndex == b.zIndex then
			return a.order < b.order
		end
		return a.zIndex < b.zIndex
	end)
	for index, overlay in overlays do
		overlay.layer = index - 1
	end
	return overlays
end

local function extractTextureInputs(selected, sourceIdentity)
	local inputs = {}
	local seen = {}
	local function applyAppearanceMetadata(input, owner, appearanceSource)
		local ok, alphaMode, surfaceColor, resampleMode = pcall(function()
			return appearanceSource.AlphaMode.Name,
				appearanceSource:IsA("SurfaceAppearance") and appearanceSource.Color or nil,
				appearanceSource:IsA("SurfaceAppearance") and appearanceSource.ResampleMode.Name or nil
		end)
		if not ok then
			alphaMode = appearanceSource:IsA("MaterialVariant") and "Opaque" or "Overlay"
			surfaceColor = appearanceSource:IsA("SurfaceAppearance") and appearanceSource.Color or nil
			resampleMode = appearanceSource:IsA("SurfaceAppearance") and appearanceSource.ResampleMode.Name or nil
		end
		input.resampleMode = resampleMode
		if input.slot ~= "color" then
			return
		end
		input.alphaMode = alphaMode
		local partColor = owner.Color
		local tint = surfaceColor
			or (
				appearanceSource:IsA("MaterialVariant")
					and alphaMode ~= "Opaque"
					and alphaMode ~= "Overlay"
					and partColor
				or nil
			)
		input.surfaceColor = tint and { tint.R, tint.G, tint.B } or nil
		input.baseColor = { partColor.R, partColor.G, partColor.B }
		input.partColorBaked = appearanceSource:IsA("MaterialVariant") and alphaMode ~= "Opaque"
	end
	local function add(owner, slot, content, appearanceSource)
		local uri = getContentUri(content)
		if uri then
			local name = sourceIdentity[owner] or owner:GetFullName()
			local key = name .. ":" .. slot .. ":" .. uri
			local input = seen[key]
			if input then
				if appearanceSource then
					applyAppearanceMetadata(input, owner, appearanceSource)
				end
			else
				input = { name = name, slot = slot, uri = uri }
				if appearanceSource then
					applyAppearanceMetadata(input, owner, appearanceSource)
				end
				seen[key] = input
				table.insert(inputs, input)
			end
		end
	end
	for _, rootInstance in selected do
		local candidates = { rootInstance }
		for _, descendant in rootInstance:GetDescendants() do
			table.insert(candidates, descendant)
		end
		for _, instance in candidates do
			if instance:IsA("BasePart") and sourceIdentity[instance] then
				local appearance = instance:FindFirstChildOfClass("SurfaceAppearance")
				if appearance then
					add(instance, "color", appearance.ColorMapContent, appearance)
					add(instance, "metalness", appearance.MetalnessMapContent, appearance)
					add(instance, "normal", appearance.NormalMapContent, appearance)
					add(instance, "roughness", appearance.RoughnessMapContent, appearance)
					add(instance, "emissive", appearance.EmissiveMaskContent, appearance)
				else
					local meshTexture = instance:IsA("MeshPart") and getContentUri(instance.TextureContent)
					if meshTexture then
						add(instance, "color", instance.TextureContent)
					end
					if instance.MaterialVariant ~= "" then
						local variant = MaterialService:GetMaterialVariant(instance.Material, instance.MaterialVariant)
						if variant and variant:IsA("MaterialVariant") then
							if not meshTexture then
								add(instance, "color", variant.ColorMapContent, variant)
							end
							for _, slot in { "metalness", "normal", "roughness", "emissive" } do
								local property = slot == "emissive" and "EmissiveMaskContent"
									or string.upper(string.sub(slot, 1, 1)) .. string.sub(slot, 2) .. "MapContent"
								add(instance, slot, variant[property], variant)
							end
						end
					end
				end
			end
		end
	end
	return inputs
end

local function extractPrimitive(part, identity, assemblyId)
	local emissiveTint, emissiveStrength = getPartEmissiveProperties(part)
	local shape
	if part:IsA("WedgePart") then
		shape = "wedge"
	elseif part:IsA("CornerWedgePart") then
		shape = "cornerWedge"
	elseif part:IsA("Part") then
		shape = part.Shape == Enum.PartType.CornerWedge and "cornerWedge" or part.Shape.Name:lower()
	else
		error("Unsupported primitive class: " .. part.ClassName)
	end
	return {
		name = identity,
		assemblyId = assemblyId,
		castShadow = part.CastShadow,
		shape = shape,
		material = part.Material.Name,
		materialVariant = part.MaterialVariant,
		color = { part.Color.R, part.Color.G, part.Color.B },
		transparency = part.Transparency,
		localTransparencyModifier = part.LocalTransparencyModifier,
		reflectance = part.Reflectance,
		size = { part.Size.X, part.Size.Y, part.Size.Z },
		transform = { part.CFrame:GetComponents() },
		emissiveTint = emissiveTint,
		emissiveStrength = emissiveStrength,
	}
end

local function extractMeshPart(meshPart, identity, assemblyId)
	local editableMesh = AssetService:CreateEditableMeshAsync(meshPart.MeshContent, {
		FixedSize = false,
	})
	if not editableMesh then
		error("Roblox could not create an EditableMesh for " .. meshPart:GetFullName())
	end
	local ok, result = pcall(function()
		editableMesh:Triangulate()
		local positions = {}
		local normals = {}
		local uvs = {}
		local colors = {}
		for _, faceId in editableMesh:GetFaces() do
			local vertexIds = editableMesh:GetFaceVertices(faceId)
			local normalIds = editableMesh:GetFaceNormals(faceId)
			local uvIds = editableMesh:GetFaceUVs(faceId)
			local colorIds = editableMesh:GetFaceColors(faceId)
			if #vertexIds ~= 3 or #normalIds ~= 3 or #uvIds ~= 3 or #colorIds ~= 3 then
				error("MeshPart contains a face with incomplete corner attributes.")
			end
			for corner = 1, 3 do
				local position = editableMesh:GetPosition(vertexIds[corner])
				local normal = editableMesh:GetNormal(normalIds[corner])
				local uv = editableMesh:GetUV(uvIds[corner])
				local colorId = colorIds[corner]
				local color = editableMesh:GetColor(colorId)
				table.insert(positions, { position.X, position.Y, position.Z })
				table.insert(normals, { normal.X, normal.Y, normal.Z })
				table.insert(uvs, { uv.X, uv.Y })
				table.insert(colors, {
					color.R,
					color.G,
					color.B,
					editableMesh:GetColorAlpha(colorId),
				})
			end
		end
		local components = { meshPart.CFrame:GetComponents() }
		local emissiveTint, emissiveStrength = getPartEmissiveProperties(meshPart)
		local meshSize = meshPart.MeshSize
		local size = meshPart.Size
		return {
			name = identity,
			assemblyId = assemblyId,
			castShadow = meshPart.CastShadow,
			positions = positions,
			normals = normals,
			uvs = uvs,
			colors = colors,
			transform = components,
			scale = {
				if meshSize.X == 0 then 1 else size.X / meshSize.X,
				if meshSize.Y == 0 then 1 else size.Y / meshSize.Y,
				if meshSize.Z == 0 then 1 else size.Z / meshSize.Z,
			},
			doubleSided = meshPart.DoubleSided,
			material = meshPart.Material.Name,
			materialVariant = meshPart.MaterialVariant,
			color = { meshPart.Color.R, meshPart.Color.G, meshPart.Color.B },
			transparency = meshPart.Transparency,
			localTransparencyModifier = meshPart.LocalTransparencyModifier,
			reflectance = meshPart.Reflectance,
			emissiveTint = emissiveTint,
			emissiveStrength = emissiveStrength,
		}
	end)
	editableMesh:Destroy()
	if not ok then
		error(string.format("Could not extract MeshPart %s: %s", meshPart:GetFullName(), tostring(result)))
	end
	return result
end

local function extractUnion(union)
	local ok, result = pcall(function()
		local serialized = SerializationService:SerializeInstancesAsync({ union })
		assert(
			typeof(serialized) == "buffer",
			string.format("SerializationService returned %s instead of a buffer", typeof(serialized))
		)
		local serializedLength = buffer.len(serialized)
		assert(serializedLength > 0, "SerializationService returned an empty buffer")
		local encoded = EncodingService:Base64Encode(serialized)
		assert(
			typeof(encoded) == "buffer",
			string.format("EncodingService returned %s instead of a buffer", typeof(encoded))
		)
		local encodedString = buffer.tostring(encoded)
		assert(#encodedString > 0, "Base64 encoding returned an empty string")
		return {
			serializedUnion = encodedString,
			serializedBytes = serializedLength,
			encodedBytes = #encodedString,
			transform = { union.CFrame:GetComponents() },
			size = { union.Size.X, union.Size.Y, union.Size.Z },
		}
	end)
	if not ok then
		error(string.format("Could not serialize union %s: %s", union:GetFullName(), tostring(result)))
	end
	return result
end

cancelButton.Activated:Connect(function()
	if not pendingRequest or not connected or not client then
		return
	end
	cancelButton.Active = false
	cancelButton.Text = "Cancelling..."
	setStatus("Cancellation requested. The worker will stop at the next processing boundary.")
	local ok, err = pcall(function()
		client:Send(HttpService:JSONEncode({
			id = pendingRequest,
			type = "cancel",
		}))
	end)
	if not ok then
		cancelButton.Active = true
		cancelButton.Text = "Retry Cancel"
		setStatus("Could not send cancellation request: " .. tostring(err), colors.bad)
	else
		transitionRequest("cancelling")
	end
end)

refreshButton.Activated:Connect(countSelection)

connectButton.Activated:Connect(function()
	if connected then
		closeClient()
		setStatus("Worker disconnected.")
	else
		connectWorker()
	end
end)

inspectButton.Activated:Connect(function()
	if pendingRequest then
		setStatus("A Combine request is already running.", colors.bad)
		return
	end
	local selected, geometry, descendants = countSelection()
	if #selected == 0 then
		setStatus("Select one or more instances first.", colors.bad)
		return
	end
	local unions = {}
	local meshParts = {}
	local primitives = {}
	local geometrySources = {}
	local unsupportedGeometry = {}
	local sourceIdentity = {}
	local sourceAssemblyIdentity = {}
	local sourceAssemblyAnchored = {}
	local assemblyIdentities = {}
	local identityIndex = 0
	local assemblyIdentityIndex = 0
	local seenCandidates = {}
	for _, instance in selected do
		local candidates = { instance }
		for _, descendant in instance:GetDescendants() do
			table.insert(candidates, descendant)
		end
		for _, candidate in candidates do
			if not seenCandidates[candidate] then
				seenCandidates[candidate] = true
				if candidate:IsA("BasePart") then
					identityIndex += 1
					sourceIdentity[candidate] = candidate:GetFullName() .. "#" .. tostring(identityIndex)
					local assemblyRoot = candidate.AssemblyRootPart or candidate
					sourceAssemblyAnchored[candidate] = assemblyRoot.Anchored
					if assemblyRoot.Anchored then
						sourceAssemblyIdentity[candidate] = "anchored"
					else
						if not assemblyIdentities[assemblyRoot] then
							assemblyIdentityIndex += 1
							assemblyIdentities[assemblyRoot] = "assembly#" .. tostring(assemblyIdentityIndex)
						end
						sourceAssemblyIdentity[candidate] = assemblyIdentities[assemblyRoot]
					end
				end
				local children = candidate:IsA("BasePart") and candidate:GetChildren() or {}
				local hasOnlyOverlayChildren = #children > 0
				local hasVisibleOverlay = false
				if candidate:IsA("BasePart") then
					for _, child in children do
						if not (child:IsA("Decal") or child:IsA("Texture")) then
							hasOnlyOverlayChildren = false
						elseif
							child.Transparency < 1
							and (getContentUri(child.ColorMapContent) or getContentUri(child.Texture))
						then
							hasVisibleOverlay = true
						end
					end
				end
				local excludedTransparentOverlay = candidate.Name == "PipeClimb"
					or candidate.Name == "PIPECLIMBPLACEHOLDER"
					or candidate.Name == "LadderClimb"
				local fullyTransparent = candidate:IsA("BasePart")
					and (candidate.Transparency >= 1 or candidate.LocalTransparencyModifier >= 1)
				local bakeTransparentOverlay = fullyTransparent
					and hasOnlyOverlayChildren
					and hasVisibleOverlay
					and not excludedTransparentOverlay
				if
					candidate:IsA("BasePart")
					and (
						(candidate.Transparency < 1 and candidate.LocalTransparencyModifier < 1)
						or bakeTransparentOverlay
					)
				then
					if candidate:IsA("UnionOperation") then
						table.insert(unions, candidate)
						table.insert(geometrySources, candidate)
					elseif candidate:IsA("MeshPart") then
						table.insert(meshParts, candidate)
						table.insert(geometrySources, candidate)
					elseif candidate:IsA("Part") or candidate:IsA("WedgePart") or candidate:IsA("CornerWedgePart") then
						table.insert(primitives, candidate)
						table.insert(geometrySources, candidate)
					else
						table.insert(unsupportedGeometry, candidate)
					end
				end
			end
		end
	end
	local geometryIdentity = {}
	for _, source in geometrySources do
		geometryIdentity[source] = sourceIdentity[source]
	end
	if #unsupportedGeometry > 0 then
		local unsupported = unsupportedGeometry[1]
		setStatus(
			string.format(
				"Unsupported BasePart class %s: %s. No geometry was replaced.",
				unsupported.ClassName,
				unsupported:GetFullName()
			),
			colors.bad
		)
		return
	end
	for _, source in geometrySources do
		local appearance = source:FindFirstChildOfClass("SurfaceAppearance")
		if appearance and getContentUri(appearance.TexturePackContent) then
			setStatus(
				string.format(
					"SurfaceAppearance texture packs are not supported yet: %s. No geometry was replaced.",
					source:GetFullName()
				),
				colors.bad
			)
			return
		end
	end
	if #meshParts > 0 or #unions > 0 or #primitives > 0 then
		local roots = normalizeSelection(selected)
		local sourceStates = {}
		for _, source in geometrySources do
			table.insert(sourceStates, {
				instance = source,
				parent = source.Parent,
				cframe = source.CFrame,
				assemblyLinearVelocity = source.AssemblyLinearVelocity,
				assemblyAngularVelocity = source.AssemblyAngularVelocity,
				size = source.Size,
				transparency = source.Transparency,
				localTransparencyModifier = source.LocalTransparencyModifier,
				color = source.Color,
				reflectance = source.Reflectance,
				material = source.Material,
				materialVariant = source.MaterialVariant,
				anchored = source.Anchored,
				collisionGroup = source.CollisionGroup,
				customPhysicalProperties = source.CustomPhysicalProperties,
				canCollide = source.CanCollide,
				canTouch = source.CanTouch,
				canQuery = source.CanQuery,
				massless = source.Massless,
				castShadow = source.CastShadow,
				attributes = source:GetAttributes(),
				tags = getTagSet(source),
				meshContent = source:IsA("MeshPart") and source.MeshContent or nil,
				textureContent = source:IsA("MeshPart") and source.TextureContent or nil,
				doubleSided = source:IsA("MeshPart") and source.DoubleSided,
				meshCollisionFidelity = source:IsA("MeshPart") and source.CollisionFidelity or nil,
				collisionPrecision = source:IsA("MeshPart") and source.CollisionPrecision or nil,
				meshRenderFidelity = source:IsA("MeshPart") and source.RenderFidelity or nil,
				shape = source:IsA("Part") and source.Shape or nil,
				collisionFidelity = source:IsA("UnionOperation") and source.CollisionFidelity or nil,
				renderFidelity = source:IsA("UnionOperation") and source.RenderFidelity or nil,
				fluidFidelity = source:IsA("UnionOperation") and source.FluidFidelity or nil,
			})
		end
		local appearanceStates = captureAppearanceStates(roots)
		local hierarchyStates = captureHierarchyStates(roots)
		local meshInputs = {}
		for index, meshPart in meshParts do
			setStatus(string.format("Extracting MeshPart %d of %d: %s", index, #meshParts, meshPart.Name))
			local ok, extracted =
				pcall(extractMeshPart, meshPart, sourceIdentity[meshPart], sourceAssemblyIdentity[meshPart])
			if not ok then
				setStatus(tostring(extracted), colors.bad)
				return
			end
			table.insert(meshInputs, extracted)
		end
		local primitiveInputs = {}
		for index, part in primitives do
			setStatus(string.format("Preparing primitive %d of %d: %s", index, #primitives, part.Name))
			local ok, extracted = pcall(extractPrimitive, part, sourceIdentity[part], sourceAssemblyIdentity[part])
			if not ok then
				setStatus(tostring(extracted), colors.bad)
				return
			end
			table.insert(primitiveInputs, extracted)
		end
		local unionInputs = {}
		for index, union in unions do
			setStatus(string.format("Serializing union %d of %d: %s", index, #unions, union.Name))
			local ok, extracted = pcall(extractUnion, union)
			if not ok then
				setStatus(tostring(extracted), colors.bad)
				return
			end
			local emissiveTint, emissiveStrength = getPartEmissiveProperties(union)
			table.insert(unionInputs, {
				name = sourceIdentity[union],
				assemblyId = sourceAssemblyIdentity[union],
				castShadow = union.CastShadow,
				serializedUnion = extracted.serializedUnion,
				serializedBytes = extracted.serializedBytes,
				encodedBytes = extracted.encodedBytes,
				transform = extracted.transform,
				size = extracted.size,
				overlayTransform = { union.CFrame:GetComponents() },
				material = union.Material.Name,
				materialVariant = union.MaterialVariant,
				color = { union.Color.R, union.Color.G, union.Color.B },
				transparency = union.Transparency,
				localTransparencyModifier = union.LocalTransparencyModifier,
				reflectance = union.Reflectance,
				emissiveTint = emissiveTint,
				emissiveStrength = emissiveStrength,
			})
		end
		local textureInputs = extractTextureInputs(selected, geometryIdentity)
		local surfaceOverlays = extractSurfaceOverlays(selected, geometryIdentity, sourceAssemblyIdentity)
		local texturedOwners = {}
		for _, input in textureInputs do
			if input.slot == "color" then
				texturedOwners[input.name] = true
			end
		end
		for _, overlay in surfaceOverlays do
			local composite = overlay.ownerOpaque and not texturedOwners[overlay.ownerName]
			table.insert(textureInputs, {
				name = overlay.name,
				slot = "color",
				uri = overlay.uri,
				tint = if composite then nil else overlay.color,
				transparency = overlay.transparency,
				alphaMode = if composite then "Overlay" elseif not overlay.ownerOpaque then "Transparency" else nil,
				surfaceColor = if composite then overlay.color else nil,
				baseColor = if composite then overlay.baseColor else nil,
			})
			for _, map in
				{
					{ slot = "metalness", uri = overlay.metalnessUri },
					{ slot = "normal", uri = overlay.normalUri },
					{ slot = "roughness", uri = overlay.roughnessUri },
					{ slot = "emissive", uri = overlay.emissiveUri },
				}
			do
				if map.uri then
					table.insert(textureInputs, {
						name = overlay.name,
						slot = map.slot,
						uri = map.uri,
					})
				end
			end
		end
		print(
			string.format(
				"[PA Combine] extracted %d MeshPart(s), %d union(s), %d primitive(s), %d texture input(s), and %d surface overlay(s)",
				#meshInputs,
				#unionInputs,
				#primitiveInputs,
				#textureInputs,
				#surfaceOverlays
			)
		)
		for _, input in unionInputs do
			print(
				string.format(
					"[PA Combine] union %s serialized to %d bytes (%d base64 bytes)",
					input.name,
					input.serializedBytes,
					input.encodedBytes
				)
			)
		end
		local identitySources = {}
		for source, identity in sourceIdentity do
			identitySources[identity] = source
		end
		pendingSelection = {
			roots = roots,
			identitySources = identitySources,
			sourceAssemblyAnchored = sourceAssemblyAnchored,
			appearanceStates = appearanceStates,
			hierarchyStates = hierarchyStates,
			geometry = geometrySources,
			sourceIdentity = sourceIdentity,
			sourceStates = sourceStates,
		}
		sendRequest({
			type = "geometry",
			meshInputs = meshInputs,
			unionInputs = unionInputs,
			primitiveInputs = primitiveInputs,
			textureInputs = textureInputs,
			surfaceOverlays = surfaceOverlays,
			creator = {
				kind = game.CreatorType.Name,
				id = tostring(game.CreatorId),
			},
			publish = true,
			maxTrianglesPerChunk = maxTrianglesPerChunk,
		})
		return
	end
	sendRequest({
		type = "inspect",
		selectionCount = #selected,
		geometryCount = geometry,
		descendantCount = descendants,
	})
end)

Selection.SelectionChanged:Connect(countSelection)

widget:GetPropertyChangedSignal("Enabled"):Connect(function()
	toggleButton:SetActive(widget.Enabled)
end)

toolbar.setButtonHandler("Combine", function()
	widget.Enabled = not widget.Enabled
	toggleButton:SetActive(widget.Enabled)
end)

plugin.Unloading:Connect(function()
	closeClient()
	toolbar.removeButtonHandler("Combine")
end)

countSelection()
toggleButton:SetActive(widget.Enabled)
