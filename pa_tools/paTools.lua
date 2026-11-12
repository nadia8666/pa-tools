local state = {
	toolbar = plugin:CreateToolbar("PA Tools"),
	buttons = {},
	buttonConnections = {},
}

shared.paToolsState = state

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
