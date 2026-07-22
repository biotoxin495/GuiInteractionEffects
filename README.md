# GuiButtonEffects — Declarative hover/press tween effects for Roblox GuiButtons

**GuiButtonEffects** is a small Roblox UI module for wiring up hover and press tween effects on `GuiButton`s declaratively, instead of hand-writing `MouseEnter`/`MouseLeave`/`MouseButton1Down`/`MouseButton1Up` connections and `TweenService:Create` calls for every button in your game.

You describe what each object should look like in each interaction state. GuiButtonEffects captures the original property values automatically, resolves the correct tween for the current state, and restores everything cleanly when you disable or clear a button.

## Quick example

```lua
local GuiButtonEffects = require(ReplicatedStorage.Modules.GuiButtonEffects)

GuiButtonEffects:Setup(button, {
	OnMouseEnter = {
		self = { BackgroundTransparency = 0.5 },
	},
	OnClickStart = {
		self = { Rotation = 5 },
	},
})
```

Hovering the button tweens `BackgroundTransparency` to `0.5`. Pressing it also tweens `Rotation` to `5`, while `BackgroundTransparency` stays at its hover value. Releasing or leaving smoothly restores the original values GuiButtonEffects captured when `Setup` was called.

## 🚀 Features

### Declarative, inline configuration

Effects are described as plain tables keyed by state and target, not imperative event handlers.

```lua
GuiButtonEffects:Setup(button, {
	OnMouseEnter = {
		self = { BackgroundTransparency = 0.5 },
	},
	OnMouseLeave = {
		self = { BackgroundTransparency = 1 },
	},
	OnClickStart = {
		self = { Rotation = 5 },
	},
})
```

### Automatic original-property capture

GuiButtonEffects gathers the union of every property referenced across `OnMouseEnter`, `OnMouseLeave`, and `OnClickStart` for every target, and records each one's original value before anything is tweened. You never have to manually snapshot or restore a value yourself.

### Correct partial-state fallback

A state only has to configure the properties it cares about. Properties it omits resolve through a documented fallback chain instead of getting stuck at a stale value:

```text
Pressed -> OnClickStart, falls back to OnMouseEnter, falls back to the original value
Hover   -> OnMouseEnter, falls back to the original value
Idle    -> OnMouseLeave, falls back to the original value
```

In the quick example above, this is exactly why `BackgroundTransparency` correctly stays at its hover value while pressed, even though `OnClickStart` never mentions it.

### Safe under rapid interaction

Before starting a new tween on an object, GuiButtonEffects cancels and destroys any tween already running on it. Repeatedly entering/leaving a button, pressing mid-hover-tween, or releasing mid-press-tween won't leave stale tweens fighting over the same properties.

### Multiple target styles

```lua
GuiButtonEffects:Setup(button, {
	OnMouseEnter = {
		self = { BackgroundTransparency = 0.5 },       -- the button itself
		Icon = { ImageColor3 = Color3.new(1, 1, 1) },  -- descendant lookup by Name
		[someInstance] = { Rotation = 5 },             -- direct instance reference (preferred)
	},
})
```

Direct instance references are the most precise and are recommended when a name might not be unique. String lookups warn during development if the target is missing or the name is ambiguous.

### `SetEnabled` and the `MouseEffectsActive` attribute

```lua
GuiButtonEffects:SetEnabled(button, false)
```

Disabling a button immediately restores its original appearance and ignores further interaction events until it's re-enabled. Setting the `MouseEffectsActive` boolean attribute to `false` on the button does the same thing, and both share one internal implementation, so they can't drift out of sync.

### `Apply` for one-off tweens

```lua
GuiButtonEffects:Apply(guiObject, {
	self = { BackgroundTransparency = 0.5 },
}, TweenInfo.new(0.2))
```

`Apply` immediately tweens a collection of target properties without setting up any interaction listeners or persistent state, useful for scripted, non-interaction-driven transitions.

### Typed

`ButtonEffectsTable`, `SetupOptions`, `EffectTargets`, `EffectProps`, and `EffectCallback` are exported types, so effect configs and options tables get Luau type checking at the call site.

## 📖 Basic usage

Place the `GuiButtonEffects` module somewhere accessible to a client script, then set up each button once:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GuiButtonEffects = require(ReplicatedStorage.Modules.GuiButtonEffects)

local button = script.Parent.CloseButton

GuiButtonEffects:Setup(button, {
	OnMouseEnter = {
		self = { BackgroundTransparency = 0.85, Rotation = 9 },
		Icon = { ImageColor3 = Color3.fromRGB(255, 41, 41) },
	},
	OnMouseLeave = {
		self = { BackgroundTransparency = 1, Rotation = 0 },
		Icon = { ImageColor3 = Color3.fromRGB(255, 0, 0) },
	},
	OnClickStart = {
		self = { BackgroundTransparency = 0.92 },
	},
}, {
	TweenInfo = TweenInfo.new(0.15),
})
```

Clean up when the button is no longer needed:

```lua
GuiButtonEffects:Clear(button)
```

Cleanup also happens automatically if the button instance is destroyed, so `Clear` is only needed if you want to detach effects from a button that's staying alive.

### Example: disabling a button while an action is in progress

```lua
GuiButtonEffects:SetEnabled(purchaseButton, false)

local success = doPurchase()

GuiButtonEffects:SetEnabled(purchaseButton, true)
```

### Example: driving state through an attribute instead

```lua
purchaseButton:SetAttribute("MouseEffectsActive", false)
-- ... later ...
purchaseButton:SetAttribute("MouseEffectsActive", true)
```

### Example: hover callbacks

```lua
GuiButtonEffects:Setup(button, {
	OnMouseEnter = {
		self = { BackgroundColor3 = button.BackgroundColor3:Lerp(Color3.new(), 0.2) },
	},
}, {
	OnMouseEnter = function()
		SoundService.Hover:Play()
	end,
})
```

## ⚙️ API

### `GuiButtonEffects:Setup(button, effects, options?)`

Sets up interaction effects for a `GuiButton`. Calling `Setup` again on a button that's already configured clears the previous configuration first.

```lua
GuiButtonEffects:Setup(button, effectsTable, options)
```

### `GuiButtonEffects:Clear(button)`

Disconnects all events, cancels active tweens, restores the button's original appearance, and forgets it. Safe to call more than once; calling it on a button that was never set up (or was already cleared) is a harmless no-op.

```lua
GuiButtonEffects:Clear(button)
```

### `GuiButtonEffects:SetEnabled(button, enabled)`

Enables or disables interaction effects for a previously-set-up button. Disabling immediately (without tweening) restores the original appearance and blocks further interaction events. Re-enabling does not automatically apply hover effects; a new interaction event is required.

```lua
GuiButtonEffects:SetEnabled(button, false)
GuiButtonEffects:SetEnabled(button, true)
```

### `GuiButtonEffects:Apply(guiObject, effects, tweenInfo?)`

Immediately tweens a collection of target properties on `guiObject`. Does not set up any persistent interaction listeners or state tracking.

```lua
GuiButtonEffects:Apply(guiObject, {
	self = { BackgroundTransparency = 0.5 },
}, TweenInfo.new(0.2))
```

## Effects table reference

```lua
{
	OnMouseEnter = {
		[target] = { [property] = value, ... },
		...
	},
	OnMouseLeave = { ... },
	OnClickStart = { ... },
}
```

All three states are optional. `target` can be `"self"`, a direct `Instance` reference, or a string name resolved via recursive descendant lookup.

## Options reference

```lua
{
	TweenInfo = TweenInfo.new(0.15), -- used for all tweened transitions

	OnMouseEnter = function() end, -- fired after hover effects are applied
	OnMouseLeave = function() end, -- fired after leave/idle effects are applied
}
```

Both callbacks are optional, and `TweenInfo` defaults to `TweenInfo.new(0.15)` when omitted.

## 📝 Notes

* GuiButtonEffects is intended for client-side UI.
* v1 supports desktop mouse interaction only (`MouseEnter`, `MouseLeave`, `MouseButton1Down`, `MouseButton1Up`). Touch, gamepad selection, and keyboard/gamepad activation are not wired up in this release.
* String target lookups warn during development if a name can't be found or matches more than one descendant; prefer direct instance references when precision matters.
* An error configuring one target does not prevent other valid targets from being set up.
* Cleanup listens to the button's `Destroying` event, not a `Parent == nil` check, so temporarily reparenting a button won't be mistaken for destruction.

## 🛠️ Installation

### Wally

Add GuiButtonEffects to your `wally.toml` dependencies:

```toml
[dependencies]
GuiButtonEffects = "biotoxin495/guiinteractioneffects@1.0.0"
```

Run:

```text
wally install
```

Then require the package from the location configured by your project. Like for example:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GuiButtonEffects = require(
	ReplicatedStorage.Packages.GuiButtonEffects
)
```

### Manual installation

You can install the standalone ModuleScript manually by copying `src/init.luau` from the repository.

Recommended structure:

```text
ReplicatedStorage
└── Modules
    └── GuiButtonEffects
```

Then require it with:

```lua
local GuiButtonEffects = require(
	ReplicatedStorage.Modules.GuiButtonEffects
)
```

made with ❤️ by biotoxin495
