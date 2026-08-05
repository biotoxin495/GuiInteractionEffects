--   ____       _ ___       _                      _   _
--  / ___|_   _(_)_ _|_ __ | |_ ___ _ __ __ _  ___| |_(_) ___  _ __
-- | |  _| | | | || || '_ \| __/ _ \ '__/ _` |/ __| __| |/ _ \| '_ \
-- | |_| | |_| | || || | | | ||  __/ | | (_| | (__| |_| | (_) | | | |
--  \____|\__,_|_|___|_| |_|\__\___|_|  \__,_|\___|\__|_|\___/|_| |_|
-- | ____|/ _|/ _| ___  ___| |_ ___
-- |  _| | |_| |_ / _ \/ __| __/ __|
-- | |___|  _|  _|  __/ (__| |_\__ \
-- |_____|_| |_|  \___|\___|\__|___/

-- made with ❤️ by biotoxin495

-- A Roblox UI module for declarative hover/press tween effects on UI Elements.
-- Original property values are captured automatically before any effect is applied, and
-- restored on cleanup, on disable, or whenever a state stops configuring them.
--
-- Usage:
--   local GuiInteractionEffects = require(path.to.GuiInteractionEffects)
--
--   GuiInteractionEffects:Setup(button, {
--     OnMouseEnter = { self = { BackgroundTransparency = 0.5 } },
--     OnClickStart = { self = { Rotation = 5 } },
--   }, {
--     TweenInfo = TweenInfo.new(0.15),
--     OnMouseEnter = function() end,
--     OnMouseLeave = function() end,
--   })
--
--   GuiInteractionEffects:SetEnabled(button, false) -- disable and snap back to the original appearance
--   GuiInteractionEffects:Clear(button)             -- disconnect, restore, and forget the button
--
-- One-off helper (no persistent listeners):
--   GuiInteractionEffects:Apply(guiObject, { self = { BackgroundTransparency = 0.5 } }, tweenInfo)
--
-- Effect states (all optional): OnMouseEnter, OnMouseLeave, OnClickStart
--
-- Target resolution:
--   self = { ... }            -- the button itself
--   [SomeInstance] = { ... }  -- direct instance reference (preferred, unambiguous)
--   SomeName = { ... }        -- recursive descendant lookup by Name (warns if missing/ambiguous)
--
-- State resolution priority (resolved per property, so a state that only configures some
-- properties doesn't leave the rest stuck at a stale value):
--   Pressed -> OnClickStart, falls back to OnMouseEnter, falls back to the original value
--   Hover   -> OnMouseEnter, falls back to the original value
--   Idle    -> OnMouseLeave, falls back to the original value
--
-- Options (all optional, see SetupOptions):
--   TweenInfo:    TweenInfo used for tweened transitions (default TweenInfo.new(0.15))
--   OnMouseEnter: EffectCallback fired after hover effects are applied
--   OnMouseLeave: EffectCallback fired after leave/idle effects are applied
--
-- MouseEffectsActive attribute:
--   Set the boolean attribute "MouseEffectsActive" to false on the button to disable effects
--   (equivalent to SetEnabled(button, false)); remove it or set it true to re-enable.
--
-- Scope (v1): desktop mouse interaction only (MouseEnter/MouseLeave/MouseButton1Down/Up).
-- Touch, gamepad selection, and keyboard/gamepad activation are not wired up in this release.

local TweenService = game:GetService("TweenService")

local GuiInteractionEffects = {}

local DEFAULT_TWEEN_INFO = TweenInfo.new(0.15)
local EFFECT_STATE_KEYS = { "OnMouseEnter", "OnMouseLeave", "OnClickStart" }
local EFFECT_STATE_CHAINS = {
	Pressed = { "OnClickStart", "OnMouseEnter" },
	Hover = { "OnMouseEnter" },
	Idle = { "OnMouseLeave" },
}

-- PUBLIC TYPES --

export type EffectCallback = () -> ()

export type EffectProps = { [string]: any }
export type EffectTarget = string | Instance
export type EffectTargets = { [EffectTarget]: EffectProps }

export type ButtonEffectsTable = {
	OnMouseEnter: EffectTargets?,
	OnMouseLeave: EffectTargets?,
	OnClickStart: EffectTargets?,
}

export type SetupOptions = {
	TweenInfo: TweenInfo?,
	OnMouseEnter: EffectCallback?,
	OnMouseLeave: EffectCallback?,
}

-- INTERNAL TYPES --

type ResolvedTarget = {
	key: EffectTarget,
	instance: Instance,
	properties: { [string]: boolean },
}

type ButtonData = {
	button: GuiButton,
	effects: ButtonEffectsTable,
	tweenInfo: TweenInfo,
	options: SetupOptions,
	originalProperties: { [Instance]: EffectProps },
	targets: { ResolvedTarget },
	connections: { [string]: RBXScriptConnection },
	activeTweens: { [Instance]: Tween },
	isHovered: boolean,
	isPressed: boolean,
	isEnabled: boolean,
}

-- Internal storage for each button's effect data
local activeButtonsData: { [GuiButton]: ButtonData } = {}

-- PRIVATE HELPER FUNCTIONS --

local function canReadProperty(instance: Instance, prop: string): (boolean, any)
	local ok, value = pcall(function()
		return (instance :: any)[prop]
	end)
	return ok, value
end

local function resolveTargetInstance(root: Instance, targetKey: EffectTarget): Instance?
	if targetKey == "self" then
		return root
	elseif typeof(targetKey) == "Instance" then
		if not (targetKey :: Instance).Parent then
			warn(
				("GuiInteractionEffects: target instance for %s appears to be destroyed (no Parent)"):format(
					root:GetFullName()
				)
			)
		end
		return targetKey :: Instance
	elseif typeof(targetKey) == "string" then
		local matches = {}
		for _, descendant in ipairs(root:GetDescendants()) do
			if descendant.Name == targetKey then
				table.insert(matches, descendant)
			end
		end

		if #matches == 0 then
			warn(("GuiInteractionEffects: could not find target '%s' under %s"):format(targetKey, root:GetFullName()))
			return nil
		end

		if #matches > 1 then
			warn(
				("GuiInteractionEffects: multiple descendants named '%s' under %s; string lookup is ambiguous, using the first match. Use a direct instance reference to avoid this."):format(
					targetKey,
					root:GetFullName()
				)
			)
		end

		return matches[1]
	end

	warn("GuiInteractionEffects: invalid target key type: " .. typeof(targetKey))
	return nil
end

-- Tweens `props` on `instance`, cancelling and destroying any tween already in flight for it.
-- The tween only clears itself from activeTweens if it is still the active one on completion,
-- so a superseded tween can't clobber a newer one's bookkeeping.
local function tweenProperties(data: ButtonData, instance: Instance, props: EffectProps)
	if next(props) == nil then
		return
	end

	local existing = data.activeTweens[instance]
	if existing then
		existing:Cancel()
		existing:Destroy()
		data.activeTweens[instance] = nil
	end

	local tween = TweenService:Create(instance, data.tweenInfo, props)
	data.activeTweens[instance] = tween
	tween.Completed:Connect(function()
		if data.activeTweens[instance] == tween then
			data.activeTweens[instance] = nil
		end
		tween:Destroy()
	end)
	tween:Play()
end

local function setPropertiesImmediate(data: ButtonData, instance: Instance, props: EffectProps)
	local existing = data.activeTweens[instance]
	if existing then
		existing:Cancel()
		existing:Destroy()
		data.activeTweens[instance] = nil
	end

	for prop, value in pairs(props) do
		(instance :: any)[prop] = value
	end
end

-- Shared by Clear, SetEnabled, and MouseEffectsActive handling so restoration behaves
-- identically everywhere. `immediate` skips tweening (used when disabling, so the button
-- can't be left visually mid-transition).
local function restoreOriginalProperties(data: ButtonData, immediate: boolean)
	for _, target in ipairs(data.targets) do
		local instance = target.instance
		if instance and instance.Parent then
			local props = data.originalProperties[instance]
			if immediate then
				setPropertiesImmediate(data, instance, props)
			else
				tweenProperties(data, instance, props)
			end
		end
	end
end

local function resolveStateName(data: ButtonData): "Pressed" | "Hover" | "Idle"
	if data.isPressed then
		return "Pressed"
	elseif data.isHovered then
		return "Hover"
	end
	return "Idle"
end

-- Central visual-state resolver. Every event callback should only flip state flags and then
-- call this, rather than deciding visuals itself.
local function updateVisuals(button: GuiButton)
	local data = activeButtonsData[button]
	if not data or not data.isEnabled then
		return
	end

	local chain = EFFECT_STATE_CHAINS[resolveStateName(data)]

	for _, target in ipairs(data.targets) do
		local instance = target.instance
		local originals = data.originalProperties[instance]
		local desired: EffectProps = {}

		for prop in pairs(target.properties) do
			local value = originals[prop]
			for _, stateKey in ipairs(chain) do
				local stateTargets = data.effects[stateKey]
				local stateProps = stateTargets and stateTargets[target.key]
				if stateProps and stateProps[prop] ~= nil then
					value = stateProps[prop]
					break
				end
			end
			desired[prop] = value
		end

		tweenProperties(data, instance, desired)
	end
end

-- Shared enable/disable implementation used by both SetEnabled and the MouseEffectsActive
-- attribute listener.
local function setButtonEnabled(data: ButtonData, isEnabled: boolean)
	if data.isEnabled == isEnabled then
		return
	end

	if isEnabled then
		data.isEnabled = true
		-- Leave the button in its current (idle) appearance; do not auto-apply hover.
	else
		data.isHovered = false
		data.isPressed = false
		data.isEnabled = false
		restoreOriginalProperties(data, true)
	end
end

local function disconnectAll(data: ButtonData)
	for _, conn in pairs(data.connections) do
		conn:Disconnect()
	end
	table.clear(data.connections)
end

-- Called when the button Instance itself is being destroyed. No point tweening back to the
-- original appearance, so this just tears everything down.
local function handleButtonDestroying(button: GuiButton)
	local data = activeButtonsData[button]
	if not data then
		return
	end

	disconnectAll(data)
	for _, tween in pairs(data.activeTweens) do
		tween:Cancel()
		tween:Destroy()
	end
	table.clear(data.activeTweens)

	activeButtonsData[button] = nil
end

local function connectEvents(button: GuiButton, data: ButtonData, options: SetupOptions)
	data.connections.MouseEnter = button.MouseEnter:Connect(function()
		if not data.isEnabled then
			return
		end
		data.isHovered = true
		updateVisuals(button)
		if options.OnMouseEnter then
			options.OnMouseEnter()
		end
	end)

	data.connections.MouseLeave = button.MouseLeave:Connect(function()
		if not data.isEnabled then
			return
		end
		data.isHovered = false
		data.isPressed = false
		updateVisuals(button)
		if options.OnMouseLeave then
			options.OnMouseLeave()
		end
	end)

	if data.effects.OnClickStart then
		data.connections.MouseButton1Down = button.MouseButton1Down:Connect(function()
			if not data.isEnabled then
				return
			end
			data.isPressed = true
			updateVisuals(button)
		end)

		data.connections.MouseButton1Up = button.MouseButton1Up:Connect(function()
			if not data.isEnabled then
				return
			end
			data.isPressed = false
			-- Resolves back to Hover (if still hovered) or Idle via updateVisuals.
			updateVisuals(button)
		end)
	end

	data.connections.Destroying = button.Destroying:Connect(function()
		handleButtonDestroying(button)
	end)
end

local function connectAttributeListener(button: GuiButton, data: ButtonData)
	data.connections.MouseEffectsActiveChanged = button
		:GetAttributeChangedSignal("MouseEffectsActive")
		:Connect(function()
			local value = button:GetAttribute("MouseEffectsActive")
			setButtonEnabled(data, value ~= false)
		end)

	if button:GetAttribute("MouseEffectsActive") == false then
		setButtonEnabled(data, false)
	end
end

-- PUBLIC API --

--- Sets up mouse interaction effects for a GuiButton.
-- @param button GuiButton - the button instance to apply effects to.
-- @param effects ButtonEffectsTable - declarative per-state target/property config.
-- @param options SetupOptions? - optional TweenInfo and hover callbacks.
function GuiInteractionEffects:Setup(button: GuiButton, effects: ButtonEffectsTable, options: SetupOptions?)
	if activeButtonsData[button] then
		GuiInteractionEffects:Clear(button)
	end

	local resolvedOptions: SetupOptions = options or {}

	local data: ButtonData = {
		button = button,
		effects = effects,
		tweenInfo = resolvedOptions.TweenInfo or DEFAULT_TWEEN_INFO,
		options = resolvedOptions,
		originalProperties = {},
		targets = {},
		connections = {},
		activeTweens = {},
		isHovered = false,
		isPressed = false,
		isEnabled = true,
	}

	-- Union of every target key referenced across all states.
	local targetKeys: { [EffectTarget]: boolean } = {}
	for _, stateKey in ipairs(EFFECT_STATE_KEYS) do
		local stateTargets = effects[stateKey]
		if stateTargets then
			for targetKey in pairs(stateTargets) do
				targetKeys[targetKey] = true
			end
		end
	end

	for targetKey in pairs(targetKeys) do
		local instance = resolveTargetInstance(button, targetKey)
		if instance then
			-- Union of every property referenced for this target, across all states.
			local propSet: { [string]: boolean } = {}
			for _, stateKey in ipairs(EFFECT_STATE_KEYS) do
				local stateTargets = effects[stateKey]
				local props = stateTargets and stateTargets[targetKey]
				if props then
					for prop in pairs(props) do
						propSet[prop] = true
					end
				end
			end

			local originals: EffectProps = {}
			local validProps: { [string]: boolean } = {}
			for prop in pairs(propSet) do
				local ok, value = canReadProperty(instance, prop)
				if ok then
					originals[prop] = value
					validProps[prop] = true
				else
					warn(
						("GuiInteractionEffects: property '%s' cannot be read on %s, skipping it"):format(
							prop,
							instance:GetFullName()
						)
					)
				end
			end

			data.originalProperties[instance] = originals
			table.insert(data.targets, { key = targetKey, instance = instance, properties = validProps })
		end
	end

	activeButtonsData[button] = data

	connectEvents(button, data, resolvedOptions)
	connectAttributeListener(button, data)
end

--- Sets up the standard mouse-over effect, darkening the button's current background color.
-- @param button GuiButton - the button instance to apply the effect to.
-- @param mouseOverFunct EffectCallback? - optional callback fired when the mouse enters.
-- @param mouseClearFunct EffectCallback? - optional callback fired when the mouse leaves.
function GuiInteractionEffects:SetupMouseOverEffect(
	button: GuiButton,
	mouseOverFunct: EffectCallback?,
	mouseClearFunct: EffectCallback?
)
	GuiInteractionEffects:Setup(button, {
		OnMouseEnter = {
			self = { BackgroundColor3 = button.BackgroundColor3:Lerp(Color3.fromRGB(0, 0, 0), 0.2) },
		},
	}, {
		TweenInfo = DEFAULT_TWEEN_INFO,
		OnMouseEnter = mouseOverFunct,
		OnMouseLeave = mouseClearFunct,
	})
end

--- Disconnects all events, cancels active tweens, restores the original appearance, and
--- removes the button from internal storage. Safe to call more than once; a no-op if the
--- button was never set up (or was already cleared).
function GuiInteractionEffects:Clear(button: GuiButton)
	local data = activeButtonsData[button]
	if not data then
		return
	end

	disconnectAll(data)
	restoreOriginalProperties(data, false)
	activeButtonsData[button] = nil
end

--- Enables or disables interaction effects for a button. Disabling immediately (untweened)
--- restores the original appearance and blocks future interaction events until re-enabled.
--- Re-enabling does not auto-apply hover effects; a new interaction event is required.
function GuiInteractionEffects:SetEnabled(button: GuiButton, isEnabled: boolean)
	local data = activeButtonsData[button]
	if not data then
		return
	end

	setButtonEnabled(data, isEnabled)
end

--- Immediately tweens a one-off collection of target properties on `guiObject`. Does not set
--- up any persistent interaction listeners or state tracking.
function GuiInteractionEffects:Apply(guiObject: GuiObject, effects: EffectTargets, tweenInfo: TweenInfo?)
	local info = tweenInfo or DEFAULT_TWEEN_INFO

	for targetKey, props in pairs(effects) do
		local instance = resolveTargetInstance(guiObject, targetKey)
		if instance then
			local validProps: EffectProps = {}
			for prop, value in pairs(props) do
				local ok = canReadProperty(instance, prop)
				if ok then
					validProps[prop] = value
				else
					warn(
						("GuiInteractionEffects: property '%s' cannot be read on %s, skipping it"):format(
							prop,
							instance:GetFullName()
						)
					)
				end
			end

			if next(validProps) ~= nil then
				local tween = TweenService:Create(instance, info, validProps)
				tween.Completed:Connect(function()
					tween:Destroy()
				end)
				tween:Play()
			end
		end
	end
end

return GuiInteractionEffects
