local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local ScriptEditorService = game:GetService("ScriptEditorService")

local URL = "ws://127.0.0.1:34872"
local TICK = 0.1
local RETRY_INTERVAL = 2
local DEBOUNCE = 0.5
local OPEN_DELAY = 2
local VERIFY_DELAY = 0.3
local SETTLE_DELAY = 1.5
local SETTLE_QUICK = 0.4
local FRESH_WINDOW = 10
local LARGE_SOURCE = 150000
local CHUNK_BYTES = 90000
local OPEN_CONCURRENCY = 12
local CREATE_DEBOUNCE = 3
local CHANGE_DEBOUNCE = 1.5
local CHECK_INTERVAL = 1
local SEP = "\31"

local scripts = {}
local keyByScript = {}
local connections = {}
local attrDirty = {}
local attrConns = {}
local candidates = setmetatable({}, { __mode = "k" })
local rejected = setmetatable({}, { __mode = "k" })
local watched = {}
local changes = {}
local outbox = { created = {}, deleted = {}, moved = {}, missing = {}, refused = {} }
local resync = false
local openActive = 0
local nextCheck = 0
local lastReported = {}
local dirtyAt = {}
local applying = {}
local applyGen = {}
local openedAt = {}
local acks = {}
local sessionState = {}
local treeDirty = true
local showDetail

local client = nil
local connected = false
local commandQueue = {}
local resumeRequested = false
local paused = false
local syncIgnored = false
local playtestPaused = false

local widget = plugin:CreateDockWidgetPluginGuiAsync(
	"pSync",
	DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Right, true, false, 320, 110, 240, 90)
)
widget.Title = "pSync"

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
local RED = Color3.fromRGB(235, 100, 100)
local GREEN = Color3.fromRGB(110, 210, 140)
local YELLOW = Color3.fromRGB(235, 200, 80)
local GREY = Color3.fromRGB(140, 140, 150)
local TAGS = {
	VSC = Color3.fromRGB(58, 120, 220),
	RBX = Color3.fromRGB(200, 120, 40),
	ERR = Color3.fromRGB(190, 60, 60),
}
local STATE_COLORS = { added = GREEN, moved = YELLOW, deleted = RED }
local STATE_PRIORITY = { added = 1, moved = 2, deleted = 3 }

local function corner(parent, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = parent
end

local function stroke(parent, color, transparency)
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Transparency = transparency
	s.Thickness = 1
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = parent
end

local function pad(parent, amount)
	local p = Instance.new("UIPadding")
	p.PaddingTop = UDim.new(0, amount)
	p.PaddingBottom = UDim.new(0, amount)
	p.PaddingLeft = UDim.new(0, amount)
	p.PaddingRight = UDim.new(0, amount)
	p.Parent = parent
end

local function stack(parent, spacing)
	local l = Instance.new("UIListLayout")
	l.SortOrder = Enum.SortOrder.LayoutOrder
	l.Padding = UDim.new(0, spacing)
	l.Parent = parent
end

local function escape(text)
	return (string.gsub(string.gsub(string.gsub(text, "&", "&amp;"), "<", "&lt;"), ">", "&gt;"))
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
page.ScrollBarImageColor3 = COLORS.stroke
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
	stroke(card, COLORS.stroke, 0.5)
	pad(card, 10)
	stack(card, 6)
	return card
end

local header = makeCard(1)

local titleRow = Instance.new("Frame")
titleRow.Size = UDim2.new(1, 0, 0, 22)
titleRow.BackgroundTransparency = 1
titleRow.LayoutOrder = 1
titleRow.Parent = header

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -20, 1, 0)
title.BackgroundTransparency = 1
title.Font = Enum.Font.GothamBold
title.TextSize = 18
title.TextXAlignment = Enum.TextXAlignment.Left
title.TextColor3 = COLORS.text
title.Text = "pSync"
title.Parent = titleRow

local dot = Instance.new("Frame")
dot.AnchorPoint = Vector2.new(1, 0.5)
dot.Position = UDim2.new(1, 0, 0.5, 0)
dot.Size = UDim2.fromOffset(10, 10)
dot.BackgroundColor3 = COLORS.bad
dot.BorderSizePixel = 0
dot.Parent = titleRow
corner(dot, 5)

local status = Instance.new("TextLabel")
status.Size = UDim2.new(1, 0, 0, 0)
status.AutomaticSize = Enum.AutomaticSize.Y
status.BackgroundTransparency = 1
status.TextWrapped = true
status.Font = Enum.Font.Gotham
status.TextSize = 12
status.TextXAlignment = Enum.TextXAlignment.Left
status.TextYAlignment = Enum.TextYAlignment.Top
status.TextColor3 = COLORS.sub
status.Text = "Connecting..."
status.LayoutOrder = 2
status.Parent = header

local resume = Instance.new("TextButton")
resume.Size = UDim2.new(1, 0, 0, 32)
resume.BackgroundColor3 = Color3.new(0.066667, 0.058824, 0.058824)
resume.BorderSizePixel = 0
resume.Font = Enum.Font.GothamBold
resume.TextSize = 14
resume.TextColor3 = Color3.new(1, 1, 1)
resume.Text = "Resume"
resume.Visible = false
resume.LayoutOrder = 2
resume.Parent = page
corner(resume, 8)
resume.MouseButton1Click:Connect(function()
	resumeRequested = true
end)

local function makeSection(title, order)
	local card = makeCard(order)
	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 0, 14)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextSize = 11
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextColor3 = COLORS.sub
	label.Text = title
	label.LayoutOrder = 0
	label.Parent = card
	return card
end

local function makeScroller(parent, height)
	local scroller = Instance.new("ScrollingFrame")
	scroller.Size = UDim2.new(1, 0, 0, height)
	scroller.BackgroundColor3 = COLORS.panelDark
	scroller.BackgroundTransparency = 0.4
	scroller.BorderSizePixel = 0
	scroller.ScrollBarThickness = 4
	scroller.ScrollBarImageColor3 = COLORS.stroke
	scroller.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroller.CanvasSize = UDim2.new()
	scroller.LayoutOrder = 1
	scroller.Parent = parent
	corner(scroller, 8)
	pad(scroller, 6)
	stack(scroller, 4)
	return scroller
end

local changeFrame = makeScroller(makeSection("CHANGES", 3), 120)
local logFrame = makeScroller(makeSection("DIFFS", 4), 240)

local treeCard = makeSection("TREE", 5)
local treeFrame = Instance.new("Frame")
treeFrame.Size = UDim2.new(1, 0, 0, 0)
treeFrame.AutomaticSize = Enum.AutomaticSize.Y
treeFrame.BackgroundTransparency = 1
treeFrame.LayoutOrder = 1
treeFrame.Parent = treeCard
stack(treeFrame, 1)

local MAX_CHANGES = 100
local changeEntries = {}
local changeSeq = 0

local function addChange(kind, file, origin, lines)
	if not file or file == "" then
		return
	end
	changeSeq += 1
	local sign = if kind == "add" then "+" elseif kind == "del" then "-" else "~"
	local color = if kind == "add" then GREEN elseif kind == "del" then RED else YELLOW

	local row = Instance.new("TextButton")
	row.Text = ""
	row.AutoButtonColor = false
	row.Size = UDim2.new(1, 0, 0, 18)
	row.BackgroundTransparency = 1
	row.LayoutOrder = -changeSeq
	row.Parent = changeFrame
	row.MouseButton1Click:Connect(function()
		showDetail({
			title = file,
			meta = origin .. "  ·  " .. kind .. "  ·  " .. os.date("%H:%M:%S"),
			lines = lines or {},
		})
	end)

	local signLabel = Instance.new("TextLabel")
	signLabel.Size = UDim2.new(0, 12, 1, 0)
	signLabel.BackgroundTransparency = 1
	signLabel.Font = Enum.Font.GothamBold
	signLabel.TextSize = 13
	signLabel.TextColor3 = color
	signLabel.Text = sign
	signLabel.Parent = row

	local dir, name = string.match(file, "^(.*/)([^/]*)$")
	dir = dir or ""
	name = name or file
	local nameLabel = Instance.new("TextLabel")
	nameLabel.Position = UDim2.fromOffset(16, 0)
	nameLabel.Size = UDim2.new(1, -56, 1, 0)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Font = Enum.Font.Code
	nameLabel.TextSize = 12
	nameLabel.TextXAlignment = Enum.TextXAlignment.Left
	nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
	nameLabel.RichText = true
	nameLabel.TextColor3 = COLORS.text
	nameLabel.Text = `<font color="#{COLORS.sub:ToHex()}">{escape(dir)}</font>{escape(name)}`
	nameLabel.Parent = row

	local tag = Instance.new("TextLabel")
	tag.AnchorPoint = Vector2.new(1, 0.5)
	tag.Position = UDim2.new(1, 0, 0.5, 0)
	tag.Size = UDim2.fromOffset(34, 14)
	tag.BackgroundColor3 = TAGS[origin] or COLORS.stroke
	tag.BorderSizePixel = 0
	tag.Font = Enum.Font.GothamBold
	tag.TextSize = 10
	tag.TextColor3 = Color3.new(1, 1, 1)
	tag.Text = origin
	tag.Parent = row
	corner(tag, 4)

	table.insert(changeEntries, row)
	if #changeEntries > MAX_CHANGES then
		local removed = table.remove(changeEntries, 1)
		if removed then
			removed:Destroy()
		end
	end
end

local function markState(key, state)
	sessionState[key] = state
	treeDirty = true
end

local MAX_LOG = 20
local MAX_ROWS = 14
local MAX_LINE = 2000
local logEntries = {}
local entrySeq = 0

local function safeText(text)
	if not utf8.len(text) then
		return "<binary data>"
	end
	if #text > MAX_LINE then
		return string.sub(text, 1, MAX_LINE) .. "…"
	end
	return text
end

local function splitLines(text)
	if text == "" then
		return {}
	end
	if string.sub(text, -1) == "\n" then
		text = string.sub(text, 1, -2)
	end
	local out = {}
	for line in string.gmatch(text .. "\n", "(.-)\n") do
		table.insert(out, safeText((string.gsub(line, "\t", "    "))))
	end
	return out
end

local function rowsFromEdits(edits)
	local rows = {}
	for i = #edits, 1, -1 do
		local edit = edits[i]
		for _, line in splitLines(edit.removed or "") do
			table.insert(rows, { "- " .. line, RED })
		end
		for _, line in splitLines(edit.text) do
			table.insert(rows, { "+ " .. line, GREEN })
		end
	end
	return rows
end

local function addLog(key, origin, rows)
	entrySeq += 1
	local entry = Instance.new("TextButton")
	entry.Text = ""
	entry.AutoButtonColor = false
	entry.Size = UDim2.new(1, 0, 0, 0)
	entry.AutomaticSize = Enum.AutomaticSize.Y
	entry.BackgroundColor3 = Color3.new(0.070588, 0.07451, 0.086275)
	entry.BackgroundTransparency = 0.3
	entry.BorderSizePixel = 0
	entry.LayoutOrder = -entrySeq
	entry.Parent = logFrame
	corner(entry, 6)
	entry.MouseButton1Click:Connect(function()
		showDetail({
			title = (string.gsub(key, SEP, "/")),
			meta = origin .. "  ·  " .. os.date("%H:%M:%S"),
			lines = rows,
		})
	end)

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 6)
	padding.PaddingBottom = UDim.new(0, 6)
	padding.PaddingLeft = UDim.new(0, 8)
	padding.PaddingRight = UDim.new(0, 8)
	padding.Parent = entry
	stack(entry, 3)

	local top = Instance.new("Frame")
	top.Size = UDim2.new(1, 0, 0, 18)
	top.BackgroundTransparency = 1
	top.LayoutOrder = 0
	top.Parent = entry

	local name = Instance.new("TextLabel")
	name.Size = UDim2.new(1, -48, 1, 0)
	name.BackgroundTransparency = 1
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.Font = Enum.Font.GothamBold
	name.TextSize = 12
	name.TextColor3 = COLORS.text
	name.TextTruncate = Enum.TextTruncate.AtEnd
	name.Text = string.gsub(key, SEP, "/") .. "  ·  " .. os.date("%H:%M:%S")
	name.Parent = top

	local tag = Instance.new("TextLabel")
	tag.AnchorPoint = Vector2.new(1, 0.5)
	tag.Position = UDim2.new(1, 0, 0.5, 0)
	tag.Size = UDim2.fromOffset(40, 16)
	tag.BackgroundColor3 = TAGS[origin] or COLORS.stroke
	tag.BorderSizePixel = 0
	tag.Font = Enum.Font.GothamBold
	tag.TextSize = 11
	tag.TextColor3 = Color3.new(1, 1, 1)
	tag.Text = origin
	tag.Parent = top
	corner(tag, 4)

	for i, row in rows do
		if i > MAX_ROWS then
			row = { "… " .. (#rows - MAX_ROWS) .. " more lines", GREY }
		end
		local label = Instance.new("TextLabel")
		label.Size = UDim2.new(1, 0, 0, 0)
		label.AutomaticSize = Enum.AutomaticSize.Y
		label.BackgroundTransparency = 1
		label.TextWrapped = true
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextYAlignment = Enum.TextYAlignment.Top
		label.Font = Enum.Font.Code
		label.TextSize = 12
		label.TextColor3 = row[2]
		label.Text = row[1]
		label.LayoutOrder = i
		label.Parent = entry
		if i > MAX_ROWS then
			break
		end
	end

	table.insert(logEntries, entry)
	if #logEntries > MAX_LOG then
		local removed = table.remove(logEntries, 1)
		if removed then
			removed:Destroy()
		end
	end
end

local function log(key, origin, rows)
	local ok, err = pcall(addLog, key, origin, rows)
	if not ok then
		warn("[pSync] log failed: " .. tostring(err))
	end
end

local treeExpanded = {}
local lastTree = 0

local function buildTrie()
	local trie = { children = {} }

	local function insert(key, state)
		local node = trie
		local walked = {}
		for _, name in string.split(key, SEP) do
			table.insert(walked, name)
			local child = node.children[name]
			if not child then
				child = { name = name, children = {}, key = table.concat(walked, SEP) }
				node.children[name] = child
			end
			node = child
		end
		node.state = state
	end

	for key in scripts do
		insert(key, sessionState[key])
	end
	for key, state in sessionState do
		if state == "deleted" and not scripts[key] then
			insert(key, state)
		end
	end

	local function flag(node)
		local best = node.state
		for _, child in node.children do
			local childFlag = flag(child)
			if childFlag and (not best or STATE_PRIORITY[childFlag] > STATE_PRIORITY[best]) then
				best = childFlag
			end
		end
		node.flag = best
		return best
	end
	flag(trie)
	return trie
end

local renderTree
renderTree = function()
	for _, child in treeFrame:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end

	local order = 0
	local function draw(node, depth)
		local list = {}
		for _, child in node.children do
			table.insert(list, child)
		end
		table.sort(list, function(a, b)
			local aFolder, bFolder = next(a.children) ~= nil, next(b.children) ~= nil
			if aFolder ~= bFolder then
				return aFolder
			end
			return string.lower(a.name) < string.lower(b.name)
		end)

		for _, child in list do
			order += 1
			local hasChildren = next(child.children) ~= nil
			local stateColor = STATE_COLORS[child.state]

			local row = Instance.new("TextButton")
			row.Size = UDim2.new(1, 0, 0, 20)
			row.BackgroundColor3 = stateColor or Color3.new(0.066667, 0.058824, 0.058824)
			row.BackgroundTransparency = if stateColor then 0.88 else 1
			row.BorderSizePixel = 0
			row.AutoButtonColor = false
			row.Font = Enum.Font.Gotham
			row.TextSize = 13
			row.TextXAlignment = Enum.TextXAlignment.Left
			row.RichText = true
			row.TextColor3 = stateColor or (if hasChildren then COLORS.text else COLORS.sub)
			row.LayoutOrder = order

			local arrow = if hasChildren then (if treeExpanded[child.key] then "∨ " else "＞ ") else "- "
			local text = arrow .. escape(child.name)
			if child.flag and not child.state then
				text ..= ` <font color="#{STATE_COLORS[child.flag]:ToHex()}">-</font>`
			end
			row.Text = text

			local indent = Instance.new("UIPadding")
			indent.PaddingLeft = UDim.new(0, 4 + depth * 14)
			indent.Parent = row
			corner(row, 4)
			row.Parent = treeFrame

			if hasChildren then
				row.MouseButton1Click:Connect(function()
					treeExpanded[child.key] = not treeExpanded[child.key]
					renderTree()
				end)
				if treeExpanded[child.key] then
					draw(child, depth + 1)
				end
			end
		end
	end
	draw(buildTrie(), 0)

	if order == 0 then
		local empty = Instance.new("TextLabel")
		empty.Size = UDim2.new(1, 0, 0, 20)
		empty.BackgroundTransparency = 1
		empty.Font = Enum.Font.Gotham
		empty.TextSize = 12
		empty.TextColor3 = COLORS.sub
		empty.Text = "No scripts tracked yet"
		empty.Parent = treeFrame
	end
end

local function colorFor(line)
	local first = string.sub(line, 1, 1)
	if first == "+" then
		return GREEN
	elseif first == "-" then
		return RED
	elseif first == "~" then
		return YELLOW
	end
	return COLORS.text
end

local function linesFromDetail(text)
	local out = {}
	if text == nil or text == "" then
		return out
	end
	local body = text
	if string.sub(body, -1) == "\n" then
		body = string.sub(body, 1, -2)
	end
	for line in string.gmatch(body .. "\n", "(.-)\n") do
		table.insert(out, { text = line, color = colorFor(line) })
	end
	return out
end

local function signedLines(sign, text, color)
	local out = {}
	if text == nil or text == "" then
		return out
	end
	local body = text
	if string.sub(body, -1) == "\n" then
		body = string.sub(body, 1, -2)
	end
	for line in string.gmatch(body .. "\n", "(.-)\n") do
		table.insert(out, { text = sign .. " " .. line, color = color })
	end
	return out
end

local MAX_DETAIL_LINES = 4000
local detailWidget = plugin:CreateDockWidgetPluginGuiAsync(
	"pSyncDetail",
	DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Float, false, false, 520, 440, 360, 260)
)
detailWidget.Title = "pSync detail"
detailWidget.Enabled = false

local detailRoot = Instance.new("Frame")
detailRoot.Size = UDim2.fromScale(1, 1)
detailRoot.BackgroundColor3 = Color3.new(0.098039, 0.101961, 0.105882)
detailRoot.BorderSizePixel = 0
detailRoot.Parent = detailWidget

local detailTitle = Instance.new("TextLabel")
detailTitle.Position = UDim2.fromOffset(12, 10)
detailTitle.Size = UDim2.new(1, -24, 0, 22)
detailTitle.BackgroundTransparency = 1
detailTitle.Font = Enum.Font.GothamBold
detailTitle.TextSize = 15
detailTitle.TextColor3 = COLORS.text
detailTitle.TextXAlignment = Enum.TextXAlignment.Left
detailTitle.TextTruncate = Enum.TextTruncate.AtEnd
detailTitle.Parent = detailRoot

local detailMeta = Instance.new("TextLabel")
detailMeta.Position = UDim2.fromOffset(12, 34)
detailMeta.Size = UDim2.new(1, -24, 0, 16)
detailMeta.BackgroundTransparency = 1
detailMeta.Font = Enum.Font.Gotham
detailMeta.TextSize = 12
detailMeta.TextColor3 = COLORS.sub
detailMeta.TextXAlignment = Enum.TextXAlignment.Left
detailMeta.TextTruncate = Enum.TextTruncate.AtEnd
detailMeta.Parent = detailRoot

local detailScroll = Instance.new("ScrollingFrame")
detailScroll.Position = UDim2.fromOffset(12, 58)
detailScroll.Size = UDim2.new(1, -24, 1, -106)
detailScroll.BackgroundColor3 = COLORS.panelDark
detailScroll.BorderSizePixel = 0
detailScroll.ScrollBarThickness = 5
detailScroll.ScrollBarImageColor3 = COLORS.stroke
detailScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
detailScroll.CanvasSize = UDim2.new()
detailScroll.Parent = detailRoot
corner(detailScroll, 8)
pad(detailScroll, 8)

local detailText = Instance.new("TextLabel")
detailText.Size = UDim2.new(1, 0, 0, 0)
detailText.AutomaticSize = Enum.AutomaticSize.Y
detailText.BackgroundTransparency = 1
detailText.TextWrapped = true
detailText.RichText = true
detailText.Font = Enum.Font.Code
detailText.TextSize = 12
detailText.TextColor3 = COLORS.text
detailText.TextXAlignment = Enum.TextXAlignment.Left
detailText.TextYAlignment = Enum.TextYAlignment.Top
detailText.Parent = detailScroll

local detailClose = Instance.new("TextButton")
detailClose.Position = UDim2.new(0, 12, 1, -40)
detailClose.Size = UDim2.new(1, -24, 0, 28)
detailClose.BackgroundColor3 = COLORS.accentDark
detailClose.BorderSizePixel = 0
detailClose.Font = Enum.Font.GothamBold
detailClose.TextSize = 14
detailClose.TextColor3 = Color3.new(1, 1, 1)
detailClose.Text = "Close"
detailClose.Parent = detailRoot
corner(detailClose, 8)
detailClose.MouseButton1Click:Connect(function()
	detailWidget.Enabled = false
end)

local function detailLine(text)
	if not utf8.len(text) then
		return "<binary data>"
	end
	if #text > MAX_LINE then
		return string.sub(text, 1, MAX_LINE) .. "…"
	end
	return text
end

showDetail = function(detail)
	detailTitle.Text = detail.title or ""
	detailMeta.Text = detail.meta or ""
	local lines = detail.lines or {}
	local parts = {}
	for i, line in lines do
		if i > MAX_DETAIL_LINES then
			table.insert(
				parts,
				`<font color="#{GREY:ToHex()}">… {#lines - MAX_DETAIL_LINES} more lines not shown</font>`
			)
			break
		end
		local text = line.text or line[1] or ""
		local color = line.color or line[2] or COLORS.text
		table.insert(parts, `<font color="#{color:ToHex()}">{escape(detailLine(text))}</font>`)
	end
	if #parts > 0 then
		detailText.Text = table.concat(parts, "\n")
	else
		detailText.Text = `<font color="#{COLORS.sub:ToHex()}">(no content)</font>`
	end
	detailScroll.CanvasPosition = Vector2.zero
	detailWidget.Enabled = true
end

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
toolbar.addButton("pSync", "Show sync status", "")
toolbar.setButtonHandler("pSync", function()
	widget.Enabled = not widget.Enabled
end)

local function setStatus(text)
	status.Text = text
	dot.BackgroundColor3 = if syncIgnored
		then COLORS.bad
		elseif paused or playtestPaused then COLORS.warn
		elseif connected then COLORS.ok
		else COLORS.bad
	resume.Visible = paused and not playtestPaused
end

local function normalizeSource(text)
	return string.gsub(string.gsub(text, "\r\n", "\n"), "\r", "\n")
end

local function hash(text)
	text = normalizeSource(text)
	local h = 2166136261
	for i = 1, #text do
		h = bit32.bxor(h, string.byte(text, i))
		h = ((h % 256) * 16777216 + h * 403) % 4294967296
	end
	return h
end

local function findDoc(script)
	for _, doc in ScriptEditorService:GetScriptDocuments() do
		if doc:GetScript() == script then
			return doc
		end
	end
	return nil
end

local function getSource(script)
	local doc = findDoc(script)
	if doc then
		return normalizeSource(doc:GetText())
	end
	return normalizeSource(script.Source)
end

local function waitLoaded(script, doc)
	local deadline = os.clock() + 3
	while normalizeSource(doc:GetText()) ~= normalizeSource(script.Source) and os.clock() < deadline do
		task.wait(0.05)
	end
end

local function openDoc(script)
	local doc = findDoc(script)
	if doc then
		return doc
	end
	local a, b = ScriptEditorService:OpenScriptDocumentAsync(script)
	doc = if typeof(a) == "Instance" then a elseif typeof(b) == "Instance" then b else findDoc(script)
	if not doc then
		error("could not open script document: " .. tostring(b))
	end
	openedAt[script] = os.clock()
	waitLoaded(script, doc)
	return doc
end

local function openLimited(script)
	while openActive >= OPEN_CONCURRENCY do
		task.wait(0.05)
	end
	openActive += 1
	local ok, result = pcall(openDoc, script)
	openActive -= 1
	if not ok then
		error(result, 0)
	end
	return result
end

local function lineStarts(text)
	local starts = { 0 }
	local pos = 1
	while true do
		local i = string.find(text, "\n", pos, true)
		if not i then
			break
		end
		table.insert(starts, i)
		pos = i + 1
	end
	return starts
end

local function lineCol(starts, text, offset)
	local lo, hi = 1, #starts
	while lo < hi do
		local mid = (lo + hi + 1) // 2
		if starts[mid] <= offset then
			lo = mid
		else
			hi = mid - 1
		end
	end
	local lineText = string.sub(text, starts[lo] + 1, offset)
	return lo, (utf8.len(lineText) or #lineText) + 1
end

local function tryApply(cmd, script)
	if RunService:IsRunning() then
		return "paused"
	end
	local doc = openLimited(script)
	local remaining = OPEN_DELAY - (os.clock() - (openedAt[script] or -math.huge))
	if remaining > 0 then
		task.wait(remaining)
	end

	if RunService:IsRunning() then
		return "paused"
	end
	local text = doc:GetText()
	local current = hash(text)
	if current == cmd.targetHash then
		return "ok"
	end
	if current ~= cmd.expectHash then
		return "changed"
	end

	local starts = lineStarts(text)
	for _, edit in cmd.edits do
		if RunService:IsRunning() then
			return "paused"
		end
		local sl, sc = lineCol(starts, text, edit.start)
		local el, ec = lineCol(starts, text, edit["end"])
		local success, message = doc:EditTextAsync(edit.text, sl, sc, el, ec)
		if success == false then
			error(message or "edit failed")
		end
	end

	task.wait(VERIFY_DELAY)
	if RunService:IsRunning() then
		return "paused"
	end
	if hash(doc:GetText()) ~= cmd.targetHash then
		return "mismatch"
	end
	-- Studio reloading a document it was just made to open is what the long settle guards against.
	-- One that has been open for a while doesn't need it, and every second spent here is a second
	-- the script has a command out that nothing else can be pushed behind.
	local fresh = os.clock() - (openedAt[script] or -math.huge) < FRESH_WINDOW
	task.wait(if fresh then SETTLE_DELAY else SETTLE_QUICK)
	if RunService:IsRunning() then
		return "paused"
	end
	if hash(doc:GetText()) == cmd.targetHash then
		return "ok", true
	end
	return "mismatch"
end

local function applyCommand(cmd)
	if RunService:IsRunning() then
		return false, false
	end
	local key = table.concat(cmd.path, SEP)
	local script = scripts[key]
	if not script or not script.Parent then
		return false, false
	end

	applyGen[key] = (applyGen[key] or 0) + 1
	local generation = applyGen[key]
	applying[key] = true
	local result = "mismatch"
	local applied = false
	local failure = nil
	for attempt = 1, 2 do
		local ok, value, didApply = pcall(tryApply, cmd, script)
		if not ok then
			failure = tostring(value)
			warn("[pSync] " .. string.gsub(key, SEP, "/") .. ": " .. failure)
		end
		result = if ok then value else "mismatch"
		applied = applied or didApply == true
		if result ~= "mismatch" then
			break
		end
	end

	if result == "ok" and applied then
		log(key, "VSC", rowsFromEdits(cmd.edits))
	elseif result == "paused" then
		applying[key] = nil
		return false, false
	elseif result == "changed" then
		log(key, "ERR", { { "Skipped: script changed in Studio, resyncing", GREY } })
	elseif result == "mismatch" then
		log(key, "ERR", { { "Edits did not apply" .. (if failure then ": " .. failure else ""), RED } })
	end

	task.delay(0.2, function()
		-- A newer command for this script may have started since; it owns the flag now.
		if applyGen[key] ~= generation then
			return
		end
		applying[key] = nil
		lastReported[key] = nil
		dirtyAt[key] = os.clock()
	end)
	return result == "ok", result == "mismatch"
end

local function markDirty(key)
	if not applying[key] then
		dirtyAt[key] = os.clock()
	end
end

local function pathOf(instance)
	if not instance:IsDescendantOf(game) then
		return nil
	end
	local path, classes = {}, {}
	local current = instance
	while current and current ~= game do
		table.insert(path, 1, current.Name)
		table.insert(classes, 1, current.ClassName)
		current = current.Parent
	end
	return path, classes
end

local function resolve(path)
	local instance = game
	for _, name in path do
		instance = instance and instance:FindFirstChild(name)
	end
	return instance
end

local function runContextOf(instance)
	if instance:IsA("Script") then
		return instance.RunContext.Name
	end
	return ""
end

local function untrack(key)
	local script = scripts[key]
	if connections[key] then
		connections[key]:Disconnect()
		connections[key] = nil
	end
	if attrConns[key] then
		attrConns[key]:Disconnect()
		attrConns[key] = nil
	end
	scripts[key] = nil
	if script then
		keyByScript[script] = nil
	end
	lastReported[key] = nil
	dirtyAt[key] = nil
	changes[key] = nil
	treeDirty = true
end

local function track(key, instance)
	scripts[key] = instance
	keyByScript[instance] = key
	connections[key] = instance:GetPropertyChangedSignal("Source"):Connect(function()
		markDirty(key)
	end)
	attrConns[key] = instance.AttributeChanged:Connect(function()
		attrDirty[key] = true
	end)
	attrDirty[key] = true
	lastReported[key] = nil
	dirtyAt[key] = 0
	treeDirty = true
end

local function onDescendantAdded(instance)
	if instance:IsA("LuaSourceContainer") and not keyByScript[instance] then
		candidates[instance] = os.clock()
	end
end

local function watchRoots(paths)
	for _, path in paths do
		local name = path[1]
		local service = name and game:FindFirstChild(name)
		if service and not watched[name] then
			watched[name] = service.DescendantAdded:Connect(onDescendantAdded)
		end
	end
end

local function rebuildTracked(paths)
	local wanted = {}
	for _, path in paths do
		local key = table.concat(path, SEP)
		wanted[key] = true
		local instance = resolve(path)
		if instance and instance:IsA("LuaSourceContainer") then
			if scripts[key] ~= instance then
				untrack(key)
				track(key, instance)
			elseif resync then
				lastReported[key] = nil
				dirtyAt[key] = 0
				attrDirty[key] = true
			end
		else
			untrack(key)
			table.insert(outbox.missing, path)
		end
	end
	for key in scripts do
		if not wanted[key] then
			untrack(key)
		end
	end
	resync = false
	watchRoots(paths)
end

local function checkCandidates()
	local now = os.clock()
	local ready = {}
	for instance, at in candidates do
		if now - at >= CREATE_DEBOUNCE then
			candidates[instance] = nil
			if instance:IsDescendantOf(game) and not keyByScript[instance] then
				if instance.Name == instance.ClassName then
					candidates[instance] = now
				else
					ready[instance] = true
				end
			end
		end
	end
	if next(ready) == nil then
		return
	end

	-- A script inside another script that isn't synced yet can only be placed once that one exists,
	-- so the ones above come along, and everything goes out parents first.
	local above = {}
	for instance in ready do
		local ancestor = instance.Parent
		while ancestor and ancestor ~= game do
			if
				ancestor:IsA("LuaSourceContainer")
				and not keyByScript[ancestor]
				and ancestor.Name ~= ancestor.ClassName
			then
				above[ancestor] = true
				candidates[ancestor] = nil
			end
			ancestor = ancestor.Parent
		end
	end
	for ancestor in above do
		ready[ancestor] = true
	end

	local list = {}
	for instance in ready do
		local path, classes = pathOf(instance)
		if path then
			table.insert(list, { instance = instance, path = path, classes = classes })
		end
	end
	table.sort(list, function(a, b)
		if #a.path ~= #b.path then
			return #a.path < #b.path
		end
		return table.concat(a.path, SEP) < table.concat(b.path, SEP)
	end)

	for _, entry in list do
		local instance = entry.instance
		local key = table.concat(entry.path, SEP)
		if not keyByScript[instance] and rejected[instance] ~= key then
			rejected[instance] = key
			table.insert(outbox.created, {
				path = entry.path,
				classes = entry.classes,
				className = instance.ClassName,
				runContext = runContextOf(instance),
				source = getSource(instance),
			})
		end
	end
end

local function checkTracked()
	local now = os.clock()
	for key, script in scripts do
		local signature = nil
		local path, classes = pathOf(script)
		if not path then
			signature = "gone"
		else
			local current = table.concat(path, SEP)
			if current ~= key then
				signature = current
			end
		end

		if signature == nil then
			changes[key] = nil
		else
			local change = changes[key]
			if not change or change.signature ~= signature then
				changes[key] = { signature = signature, at = now }
			elseif now - change.at >= CHANGE_DEBOUNCE then
				local from = string.split(key, SEP)
				untrack(key)
				if signature == "gone" then
					markState(key, "deleted")
					table.insert(outbox.deleted, from)
				else
					markState(signature, "moved")
					rejected[script] = signature
					table.insert(outbox.moved, {
						from = from,
						path = path,
						classes = classes,
						className = script.ClassName,
						runContext = runContextOf(script),
					})
				end
			end
		end
	end
end

local function encodeAttr(value)
	local t = typeof(value)
	if t == "string" or t == "number" or t == "boolean" then
		return value
	elseif t == "Vector3" then
		return { Vector3 = { value.X, value.Y, value.Z } }
	elseif t == "Vector2" then
		return { Vector2 = { value.X, value.Y } }
	elseif t == "Color3" then
		return { Color3 = { value.R, value.G, value.B } }
	end
	return nil
end

local function decodeAttr(value)
	if type(value) ~= "table" then
		return value
	end
	if value.Vector3 then
		return Vector3.new(table.unpack(value.Vector3))
	elseif value.Vector2 then
		return Vector2.new(table.unpack(value.Vector2))
	elseif value.Color3 then
		return Color3.new(table.unpack(value.Color3))
	end
	return nil
end

local function collectAttrReports()
	local reports = {}
	for key in attrDirty do
		local instance = scripts[key]
		if instance then
			local entries = {}
			for name, value in pairs(instance:GetAttributes()) do
				local encoded = encodeAttr(value)
				if encoded ~= nil then
					table.insert(entries, { name = name, value = encoded })
				end
			end
			table.insert(reports, { path = string.split(key, SEP), attributes = entries })
		end
	end
	table.clear(attrDirty)
	return reports
end

local function applyAttrCommand(cmd)
	local instance = scripts[table.concat(cmd.path, SEP)]
	if not instance then
		return
	end
	for _, name in cmd.remove or {} do
		instance:SetAttribute(name, nil)
	end
	for _, entry in cmd.set or {} do
		local ok, err = pcall(instance.SetAttribute, instance, entry.name, decodeAttr(entry.value))
		if not ok then
			warn("[pSync] attribute " .. tostring(entry.name) .. ": " .. tostring(err))
		end
	end
end

local SCRIPT_CLASSES = { Script = true, LocalScript = true, ModuleScript = true }

-- Puts `source` into a new script through the script editor, in pieces, instead of assigning
-- Script.Source: that is refused at 200000 characters and above, and the editor API is the one
-- that stays safe in Team Create.
local function writeSource(instance, source)
	if RunService:IsRunning() then
		error("sync paused for playtest")
	end
	local doc = openLimited(instance)
	local target = hash(source)
	if hash(doc:GetText()) == target then
		return
	end
	local length = #source
	local line, col = 1, 1
	local pos = 1
	while pos <= length do
		if RunService:IsRunning() then
			error("sync paused for playtest")
		end
		local stop = math.min(pos + CHUNK_BYTES - 1, length)
		if stop < length then
			local cut = nil
			for i = stop, pos, -1 do
				if string.byte(source, i) == 10 then
					cut = i
					break
				end
			end
			if cut then
				stop = cut
			else
				-- a stretch without a line break: just don't cut a multi-byte character in half
				while stop > pos do
					local nextByte = string.byte(source, stop + 1)
					if nextByte and nextByte >= 128 and nextByte < 192 then
						stop -= 1
					else
						break
					end
				end
			end
		end

		local piece = string.sub(source, pos, stop)
		local success, message = doc:EditTextAsync(piece, line, col, line, col)
		if success == false then
			error(message or "edit failed")
		end

		local breaks, lastBreak = 0, nil
		for i = 1, #piece do
			if string.byte(piece, i) == 10 then
				breaks += 1
				lastBreak = i
			end
		end
		if lastBreak then
			line += breaks
			local tail = string.sub(piece, lastBreak + 1)
			col = (utf8.len(tail) or #tail) + 1
		else
			col += utf8.len(piece) or #piece
		end
		pos = stop + 1
	end

	task.wait(VERIFY_DELAY)
	if hash(doc:GetText()) ~= target then
		error("the editor did not take the whole source")
	end
end

local function applyCreate(create)
	if RunService:IsRunning() then
		return
	end
	local path = create.path
	local key = table.concat(path, SEP)
	if scripts[key] then
		return
	end

	local parent = game:FindFirstChild(path[1])
	if not parent then
		log(key, "ERR", { { "Cannot create: " .. tostring(path[1]) .. " does not exist", RED } })
		return
	end
	for i = 2, #path - 1 do
		local child = parent:FindFirstChild(path[i])
		if not child then
			-- The backend says what each level is (from the sourcemap); a script level is created from
			-- its own entry, which comes first, so it missing here means that one failed.
			local spec = create.parents and create.parents[i]
			local className = if spec then spec.className else "Folder"
			if SCRIPT_CLASSES[className] then
				log(key, "ERR", {
					{ "Cannot create: " .. path[i] .. " (a " .. className .. ") above it does not exist", RED },
				})
				return
			end
			local made = nil
			pcall(function()
				made = Instance.new(className)
			end)
			made = made or Instance.new("Folder")
			made.Name = path[i]
			made.Parent = parent
			child = made
		end
		parent = child
	end
	local existing = parent:FindFirstChild(path[#path])
	local adopt = nil
	if existing then
		if existing:IsA("Folder") and SCRIPT_CLASSES[create.className] then
			-- A Folder an earlier run made where this script belongs: it becomes the script and keeps
			-- what is inside it.
			adopt = existing
		else
			log(key, "ERR", { { "Cannot create: an instance with that name already exists", RED } })
			return
		end
	end

	local instance = Instance.new(create.className)
	instance.Name = path[#path]
	if create.className == "Script" and create.runContext ~= "" then
		instance.RunContext = Enum.RunContext[create.runContext]
	end
	-- Nothing is reported for this script until its text is in: an empty script must never be
	-- taken for Studio's version of the file.
	applyGen[key] = (applyGen[key] or 0) + 1
	local generation = applyGen[key]
	applying[key] = true
	track(key, instance)
	instance.Parent = parent

	local filled, err = nil, nil
	if #create.source < LARGE_SOURCE then
		filled, err = pcall(function()
			instance.Source = create.source
		end)
	else
		filled, err = pcall(writeSource, instance, create.source)
	end
	if not filled then
		untrack(key)
		applying[key] = nil
		instance:Destroy()
		if RunService:IsRunning() then
			return
		end
		warn("[pSync] " .. string.gsub(key, SEP, "/") .. ": " .. tostring(err))
		log(key, "ERR", { { "Cannot create: " .. tostring(err), RED } })
		table.insert(outbox.refused, { path = path, reason = tostring(err) })
		return
	end

	if adopt then
		for _, child in adopt:GetChildren() do
			child.Parent = instance
		end
		adopt:Destroy()
	end
	task.delay(0.2, function()
		if applyGen[key] ~= generation then
			return
		end
		applying[key] = nil
		lastReported[key] = nil
		dirtyAt[key] = os.clock()
	end)
	markState(key, "added")
	addChange("add", create.file, "VSC", signedLines("+", string.sub(create.source, 1, 60000), GREEN))
end

local function applyDelete(deleted)
	local key = table.concat(deleted.path, SEP)
	local script = scripts[key]
	if not script then
		local found = resolve(deleted.path)
		if found and found:IsA("LuaSourceContainer") then
			script = found
		else
			return
		end
	end
	local removedText = script.Source
	untrack(key)
	local parent = script.Parent
	script:Destroy()
	while parent and parent:IsA("Folder") and #parent:GetChildren() == 0 do
		local up = parent.Parent
		parent:Destroy()
		parent = up
	end
	markState(key, "deleted")
	addChange("del", deleted.file, "VSC", signedLines("-", removedText, RED))
end

ScriptEditorService.TextDocumentDidChange:Connect(function(doc)
	local script = doc:GetScript()
	local key = script and keyByScript[script]
	if key then
		markDirty(key)
	end
end)

local function collectReports()
	local reports = {}
	local now = os.clock()
	for key, at in dirtyAt do
		if now - at >= DEBOUNCE and not applying[key] then
			dirtyAt[key] = nil
			local script = scripts[key]
			if script then
				local source = getSource(script)
				if source ~= lastReported[key] then
					lastReported[key] = source
					table.insert(reports, { path = string.split(key, SEP), source = source })
				end
			end
		end
	end
	return reports
end

local function send(body)
	if not (connected and client) then
		return
	end
	local ok, err = pcall(function()
		local encoded = HttpService:JSONEncode(body)
		local success, sendErr = pcall(client.Send, client, encoded)
		if not success then
			error(`send failed ({#encoded} bytes): {sendErr}`)
		end
	end)
	if not ok then
		warn("[pSync] " .. tostring(err))
	end
end

local function processCommands()
	while #commandQueue > 0 do
		local cmd = table.remove(commandQueue, 1)
		task.spawn(function()
			local success, ok, halt = pcall(applyCommand, cmd)
			if not success then
				warn("[pSync] apply failed: " .. tostring(ok))
				ok, halt = false, false
			end
			table.insert(acks, { id = cmd.id, ok = ok, halt = halt })
		end)
	end
end

local function onMessage(message)
	if RunService:IsRunning() then
		return
	end
	local ok, response = pcall(HttpService.JSONDecode, HttpService, message)
	if not ok then
		warn("[pSync] bad message from backend: " .. tostring(response))
		return
	end
	syncIgnored = response.ignored == true
	if syncIgnored then
		paused = false
		setStatus(response.message or "Sync ignored: this project does not match the open place")
		return
	end
	paused = response.paused
	for _, deleted in response.deletes or {} do
		local deleteOk, deleteError = pcall(applyDelete, deleted)
		if not deleteOk then
			warn("[pSync] delete failed: " .. tostring(deleteError))
		end
	end
	if response.tracked then
		rebuildTracked(response.tracked)
	end
	for _, event in response.events or {} do
		log(table.concat(event.path, SEP), "RBX", rowsFromEdits(event.edits))
	end
	for _, notice in response.notices or {} do
		local key = table.concat(notice.path, SEP)
		if notice.kind == "err" then
			log(key, notice.origin, { { notice.text, RED } })
		elseif notice.kind == "attr" then
			addChange("move", notice.file, notice.origin, linesFromDetail(notice.detail))
		else
			addChange(notice.kind, notice.file, notice.origin, linesFromDetail(notice.detail))
			markState(
				key,
				if notice.kind == "add" then "added" elseif notice.kind == "move" then "moved" else "deleted"
			)
		end
	end
	local creates = response.creates or {}
	if #creates > 0 then
		-- Parents first, one after the other: a script goes inside the one made just before it.
		table.sort(creates, function(a, b)
			return #a.path < #b.path
		end)
		task.spawn(function()
			for _, create in creates do
				local createOk, createError = pcall(applyCreate, create)
				if not createOk then
					warn("[pSync] create failed: " .. tostring(createError))
				end
			end
		end)
	end
	for _, cmd in response.attrCommands or {} do
		local attributeOk, attributeError = pcall(applyAttrCommand, cmd)
		if not attributeOk then
			warn("[pSync] attribute apply failed: " .. tostring(attributeError))
		end
	end
	for _, cmd in response.commands do
		table.insert(commandQueue, cmd)
	end
	setStatus(response.message)
	processCommands()
end

local function closeClient(target)
	pcall(function()
		target:Close()
	end)
end

plugin.Unloading:Connect(function()
	toolbar.removeButtonHandler("pSync")
	if client then
		closeClient(client)
		client = nil
	end
end)

local function connect()
	local ok, created = pcall(function()
		return HttpService:CreateWebStreamClient(Enum.WebStreamClientType.WebSocket, { Url = URL })
	end)
	if not ok then
		warn("[pSync] " .. tostring(created))
		return
	end

	client = created
	created.Opened:Connect(function()
		connected = true
		syncIgnored = false
		setStatus("Checking .psync project identity...")
		resync = true
		for _, list in outbox do
			table.clear(list)
		end
		send({ hello = true, placeId = game.PlaceId })
	end)
	created.MessageReceived:Connect(onMessage)
	local finished = false
	local function closed()
		if finished then
			return
		end
		finished = true
		closeClient(created)
		if client == created then
			client = nil
			connected = false
			paused = false
			setStatus("Waiting for sync_backend...")
		end
	end
	created.Closed:Connect(closed)
	created.Error:Connect(closed)
end

task.spawn(function()
	while true do
		if RunService:IsRunning() then
			if not playtestPaused then
				playtestPaused = true
				table.clear(commandQueue)
				acks = {}
				resumeRequested = false
				local previous = client
				client = nil
				connected = false
				paused = false
				syncIgnored = false
				if previous then
					closeClient(previous)
				end
				setStatus("Sync paused during playtest")
			end
			task.wait(TICK)
		else
			if playtestPaused then
				playtestPaused = false
				setStatus("Playtest ended. Reconnecting...")
			end
			if not client then
				connect()
				task.wait(RETRY_INTERVAL)
			else
				if not syncIgnored and treeDirty and os.clock() - lastTree >= 0.5 then
					treeDirty = false
					lastTree = os.clock()
					local ok, err = pcall(renderTree)
					if not ok then
						warn("[pSync] tree failed: " .. tostring(err))
					end
				end
				if connected and not syncIgnored then
					if os.clock() >= nextCheck then
						nextCheck = os.clock() + CHECK_INTERVAL
						checkCandidates()
						checkTracked()
					end
					local reports = collectReports()
					local attrReports = collectAttrReports()
					local hasOutbox = #outbox.created
							+ #outbox.deleted
							+ #outbox.moved
							+ #outbox.missing
							+ #outbox.refused
						> 0
					if #reports > 0 or #acks > 0 or resumeRequested or hasOutbox or #attrReports > 0 then
						send({
							reports = reports,
							attrReports = attrReports,
							acks = acks,
							resume = resumeRequested,
							created = outbox.created,
							deleted = outbox.deleted,
							moved = outbox.moved,
							missing = outbox.missing,
							refused = outbox.refused,
						})
						acks = {}
						resumeRequested = false
						outbox = { created = {}, deleted = {}, moved = {}, missing = {}, refused = {} }
					end
				end
				task.wait(TICK)
			end
		end
	end
end)
