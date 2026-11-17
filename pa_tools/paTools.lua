local state = {
	toolbar = plugin:CreateToolbar("PA Tools"),
	buttons = {},
	buttonConnections = {},
}

shared.paToolsState = state

local ui = {}

ui.colors = {
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
	root = Color3.new(0.098039, 0.101961, 0.105882),
	card = Color3.new(0.086275, 0.090196, 0.105882),
	button = Color3.fromRGB(46, 47, 62),
}

local colors = ui.colors

function ui.create(className, properties, parent)
	local instance = Instance.new(className)
	for key, value in properties do
		instance[key] = value
	end
	instance.Parent = parent
	return instance
end

local create = ui.create

function ui.corner(parent, radius)
	return create("UICorner", { CornerRadius = UDim.new(0, radius or 8) }, parent)
end

function ui.stroke(parent, color, transparency)
	return create("UIStroke", {
		Color = color or colors.stroke,
		Transparency = transparency or 0.5,
		Thickness = 1,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, parent)
end

function ui.pad(parent, amount)
	return create("UIPadding", {
		PaddingTop = UDim.new(0, amount),
		PaddingBottom = UDim.new(0, amount),
		PaddingLeft = UDim.new(0, amount),
		PaddingRight = UDim.new(0, amount),
	}, parent)
end

function ui.stack(parent, spacing)
	return create("UIListLayout", {
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, spacing),
	}, parent)
end

function ui.escape(text)
	return (string.gsub(string.gsub(string.gsub(text, "&", "&amp;"), "<", "&lt;"), ">", "&gt;"))
end

function ui.page(widget)
	local root = create("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = colors.root,
		BorderSizePixel = 0,
	}, widget)
	local page = create("ScrollingFrame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = colors.stroke,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		ScrollingDirection = Enum.ScrollingDirection.Y,
	}, root)
	ui.pad(page, 10)
	ui.stack(page, 10)
	return root, page
end

function ui.card(parent, order)
	local card = create("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = colors.card,
		BackgroundTransparency = 0.2,
		BorderSizePixel = 0,
		LayoutOrder = order,
	}, parent)
	ui.corner(card, 10)
	ui.stroke(card, colors.stroke, 0.5)
	ui.pad(card, 10)
	ui.stack(card, 6)
	return card
end

function ui.floating(parent, size)
	local panel = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -20),
		Size = size,
		BackgroundColor3 = colors.card,
		BorderSizePixel = 0,
	}, parent)
	ui.corner(panel, 10)
	ui.stroke(panel, colors.stroke, 0.35)
	ui.pad(panel, 10)
	return panel
end

function ui.label(parent, text, order, color)
	return create("TextLabel", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Font = Enum.Font.Gotham,
		TextSize = 12,
		TextColor3 = color or colors.text,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Text = text,
		LayoutOrder = order,
	}, parent)
end

function ui.title(parent, text, order)
	return create("TextLabel", {
		Size = UDim2.new(1, 0, 0, 22),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		TextSize = 18,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = colors.text,
		Text = text,
		LayoutOrder = order,
	}, parent)
end

function ui.titleRow(parent, text, order)
	local row = create("Frame", {
		Size = UDim2.new(1, 0, 0, 22),
		BackgroundTransparency = 1,
		LayoutOrder = order,
	}, parent)
	local title = ui.title(row, text, 1)
	title.Size = UDim2.new(1, -20, 1, 0)
	local dot = create("Frame", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		Size = UDim2.fromOffset(10, 10),
		BackgroundColor3 = colors.bad,
		BorderSizePixel = 0,
	}, row)
	ui.corner(dot, 5)
	return row, title, dot
end

function ui.section(parent, title, order)
	local card = ui.card(parent, order)
	local label = create("TextLabel", {
		Size = UDim2.new(1, 0, 0, 14),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		TextSize = 11,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = colors.sub,
		Text = title,
		LayoutOrder = 0,
	}, card)
	return card, label
end

function ui.scroller(parent, height, order)
	local scroller = create("ScrollingFrame", {
		Size = UDim2.new(1, 0, 0, height),
		BackgroundColor3 = colors.panelDark,
		BackgroundTransparency = 0.4,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = colors.stroke,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		LayoutOrder = order or 1,
	}, parent)
	ui.corner(scroller, 8)
	ui.pad(scroller, 6)
	ui.stack(scroller, 4)
	return scroller
end

function ui.button(parent, text, order, callback, primary)
	local button = create("TextButton", {
		Size = UDim2.new(1, 0, 0, 32),
		BackgroundColor3 = if primary then colors.accentDark else colors.button,
		BorderSizePixel = 0,
		Font = Enum.Font.GothamBold,
		TextSize = 13,
		TextColor3 = if primary then Color3.new(1, 1, 1) else colors.text,
		Text = text,
		LayoutOrder = order,
	}, parent)
	ui.corner(button, 8)
	if callback then
		button.Activated:Connect(callback)
	end
	return button
end

function ui.input(parent, order, text, placeholder)
	local input = create("TextBox", {
		Size = UDim2.new(1, 0, 0, 32),
		BackgroundColor3 = colors.panelDark,
		BorderSizePixel = 0,
		Font = Enum.Font.Gotham,
		TextSize = 13,
		TextColor3 = colors.text,
		PlaceholderColor3 = colors.sub,
		PlaceholderText = placeholder or "",
		Text = text or "",
		ClearTextOnFocus = false,
		LayoutOrder = order,
	}, parent)
	ui.corner(input, 8)
	ui.stroke(input, colors.stroke, 0.5)
	return input
end

function ui.output(parent, order, color)
	local output = create("TextBox", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = colors.panelDark,
		BorderSizePixel = 0,
		Font = Enum.Font.Code,
		TextSize = 11,
		TextColor3 = color or colors.text,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		ClearTextOnFocus = false,
		MultiLine = true,
		TextEditable = false,
		LayoutOrder = order,
	}, parent)
	ui.pad(output, 8)
	ui.corner(output, 6)
	ui.stroke(output, colors.stroke, 0.5)
	return output
end

function ui.progress(parent, order)
	local bar = create("Frame", {
		Size = UDim2.new(1, 0, 0, 6),
		BackgroundColor3 = colors.panelDark,
		BorderSizePixel = 0,
		LayoutOrder = order,
	}, parent)
	ui.corner(bar, 3)
	local fill = create("Frame", {
		Size = UDim2.fromScale(0, 1),
		BackgroundColor3 = colors.accent,
		BorderSizePixel = 0,
	}, bar)
	ui.corner(fill, 3)
	return bar, fill
end

local api = {}

function api.addButton(id, tooltip, icon)
	local button = state.buttons[id]
	if not button then
		local buttonId = id
		local suffix = 1
		while true do
			local ok, created = pcall(function()
				return state.toolbar:CreateButton(buttonId, tooltip, icon)
			end)
			if ok then
				button = created
				break
			end
			if not string.find(tostring(created), "Cannot create more than one button with id", 1, true) then
				error(created)
			end
			suffix += 1
			buttonId = string.format("%s (%d)", id, suffix)
		end
		state.buttons[id] = button
	end
	button.ClickableWhenViewportHidden = true
	return button
end

function api.setButtonHandler(id, callback)
	local button = state.buttons[id]
	assert(button, string.format("PA Tools button %q has not been registered", id))
	local previous = state.buttonConnections[id]
	if previous then
		previous:Disconnect()
		state.buttonConnections[id] = nil
	end
	if callback then
		state.buttonConnections[id] = button.Click:Connect(callback)
	end
end

function api.removeButtonHandler(id)
	api.setButtonHandler(id, nil)
end

api.toolbar = state.toolbar
api.ui = ui
api.ready = true
shared.paTools = api

local toolbarCallbacks = shared.paToolbarCallbacks
if not toolbarCallbacks then
	toolbarCallbacks = {}
	shared.paToolbarCallbacks = toolbarCallbacks
end

for _, callback in toolbarCallbacks do
	local ok, err = pcall(callback)
	if not ok then
		warn("PA Tools could not restore a plugin toolbar: " .. tostring(err))
	end
end

plugin.Unloading:Connect(function()
	if shared.paTools == api then
		shared.paTools = nil
	end
end)
