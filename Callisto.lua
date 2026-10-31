--!strict
--[[
	Callisto — single-file UI library
	Rebuilt from the original instance dump. Visuals are byte-for-byte the same
	properties; everything else is structure, animation and theming.

	Animation rules honoured throughout:
	  - NO element ever changes size for aesthetic purposes. All feedback is
	    transparency, colour, position or rotation.
	  - NO CanvasGroups anywhere: they flatten UIGradients over child text and
	    have too many rendering caveats. Windows and popups fade through the
	    Fader, which cascades transparency tweens over every descendant.
	  - The slider fill DOES resize, instantly and untweened — that is the
	    value display, not an animation.

	local Callisto = loadstring(game:HttpGet("..."))()

	local Window = Callisto:CreateWindow({ Title = "Callisto", Size = Vector2.new(591, 480) })
	local Page   = Window:AddPage("General")
	local Left   = Page:AddSection("Left", "Section #1")

	Left:AddToggle({ Title = "Toggle", Default = false, Callback = print })
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer

--=============================================================================
-- Shorthands (kept from the original source)
--=============================================================================

local CSK = ColorSequenceKeypoint.new
local NSK = NumberSequenceKeypoint.new
local BSP = Enum.BorderStrokePosition
local ASM = Enum.ApplyStrokeMode
local UFA = Enum.UIFlexAlignment
local TXA = Enum.TextXAlignment
local UIT = Enum.UserInputType
local ETT = Enum.TextTruncate
local UFO = UDim2.fromOffset
local UFS = UDim2.fromScale
local EGS = Enum.GuiState
local EKC = Enum.KeyCode
local TIS = table.insert
local TR = table.remove
local TF = table.find
local MC = math.clamp
local MR = math.round
local MF = math.floor
local ED = Enum.EasingDirection
local FD = Enum.FillDirection
local ES = Enum.EasingStyle
local FW = Enum.FontWeight
local SO = Enum.SortOrder
local FS = Enum.FontStyle
local TI = TweenInfo.new
local V2 = Vector2.new
local UD2 = UDim2.new
local UD = UDim.new
local FN = Font.new
local RGB = Color3.fromRGB
local HSV = Color3.fromHSV
local CS = ColorSequence.new
local NS = NumberSequence.new
local SCL = Enum.ScaleType
local ZIB = Enum.ZIndexBehavior
local AT = Enum.AutomaticSize
local HFA = Enum.HorizontalAlignment
local VFA = Enum.VerticalAlignment
local RSM = Enum.ResamplerMode

local FONT_ID = "rbxassetid://12187365364"

--=============================================================================
-- Library root
--=============================================================================

local Callisto = {}
Callisto.__index = Callisto

Callisto.Version = "1.0.0"
Callisto.Flags = {} :: { [string]: any }
Callisto.Windows = {} :: { any }
Callisto.Connections = {} :: { RBXScriptConnection }

--=============================================================================
-- Theme
--=============================================================================

-- Every colour the original file used, named. Derived accent/foreground shades
-- default to the exact literals from the dump so nothing shifts visually.
local DefaultTheme = {
	Background = RGB(24, 26, 27),
	Foreground = RGB(31, 34, 35),
	ForegroundLight = RGB(38, 41, 42),
	Border = RGB(45, 48, 49),
	Accent = RGB(0, 120, 255),
	AccentLight = RGB(77, 163, 255),
	AccentDark = RGB(0, 86, 178),
	Text = RGB(255, 255, 255),
}

Callisto.Theme = table.clone(DefaultTheme)

-- instance -> { property = themeKey }
local ColorRegistry: { [Instance]: { [string]: string } } = {}
-- gradient -> { {time, themeKey}, ... }
local GradientRegistry: { [UIGradient]: { { any } } } = {}
-- the running theme transition, if any
local ThemeTransition: RBXScriptConnection? = nil

local function Bind(instance: Instance, map: { [string]: string })
	ColorRegistry[instance] = map
	for property, key in next, map do
		pcall(function()
			(instance :: any)[property] = Callisto.Theme[key]
		end)
	end
end

local function BindGradient(gradient: UIGradient, stops: { { any } })
	GradientRegistry[gradient] = stops
	local keypoints = {}
	for _, stop in next, stops do
		TIS(keypoints, CSK(stop[1], Callisto.Theme[stop[2]]))
	end
	gradient.Color = CS(keypoints)
end

-- Paints every registered property/gradient at `alpha` between the previous
-- theme snapshot and the current one. Gradients are rebuilt keypoint-by-
-- keypoint, which is the only way to animate UIGradient.Color at all.
local function PaintTheme(alpha: number, previous: { [string]: Color3 })
	for instance, map in next, ColorRegistry do
		if not instance.Parent then
			ColorRegistry[instance] = nil
			continue
		end
		for property, key in next, map do
			pcall(function()
				(instance :: any)[property] = previous[key]:Lerp(Callisto.Theme[key], alpha)
			end)
		end
	end

	for gradient, stops in next, GradientRegistry do
		if not gradient.Parent then
			GradientRegistry[gradient] = nil
			continue
		end
		local keypoints = {}
		for _, stop in next, stops do
			TIS(keypoints, CSK(stop[1], previous[stop[2]]:Lerp(Callisto.Theme[stop[2]], alpha)))
		end
		gradient.Color = CS(keypoints)
	end
end

--[[
	SetTheme({ Accent = Color3.fromRGB(255, 80, 120) })

	Only pass the keys you care about. AccentLight / AccentDark / ForegroundLight
	are re-derived automatically unless you pass them explicitly — the derivation
	(+/- 30% toward white/black) reproduces the original literals for the default
	accent, so the stock look is preserved exactly.

	The repaint animates over ~0.25s (gradients included); pass `false` as the
	second argument for an instant swap.
]]
function Callisto:SetTheme(theme: { [string]: Color3 }, animate: boolean?)
	local previous = table.clone(self.Theme)

	for key, color in next, theme do
		if self.Theme[key] ~= nil then
			self.Theme[key] = color
		end
	end

	if theme.Accent and not theme.AccentLight then
		self.Theme.AccentLight = theme.Accent:Lerp(RGB(255, 255, 255), 0.3)
	end
	if theme.Accent and not theme.AccentDark then
		self.Theme.AccentDark = theme.Accent:Lerp(RGB(0, 0, 0), 0.3)
	end
	if theme.Foreground and not theme.ForegroundLight then
		self.Theme.ForegroundLight = theme.Foreground:Lerp(RGB(255, 255, 255), 0.03)
	end

	if ThemeTransition then
		ThemeTransition:Disconnect()
		ThemeTransition = nil
	end

	if animate == false then
		PaintTheme(1, previous)
		return
	end

	local elapsed = 0
	ThemeTransition = RunService.RenderStepped:Connect(function(dt)
		elapsed += dt
		local progress = MC(elapsed / 0.25, 0, 1)
		PaintTheme(1 - (1 - progress) ^ 3, previous) -- cubic ease-out
		if progress >= 1 and ThemeTransition then
			ThemeTransition:Disconnect()
			ThemeTransition = nil
		end
	end)
end

function Callisto:ResetTheme(animate: boolean?)
	self:SetTheme(table.clone(DefaultTheme), animate)
end

--=============================================================================
-- Utilities
--=============================================================================

local function Add(class: string, properties: { [string]: any }?): any
	local success, instance = pcall(Instance.new, class)
	if not success then
		return nil
	end

	if properties then
		-- Parent is applied last so a half-configured instance is never rendered.
		local parent = properties.Parent
		for key, value in next, properties do
			if key == "Parent" then
				continue
			end
			local ok, err = pcall(function()
				(instance :: any)[key] = value
			end)
			if not ok then
				warn(err)
			end
		end
		if parent then
			(instance :: any).Parent = parent
		end
	end

	return instance
end

-- Animation constants. One place to retune the whole library's feel.
local Anim = {
	Fast = TI(0.12, ES.Quad, ED.Out),
	Base = TI(0.18, ES.Quad, ED.Out),
	Slow = TI(0.28, ES.Quart, ED.Out),
	Spring = TI(0.35, ES.Back, ED.Out),
}

local function Tween(instance: Instance, info: TweenInfo, goal: { [string]: any }): Tween
	local tween = TweenService:Create(instance, info, goal)
	tween:Play()
	return tween
end

local function Connect(signal: RBXScriptSignal, callback)
	local connection = signal:Connect(callback)
	TIS(Callisto.Connections, connection)
	return connection
end

-- Fires callback(hovering: boolean).
local function Hover(button: GuiButton, callback: (boolean) -> ())
	Connect(button.MouseEnter, function()
		callback(true)
	end)
	Connect(button.MouseLeave, function()
		callback(false)
	end)
end

-- Standard press feedback: a short transparency dip. Never a size change.
local function Press(button: GuiButton)
	Connect(button.MouseButton1Down, function()
		Tween(button, Anim.Fast, { BackgroundTransparency = 0.15 })
	end)
	local function release()
		Tween(button, Anim.Base, { BackgroundTransparency = 0 })
	end
	Connect(button.MouseButton1Up, release)
	Connect(button.MouseLeave, release)
end

--=============================================================================
-- Fader — whole-tree fades without CanvasGroups
--
-- Fader.Out captures every descendant's rest transparency (only when the tree
-- is at rest, so interrupted animations never pollute the cache) and tweens
-- everything to fully transparent. Fader.In tweens everything back to the
-- captured values.
--=============================================================================

local Fader = {}

Fader.Properties = {
	Frame = { "BackgroundTransparency" },
	TextLabel = { "BackgroundTransparency", "TextTransparency" },
	TextButton = { "BackgroundTransparency", "TextTransparency" },
	TextBox = { "BackgroundTransparency", "TextTransparency" },
	ImageLabel = { "BackgroundTransparency", "ImageTransparency" },
	ImageButton = { "BackgroundTransparency", "ImageTransparency" },
	ScrollingFrame = { "BackgroundTransparency", "ScrollBarImageTransparency" },
	UIStroke = { "Transparency" },
	UIShadow = { "Transparency" },
}

-- root -> { instance -> { property -> restValue } }
Fader.Cache = {} :: { [Instance]: { [Instance]: { [string]: number } } }
-- root -> "shown" | "showing" | "hidden" (absent = shown, never faded)
Fader.State = {} :: { [Instance]: string }
-- root -> generation counter, so stale task.delay callbacks are ignored
Fader.Token = {} :: { [Instance]: number }

function Fader.Out(root: Instance, info: TweenInfo)
	local state = Fader.State[root]

	-- capture fresh rest values only when the tree is fully at rest; if we are
	-- interrupting a fade-in, the existing cache still holds the true values
	if state == nil or state == "shown" then
		local cache = {}
		local targets = root:GetDescendants()
		TIS(targets, root)
		for _, target in next, targets do
			local props = Fader.Properties[target.ClassName]
			if props then
				local values = {}
				for _, property in next, props do
					values[property] = (target :: any)[property]
				end
				cache[target] = values
			end
		end
		Fader.Cache[root] = cache
	end

	Fader.State[root] = "hidden"
	Fader.Token[root] = (Fader.Token[root] or 0) + 1

	-- zero-duration TweenService tweens apply a frame LATE, which breaks the
	-- park-transparent-then-fade-in pattern — instant fades set directly
	local instant = info.Time <= 0

	for target, values in next, Fader.Cache[root] do
		if target.Parent == nil and target ~= root then
			continue
		end
		if instant then
			for property in next, values do
				pcall(function()
					(target :: any)[property] = 1
				end)
			end
		else
			local goal = {}
			for property in next, values do
				goal[property] = 1
			end
			pcall(Tween, target, info, goal)
		end
	end
end

function Fader.In(root: Instance, info: TweenInfo)
	local cache = Fader.Cache[root]
	if not cache then
		return -- never faded out: already fully visible
	end

	local token = (Fader.Token[root] or 0) + 1
	Fader.Token[root] = token

	local instant = info.Time <= 0
	Fader.State[root] = instant and "shown" or "showing"

	for target, values in next, cache do
		if target.Parent == nil and target ~= root then
			continue
		end
		if instant then
			for property, value in next, values do
				pcall(function()
					(target :: any)[property] = value
				end)
			end
		else
			pcall(Tween, target, info, values)
		end
	end

	if not instant then
		task.delay(info.Time, function()
			if Fader.Token[root] == token and Fader.State[root] == "showing" then
				Fader.State[root] = "shown"
			end
		end)
	end
end

-- Drop every cached root that lives under `ancestor` (called before the
-- instances are destroyed, while ancestry is still intact).
function Fader.Forget(ancestor: Instance)
	for root in next, Fader.Cache do
		if root == ancestor or root:IsDescendantOf(ancestor) then
			Fader.Cache[root] = nil
			Fader.State[root] = nil
			Fader.Token[root] = nil
		end
	end
end

function Fader.Clear()
	table.clear(Fader.Cache)
	table.clear(Fader.State)
	table.clear(Fader.Token)
end

local function GetParentGui(): Instance
	-- gethui is an executor-injected global; reach it through the function
	-- environment so plain Luau tooling doesn't flag an unknown global
	local ok, hui = pcall(function()
		return ((getfenv() :: any).gethui)()
	end)
	if ok and hui then
		return hui
	end

	if RunService:IsStudio() then
		return LocalPlayer:WaitForChild("PlayerGui")
	end

	local success, core = pcall(function()
		return game:GetService("CoreGui")
	end)
	return (success and core) or LocalPlayer:WaitForChild("PlayerGui")
end

-- Draggable: smooth, frame-rate independent follow. The lerp loop only runs
-- while dragging (and briefly afterwards, to settle), so it never fights the
-- position tweens the open/close animations play on the same target.
local function MakeDraggable(handle: GuiObject, target: GuiObject)
	local dragging, dragStart, startPosition = false, Vector3.zero, UD2()
	local goal = target.Position
	local settling = false

	Connect(handle.InputBegan, function(input)
		if input.UserInputType == UIT.MouseButton1 or input.UserInputType == UIT.Touch then
			dragging = true
			settling = true
			dragStart = input.Position
			startPosition = target.Position
			goal = startPosition

			local connection
			connection = input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					dragging = false
					connection:Disconnect()
				end
			end)
		end
	end)

	Connect(UserInputService.InputChanged, function(input)
		if not dragging then
			return
		end
		if input.UserInputType ~= UIT.MouseMovement and input.UserInputType ~= UIT.Touch then
			return
		end
		local delta = input.Position - dragStart
		goal = UD2(
			startPosition.X.Scale,
			startPosition.X.Offset + delta.X,
			startPosition.Y.Scale,
			startPosition.Y.Offset + delta.Y
		)
	end)

	Connect(RunService.RenderStepped, function(dt)
		if not settling then
			return
		end

		local position = target.Position
		local settled = not dragging
			and math.abs(goal.X.Offset - position.X.Offset) < 0.5
			and math.abs(goal.Y.Offset - position.Y.Offset) < 0.5
			and math.abs(goal.X.Scale - position.X.Scale) < 0.001
			and math.abs(goal.Y.Scale - position.Y.Scale) < 0.001

		if settled then
			target.Position = goal
			settling = false
			return
		end

		target.Position = position:Lerp(goal, MC(dt * 20, 0, 1))
	end)
end

-- User-driven resizing. This changes Size, but it is direct manipulation of
-- the window by the user — not an animation — so it does not break the rule.
local function MakeResizable(handle: GuiButton, target: GuiObject, minimum: Vector2)
	local resizing, startPosition, startSize = false, Vector3.zero, V2()

	Connect(handle.InputBegan, function(input)
		if input.UserInputType == UIT.MouseButton1 or input.UserInputType == UIT.Touch then
			resizing = true
			startPosition = input.Position
			startSize = target.AbsoluteSize

			local connection
			connection = input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					resizing = false
					connection:Disconnect()
				end
			end)
		end
	end)

	Connect(UserInputService.InputChanged, function(input)
		if not resizing then
			return
		end
		if input.UserInputType ~= UIT.MouseMovement and input.UserInputType ~= UIT.Touch then
			return
		end
		local delta = input.Position - startPosition
		target.Size = UFO(
			math.max(minimum.X, MR(startSize.X + delta.X)),
			math.max(minimum.Y, MR(startSize.Y + delta.Y))
		)
	end)
end

--=============================================================================
-- Shared primitives — the exact decorations the dump applied over and over
--=============================================================================

local function Corner(parent: Instance, radius: number?): UICorner
	return Add("UICorner", { Parent = parent, CornerRadius = radius and UD(0, radius) or nil })
end

-- Fully rounded (capsule) corner — UD(1, 0).
local function Pill(parent: Instance): UICorner
	return Add("UICorner", { Parent = parent, CornerRadius = UD(1, 0) })
end

local function Stroke(parent: Instance, key: string?, inner: boolean?): UIStroke
	local stroke = Add("UIStroke", {
		Parent = parent,
		ApplyStrokeMode = ASM.Border,
		BorderStrokePosition = inner and BSP.Inner or nil,
	})
	Bind(stroke, { Color = key or "Border" })
	return stroke
end

-- UIShadow is not available on every client; Add() returns nil there and every
-- caller guards, so the library degrades to shadowless rendering gracefully.
local function Shadow(parent: Instance, transparency: number?, key: string?): any
	local shadow = Add("UIShadow", {
		Parent = parent,
		Transparency = transparency or 0.65,
		BlurRadius = UD(0, 10),
	})
	if shadow and key then
		Bind(shadow, { Color = key })
	end
	return shadow
end

-- IMPORTANT: UIGradient colours MULTIPLY with the element's BackgroundColor3.
-- The dump therefore gives every gradient carrier a plain white background so
-- the gradient's own colours render unmodified. These helpers enforce that —
-- theming flows entirely through the gradient keypoints, never the background.
local WHITE = RGB(255, 255, 255)

-- The "raised control" gradient every button/input/toggle shared.
local function SurfaceGradient(parent: Instance): UIGradient
	(parent :: any).BackgroundColor3 = WHITE
	local gradient = Add("UIGradient", { Parent = parent, Rotation = 90 })
	BindGradient(gradient, { { 0, "Foreground" }, { 1, "ForegroundLight" } })
	return gradient
end

local function AccentGradient(parent: Instance): UIGradient
	(parent :: any).BackgroundColor3 = WHITE
	local gradient = Add("UIGradient", { Parent = parent, Rotation = -90 })
	BindGradient(gradient, { { 0, "Accent" }, { 1, "AccentLight" } })
	return gradient
end

local function Padding(parent: Instance, top: number?, bottom: number?, left: number?, right: number?): UIPadding
	return Add("UIPadding", {
		Parent = parent,
		PaddingTop = UD(0, top or 0),
		PaddingBottom = UD(0, bottom or 0),
		PaddingLeft = UD(0, left or 0),
		PaddingRight = UD(0, right or 0),
	})
end

local function List(parent: Instance, properties: { [string]: any }?): UIListLayout
	local props: { [string]: any } = properties or {}
	props.Parent = parent
	props.SortOrder = props.SortOrder or SO.LayoutOrder
	return Add("UIListLayout", props)
end

local function Text(parent: Instance, properties: { [string]: any }): any
	local props = properties
	props.Parent = parent
	props.FontFace = props.FontFace or FN(FONT_ID, FW.SemiBold, FS.Normal)
	props.BackgroundTransparency = props.BackgroundTransparency or 1
	props.TextSize = props.TextSize or 14
	props.BorderSizePixel = 0

	-- ClassName is a pseudo-key for this helper, not a real property
	local class = props.ClassName or "TextLabel"
	props.ClassName = nil

	local color = props.TextColor3
	props.TextColor3 = nil

	local label = Add(class, props)
	if typeof(color) == "Color3" then
		label.TextColor3 = color
	else
		Bind(label, { TextColor3 = color or "Text" })
	end
	return label
end

-- Popup container: a plain Frame (NOT a CanvasGroup — those flatten gradients
-- over child text). Open/close fades run through the Fader.
-- Pass a theme key for a solid background; omit it when the popup carries a
-- colour gradient (the gradient helper will set the white base itself).
local function PopupFrame(parent: Instance, name: string, backgroundKey: string?): any
	local frame = Add("Frame", {
		Parent = parent,
		Name = name,
		Visible = false,
		ClipsDescendants = true,
		BorderSizePixel = 0,
		ZIndex = 40,
	})
	if backgroundKey then
		Bind(frame, { BackgroundColor3 = backgroundKey })
	end
	return frame
end

-- Converts an on-screen point into a Position local to `holder`. Popups are
-- parented to the Externals frame, whose origin is NOT the screen origin on an
-- IgnoreGuiInset ScreenGui — subtracting the holder's own AbsolutePosition
-- makes the maths inset-proof.
local function ToHolderSpace(holder: Instance, x: number, y: number): UDim2
	local origin: Vector2 = (holder :: any).AbsolutePosition
	return UFO(MR(x - origin.X), MR(y - origin.Y))
end

-- Shared open/close animation for popups: Fader cascade + an 8px vertical
-- slide. Position and transparency only; the popup's size is set before
-- opening and never animated.
local function AnimatePopup(popup: GuiObject, open: boolean, basePosition: UDim2)
	if open then
		popup.Position = basePosition + UD2(0, 0, 0, 8)
		popup.Visible = true
		Tween(popup, Anim.Slow, { Position = basePosition })
		Fader.In(popup, Anim.Slow)
	else
		Fader.Out(popup, Anim.Base)
		local tween = Tween(popup, Anim.Base, { Position = basePosition + UD2(0, 0, 0, 8) })
		tween.Completed:Once(function()
			if Fader.State[popup] == "hidden" then
				popup.Visible = false
			end
		end)
	end
end

local function InsideBounds(mouse: Vector2, object: GuiObject): boolean
	local topLeft = object.AbsolutePosition
	local bottomRight = topLeft + object.AbsoluteSize
	return mouse.X >= topLeft.X and mouse.X <= bottomRight.X
		and mouse.Y >= topLeft.Y and mouse.Y <= bottomRight.Y
end

--=============================================================================
-- Sub-elements (things that live in a row's right-hand content)
--=============================================================================

local SubElement = {}

-- Toggle: pill switch. Off = Toggle template, On = ToggleE template.
-- The knob slides (position) and everything else crossfades; nothing resizes.
function SubElement.Toggle(parent: Instance, default: boolean, callback: (boolean) -> ())
	local state = default and true or false

	local button = Add("TextButton", {
		Parent = parent,
		Text = "",
		AutoButtonColor = false,
		Name = "Toggle",
		Size = UFO(26, 16),
		BorderSizePixel = 0,
	})
	Pill(button)
	SurfaceGradient(button)
	local outerStroke = Stroke(button, "Border", true)
	local glow = Shadow(button, 0.65, "Accent")

	-- accent fill, faded in when active
	local fill = Add("Frame", {
		Parent = button,
		Name = "Gradient",
		BackgroundTransparency = 1,
		Size = UFS(1, 1),
		BorderSizePixel = 0,
		ZIndex = 2,
	})
	Pill(fill)
	AccentGradient(fill)
	local fillStroke = Stroke(fill, "AccentLight", true)
	fillStroke.Transparency = 1

	local knob = Add("Frame", {
		Parent = button,
		AnchorPoint = V2(0, 0.5),
		Name = "Indicator",
		BackgroundTransparency = 0.8,
		Position = UD2(0, 2, 0.5, 0),
		Size = UFO(12, 12),
		ZIndex = 3,
		BorderSizePixel = 0,
		BackgroundColor3 = RGB(255, 255, 255),
	})
	Pill(knob)

	local function render(animate: boolean?)
		local info = animate == false and TI(0) or Anim.Base
		Tween(fill, info, { BackgroundTransparency = state and 0 or 1 })
		Tween(fillStroke, info, { Transparency = state and 0 or 1 })
		Tween(outerStroke, info, { Transparency = state and 1 or 0 })
		Tween(knob, state and Anim.Spring or Anim.Base, {
			Position = state and UD2(1, -14, 0.5, 0) or UD2(0, 2, 0.5, 0),
			BackgroundTransparency = state and 0 or 0.8,
		})
		if glow then
			Tween(glow, info, { Transparency = state and 0.65 or 1 })
		end
	end

	render(false)

	Connect(button.MouseButton1Click, function()
		state = not state
		render()
		task.spawn(callback, state)
	end)

	-- hover feedback: knob brightens slightly (transparency only)
	Hover(button, function(hovering)
		if state then
			return -- already fully opaque when on
		end
		Tween(knob, Anim.Fast, { BackgroundTransparency = hovering and 0.6 or 0.8 })
	end)

	return {
		Instance = button,
		Get = function()
			return state
		end,
		Set = function(_, value: boolean)
			state = value and true or false
			render()
			task.spawn(callback, state)
		end,
	}
end

-- Checkbox: square with a tick. Off = Checkbox, On = CheckboxE.
-- The tick fades in while springing from a slight rotation — no size change.
function SubElement.Checkbox(parent: Instance, default: boolean, callback: (boolean) -> ())
	local state = default and true or false

	local button = Add("TextButton", {
		Parent = parent,
		Text = "",
		AutoButtonColor = false,
		Name = "Checkbox",
		Size = UFO(16, 16),
		BorderSizePixel = 0,
	})
	Corner(button, 3)
	SurfaceGradient(button)
	local outerStroke = Stroke(button, "Border", true)
	local glow = Shadow(button, 1, "Accent")

	local fill = Add("Frame", {
		Parent = button,
		Name = "Gradient",
		BackgroundTransparency = 1,
		Size = UFS(1, 1),
		BorderSizePixel = 0,
	})
	Corner(fill, 3)
	AccentGradient(fill)
	local fillStroke = Stroke(fill, "AccentLight", true)
	fillStroke.Transparency = 1

	local icon = Add("ImageLabel", {
		Parent = button,
		ScaleType = SCL.Fit,
		Name = "Icon",
		ResampleMode = RSM.Pixelated,
		AnchorPoint = V2(0.5, 0.5),
		Image = "rbxassetid://114424333378875",
		BackgroundTransparency = 1,
		ImageTransparency = 1,
		Rotation = -60,
		Position = UFS(0.5, 0.5),
		Size = UFO(10, 10),
		ZIndex = 2,
		BorderSizePixel = 0,
	})

	local function render(animate: boolean?)
		local info = animate == false and TI(0) or Anim.Base
		Tween(fill, info, { BackgroundTransparency = state and 0 or 1 })
		Tween(fillStroke, info, { Transparency = state and 0 or 1 })
		Tween(outerStroke, info, { Transparency = state and 1 or 0 })
		Tween(icon, info, { ImageTransparency = state and 0 or 1 })
		Tween(icon, animate == false and TI(0) or (state and Anim.Spring or Anim.Fast), {
			Rotation = state and 0 or -60,
		})
		if glow then
			Tween(glow, info, { Transparency = state and 0.65 or 1 })
		end
	end

	render(false)

	Connect(button.MouseButton1Click, function()
		state = not state
		render()
		task.spawn(callback, state)
	end)

	return {
		Instance = button,
		Get = function()
			return state
		end,
		Set = function(_, value: boolean)
			state = value and true or false
			render()
			task.spawn(callback, state)
		end,
	}
end

--=============================================================================
-- Colorpicker popup (Externals.Colorpicker)
--=============================================================================

local function BuildColorpicker(holder: Instance, swatch: GuiButton, default: Color3, defaultAlpha: number, callback)
	local hue, saturation, value = default:ToHSV()
	local alpha = defaultAlpha or 0

	local panel = PopupFrame(holder, "Colorpicker", "Background")
	panel.Size = UFO(203, 207)
	panel.ZIndex = 50
	Corner(panel, 5)
	Stroke(panel, "Border", true)
	Shadow(panel, 0.65)
	Padding(panel, 10, 10, 10, 10)

	local preview = Add("Frame", {
		Parent = panel,
		Name = "Indicator",
		Size = UFO(16, 16),
		BorderSizePixel = 0,
		ZIndex = 51,
	})
	Pill(preview)
	Shadow(preview, 0.65)

	local hueBar = Add("TextButton", {
		Parent = panel,
		Text = "",
		AutoButtonColor = false,
		Name = "Hue",
		Position = UFO(26, 0),
		Size = UD2(1, -26, 0, 16),
		BorderSizePixel = 0,
		ZIndex = 51,
	})
	Pill(hueBar)
	Add("UIGradient", {
		Parent = hueBar,
		Color = CS({
			CSK(0, RGB(255, 0, 0)),
			CSK(0.16, RGB(255, 255, 0)),
			CSK(0.3, RGB(0, 255, 0)),
			CSK(0.5, RGB(0, 255, 255)),
			CSK(0.66, RGB(0, 0, 255)),
			CSK(0.83, RGB(255, 0, 255)),
			CSK(1, RGB(255, 0, 0)),
		}),
	})
	Shadow(hueBar, 0.65)

	-- Selectors must never sink input: once a click parks one under the
	-- cursor, an Active selector would swallow every following press and the
	-- track would stop receiving drags.
	local hueSelector = Add("TextButton", {
		Parent = hueBar,
		Text = "",
		Active = false,
		Selectable = false,
		AnchorPoint = V2(0, 0.5),
		Name = "Selector",
		Position = UD2(0, 1, 0.5, 0),
		Size = UFO(10, 10),
		BackgroundColor3 = RGB(255, 0, 0),
		BorderSizePixel = 0,
		ZIndex = 52,
	})
	Pill(hueSelector)
	Add("UIStroke", {
		Parent = hueSelector,
		Thickness = 2,
		BorderOffset = UD(0, 1),
		Color = RGB(255, 255, 255),
		ApplyStrokeMode = ASM.Border,
	})

	local alphaBar = Add("TextButton", {
		Parent = panel,
		Text = "",
		AutoButtonColor = false,
		AnchorPoint = V2(0, 1),
		Name = "Alpha",
		Position = UFS(0, 1),
		Size = UD2(0, 16, 1, -26),
		BorderSizePixel = 0,
		ZIndex = 51,
	})
	Pill(alphaBar)
	Shadow(alphaBar, 0.65)

	local alphaOverlay = Add("Frame", {
		Parent = alphaBar,
		Name = "_",
		Size = UD2(1, 0, 1, 1),
		BackgroundColor3 = RGB(255, 255, 255),
		BorderSizePixel = 0,
		ZIndex = 51,
	})
	Add("UIGradient", {
		Parent = alphaOverlay,
		Rotation = -90,
		Transparency = NS({ NSK(0, 0), NSK(1, 1) }),
		Color = CS({ CSK(0, RGB(0, 0, 0)), CSK(1, RGB(255, 255, 255)) }),
	})
	Pill(alphaOverlay)

	local alphaSelector = Add("TextButton", {
		Parent = alphaBar,
		Text = "",
		Active = false,
		Selectable = false,
		AnchorPoint = V2(0.5, 0),
		Name = "Selector",
		Position = UD2(0.5, 0, 0, 1),
		Size = UFO(10, 10),
		BorderSizePixel = 0,
		ZIndex = 52,
	})
	Pill(alphaSelector)
	Add("UIStroke", {
		Parent = alphaSelector,
		Thickness = 2,
		BorderOffset = UD(0, 1),
		Color = RGB(255, 255, 255),
		ApplyStrokeMode = ASM.Border,
	})

	local sv = Add("Frame", {
		Parent = panel,
		Name = "SV",
		Position = UFO(26, 26),
		Size = UD2(1, -26, 1, -26),
		BackgroundColor3 = RGB(255, 255, 255),
		BorderSizePixel = 0,
		ZIndex = 51,
	})
	Corner(sv, 5)
	local svGradient = Add("UIGradient", {
		Parent = sv,
		Color = CS({ CSK(0, RGB(255, 255, 255)), CSK(1, RGB(255, 0, 0)) }),
	})
	Shadow(sv, 0.65)

	local svOverlay = Add("Frame", {
		Parent = sv,
		Name = "_",
		Size = UFS(1, 1),
		BackgroundColor3 = RGB(0, 0, 0),
		BorderSizePixel = 0,
		ZIndex = 51,
	})
	Add("UIGradient", {
		Parent = svOverlay,
		Rotation = -90,
		Transparency = NS({ NSK(0, 0), NSK(1, 1) }),
		Color = CS({ CSK(0, RGB(0, 0, 0)), CSK(1, RGB(0, 0, 0)) }),
	})
	Add("UICorner", {
		Parent = svOverlay,
		TopLeftRadius = UD(0, 5),
		TopRightRadius = UD(0, 5),
		BottomRightRadius = UD(0, 4),
		BottomLeftRadius = UD(0, 4),
	})

	local svSelector = Add("TextButton", {
		Parent = sv,
		Text = "",
		Active = false,
		Selectable = false,
		AnchorPoint = V2(1, 0),
		Name = "Selector",
		Position = UD2(1, -1, 0, 1),
		Size = UFO(10, 10),
		BorderSizePixel = 0,
		ZIndex = 52,
	})
	Pill(svSelector)
	Add("UIStroke", {
		Parent = svSelector,
		Thickness = 2,
		BorderOffset = UD(0, 1),
		Color = RGB(255, 255, 255),
		ApplyStrokeMode = ASM.Border,
	})

	local function render(animate: boolean?)
		local color = HSV(hue, saturation, value)
		local info = animate == false and TI(0) or Anim.Fast

		Tween(swatch, info, { BackgroundColor3 = color, BackgroundTransparency = alpha })
		Tween(preview, info, { BackgroundColor3 = color, BackgroundTransparency = alpha })
		Tween(alphaBar, info, { BackgroundColor3 = color })
		Tween(alphaSelector, info, { BackgroundColor3 = color })
		Tween(hueSelector, info, { BackgroundColor3 = HSV(hue, 1, 1) })
		Tween(svSelector, info, { BackgroundColor3 = color })

		svGradient.Color = CS({ CSK(0, RGB(255, 255, 255)), CSK(1, HSV(hue, 1, 1)) })

		-- Selector travel: the 10px knob plus a 1px margin each side must stay
		-- inside the track, so the pixel offset counter-travels 12px across the
		-- full scale range (at scale 0 the offset is +1/+11, at scale 1 it is
		-- -11/-1 depending on the anchor).
		Tween(hueSelector, info, { Position = UD2(hue, 1 - 12 * hue, 0.5, 0) })
		Tween(alphaSelector, info, { Position = UD2(0.5, 0, alpha, 1 - 12 * alpha) })
		Tween(svSelector, info, {
			Position = UD2(saturation, 11 - 12 * saturation, 1 - value, 1 - 12 * (1 - value)),
		})

		task.spawn(callback, color, alpha)
	end

	-- Generic click-and-drag binding for the three tracks.
	local function BindTrack(track: GuiObject, apply: (Vector2) -> ())
		local dragging = false

		local function update(position: Vector3 | Vector2)
			local absolutePosition = track.AbsolutePosition
			local absoluteSize = track.AbsoluteSize
			apply(V2(
				MC((position.X - absolutePosition.X) / absoluteSize.X, 0, 1),
				MC((position.Y - absolutePosition.Y) / absoluteSize.Y, 0, 1)
			))
		end

		Connect(track.InputBegan, function(input)
			if input.UserInputType == UIT.MouseButton1 or input.UserInputType == UIT.Touch then
				dragging = true
				update(input.Position)
			end
		end)
		Connect(UserInputService.InputEnded, function(input)
			if input.UserInputType == UIT.MouseButton1 or input.UserInputType == UIT.Touch then
				dragging = false
			end
		end)
		Connect(UserInputService.InputChanged, function(input)
			if not dragging then
				return
			end
			if input.UserInputType == UIT.MouseMovement or input.UserInputType == UIT.Touch then
				update(input.Position)
			end
		end)
	end

	BindTrack(hueBar, function(position)
		hue = position.X
		render()
	end)
	BindTrack(alphaBar, function(position)
		alpha = position.Y
		render()
	end)
	BindTrack(sv, function(position)
		saturation = position.X
		value = 1 - position.Y
		render()
	end)

	local open = false
	local function setOpen(shouldOpen: boolean)
		if open == shouldOpen then
			return
		end
		open = shouldOpen

		local absolutePosition = swatch.AbsolutePosition
		local base = ToHolderSpace(holder, absolutePosition.X - 187, absolutePosition.Y + 22)
		AnimatePopup(panel, open, base)
	end

	Connect(swatch.MouseButton1Click, function()
		setOpen(not open)
	end)

	-- Click-away closes the popup.
	Connect(UserInputService.InputBegan, function(input, processed)
		if processed or not open then
			return
		end
		if input.UserInputType ~= UIT.MouseButton1 and input.UserInputType ~= UIT.Touch then
			return
		end
		local mouse = V2(input.Position.X, input.Position.Y)
		if not InsideBounds(mouse, panel) and not InsideBounds(mouse, swatch) then
			setOpen(false)
		end
	end)

	render(false)

	-- prime the fader: capture rest values now that the panel is fully built,
	-- and park everything transparent for the first fade-in
	Fader.Out(panel, TI(0))

	return {
		Panel = panel,
		Close = function()
			setOpen(false)
		end,
		Get = function()
			return HSV(hue, saturation, value), alpha
		end,
		Set = function(_, color: Color3, newAlpha: number?)
			hue, saturation, value = color:ToHSV()
			alpha = newAlpha or alpha
			render()
		end,
	}
end

--=============================================================================
-- Section — holds elements
--=============================================================================

local Section = {}
Section.__index = Section

-- Every labelled control (toggle/checkbox/colorpicker/keybind) shares this row.
function Section:_Row(title: string)
	local row = Add("Frame", {
		Parent = self.Content,
		Name = "Label",
		BackgroundTransparency = 1,
		Size = UFS(1, 0),
		AutomaticSize = AT.Y,
		BorderSizePixel = 0,
		LayoutOrder = self:_Order(),
	})

	local left = Add("Frame", {
		Parent = row,
		AnchorPoint = V2(0, 0.5),
		Name = "LeftContent",
		BackgroundTransparency = 1,
		Position = UFS(0, 0.5),
		Size = UFS(1, 0),
		AutomaticSize = AT.XY,
		BorderSizePixel = 0,
	})
	List(left, { Padding = UD(0, 7), FillDirection = FD.Horizontal })

	local label = Text(left, {
		Name = "Label",
		LayoutOrder = 1,
		Text = title,
		TextTruncate = ETT.SplitWord,
		AutomaticSize = AT.XY,
	})

	local right = Add("Frame", {
		Parent = row,
		AnchorPoint = V2(1, 0),
		BackgroundTransparency = 1,
		Position = UFS(1, 0),
		Name = "RightContent",
		AutomaticSize = AT.XY,
		BorderSizePixel = 0,
	})
	List(right, { VerticalAlignment = VFA.Center, FillDirection = FD.Horizontal, Padding = UD(0, 5) })

	return row, left, right, label
end

function Section:_Order(): number
	self._order = (self._order or 0) + 1
	return self._order
end

--== Button ===================================================================

--[[
	Section:AddButton({ Title = "single button", Callback = function() end })
	Section:AddButton({ Buttons = { {Title="a",Callback=f}, {Title="b",Callback=g} } })
]]
function Section:AddButton(options: { [string]: any })
	local list = options.Buttons or { options }

	local container = Add("Frame", {
		Parent = self.Content,
		Active = true,
		Selectable = true,
		BackgroundTransparency = 1,
		Name = "Button",
		Size = UD2(1, 0, 0, 25),
		BorderSizePixel = 0,
		LayoutOrder = self:_Order(),
	})
	Corner(container, 5)
	List(container, {
		VerticalAlignment = VFA.Center,
		FillDirection = FD.Horizontal,
		HorizontalAlignment = HFA.Center,
		HorizontalFlex = UFA.Fill,
		Padding = UD(0, 5),
	})

	local built = {}
	for index, entry in ipairs(list) do
		local button = Add("TextButton", {
			Parent = container,
			Text = "",
			AutoButtonColor = false,
			Name = "Button",
			TextTruncate = ETT.AtEnd,
			Size = UD2(1, 0, 0, 25),
			LayoutOrder = index,
			BorderSizePixel = 0,
		})
		Corner(button, 5)
		Shadow(button, 0.65)
		local stroke = Stroke(button, "Border", true)
		SurfaceGradient(button)

		-- accent flash layer: blinks in on click, then bleeds back out.
		-- Transparency only — the button never moves or resizes.
		local flash = Add("Frame", {
			Parent = button,
			Name = "Flash",
			BackgroundTransparency = 1,
			Size = UFS(1, 1),
			ZIndex = 2,
			BorderSizePixel = 0,
		})
		Corner(flash, 5)
		AccentGradient(flash)
		local flashStroke = Stroke(flash, "AccentLight", true)
		flashStroke.Transparency = 1

		local label = Text(button, {
			Name = "Label",
			Text = entry.Title or entry.Name or "Button",
			TextTransparency = 0.5,
			Size = UFS(1, 1),
			TextTruncate = ETT.SplitWord,
			ZIndex = 3,
		})
		Padding(label, 0, 1)

		Hover(button, function(hovering)
			Tween(label, Anim.Base, { TextTransparency = hovering and 0 or 0.5 })
			Tween(stroke, Anim.Base, { Color = hovering and Callisto.Theme.Accent or Callisto.Theme.Border })
		end)
		Press(button)

		Connect(button.MouseButton1Click, function()
			flash.BackgroundTransparency = 0.25
			flashStroke.Transparency = 0.25
			Tween(flash, Anim.Slow, { BackgroundTransparency = 1 })
			Tween(flashStroke, Anim.Slow, { Transparency = 1 })
			if entry.Callback then
				task.spawn(entry.Callback)
			end
		end)

		TIS(built, { Instance = button, Label = label })
	end

	return { Instance = container, Buttons = built }
end

--== Label ====================================================================

function Section:AddLabel(options: { [string]: any } | string)
	local opts: { [string]: any } = typeof(options) == "string" and { Title = options } or (options :: any)
	local row, _, _, label = self:_Row(opts.Title or "Label")

	return {
		Instance = row,
		Set = function(_, value: string)
			label.Text = value
		end,
	}
end

--== Toggle ===================================================================

function Section:AddToggle(options: { [string]: any })
	local row, _, right = self:_Row(options.Title or "Toggle")
	local flag = options.Flag

	local function fire(state: boolean)
		if flag then
			Callisto.Flags[flag] = state
		end
		if options.Callback then
			options.Callback(state)
		end
	end

	local control: any
	if options.Style == "Checkbox" then
		control = SubElement.Checkbox(right, options.Default or false, fire)
	else
		control = SubElement.Toggle(right, options.Default or false, fire)
	end

	if flag then
		Callisto.Flags[flag] = options.Default or false
	end

	control.Instance.LayoutOrder = 2
	control.Row = row
	return control
end

function Section:AddCheckbox(options: { [string]: any })
	options.Style = "Checkbox"
	return self:AddToggle(options)
end

--== Colorpicker ==============================================================

function Section:AddColorpicker(options: { [string]: any })
	local row, _, right = self:_Row(options.Title or "Colorpicker")
	local flag = options.Flag

	local swatch = Add("TextButton", {
		Parent = right,
		Text = "",
		AutoButtonColor = false,
		Name = "Colorpicker",
		Size = UFO(16, 16),
		LayoutOrder = 2,
		BorderSizePixel = 0,
	})
	-- deliberately NOT theme-bound: the swatch shows the picked colour, so a
	-- later SetTheme must not overwrite it
	swatch.BackgroundColor3 = options.Default or Callisto.Theme.Accent
	Pill(swatch)
	-- hover ring: accent-themed (the dump's hardcoded purple clashed with any
	-- theme) and driven by GuiState, which unlike MouseEnter/MouseLeave cannot
	-- miss the leave event and leave the ring stuck on
	local swatchStroke = Add("UIStroke", {
		Parent = swatch,
		Transparency = 1,
		BorderOffset = UD(0, 1),
		ApplyStrokeMode = ASM.Border,
	})
	Bind(swatchStroke, { Color = "Accent" })

	Connect(swatch:GetPropertyChangedSignal("GuiState"), function()
		local hovering = swatch.GuiState == EGS.Hover or swatch.GuiState == EGS.Press
		Tween(swatchStroke, Anim.Fast, { Transparency = hovering and 0 or 1 })
	end)

	local picker: any = BuildColorpicker(
		self.Window.Externals,
		swatch,
		options.Default or Callisto.Theme.Accent,
		options.Alpha or 0,
		function(color, alpha)
			if flag then
				Callisto.Flags[flag] = color
			end
			if options.Callback then
				options.Callback(color, alpha)
			end
		end
	)

	picker.Row = row
	return picker
end

--== Keybind ==================================================================

local KeybindBlacklist = {
	[EKC.Unknown] = true,
}

function Section:AddKeybind(options: { [string]: any })
	local _, left = self:_Row(options.Title or "Keybind")
	local current: EnumItem? = options.Default
	local binding = false

	local button = Text(left, {
		ClassName = "TextButton",
		LayoutOrder = 2,
		-- the dump had Active = false (static mockup); it must be true to click
		Active = true,
		Selectable = false,
		TextTruncate = ETT.SplitWord,
		Name = "Keybind",
		Text = current and current.Name:upper() or "NONE",
		TextTransparency = 0.5,
		AutomaticSize = AT.XY,
		AutoButtonColor = false,
	})

	local function render()
		button.Text = binding and "..." or (current and current.Name:upper() or "NONE")
		Tween(button, Anim.Fast, { TextTransparency = binding and 0 or 0.5 })
	end

	Connect(button.MouseButton1Click, function()
		binding = true
		render()
	end)

	Hover(button, function(hovering)
		if not binding then
			Tween(button, Anim.Fast, { TextTransparency = hovering and 0.2 or 0.5 })
		end
	end)

	Connect(UserInputService.InputBegan, function(input, processed)
		if binding then
			if input.UserInputType == UIT.Keyboard and not KeybindBlacklist[input.KeyCode] then
				-- Backspace clears the bind. `x and nil or y` cannot express this
				-- in Lua (nil is falsy), so it has to be a real branch.
				if input.KeyCode == EKC.Backspace then
					current = nil
				else
					current = input.KeyCode
				end
				binding = false
				render()
				if options.Flag then
					Callisto.Flags[options.Flag] = current
				end
			end
			return
		end

		if processed or not current then
			return
		end
		if input.UserInputType == UIT.Keyboard and input.KeyCode == current and options.Callback then
			task.spawn(options.Callback, current)
		end
	end)

	render()

	return {
		Instance = button,
		Get = function()
			return current
		end,
		Set = function(_, key: EnumItem?)
			current = key
			render()
		end,
	}
end

--== Slider ===================================================================

function Section:AddSlider(options: { [string]: any })
	local minimum = options.Min or 0
	local maximum = options.Max or 100
	local decimals = options.Decimals or 0
	local suffix = options.Suffix or "%"
	local value = MC(options.Default or minimum, minimum, maximum)

	local container = Add("Frame", {
		Parent = self.Content,
		Name = "Slider",
		BackgroundTransparency = 1,
		Size = UFS(1, 0),
		AutomaticSize = AT.Y,
		BorderSizePixel = 0,
		LayoutOrder = self:_Order(),
	})
	List(container, { Padding = UD(0, 5) })

	local textHolder = Add("Frame", {
		Parent = container,
		AnchorPoint = V2(0, 0.5),
		Name = "TextHolder",
		BackgroundTransparency = 1,
		Position = UFS(0, 0.5),
		Size = UFS(1, 0),
		AutomaticSize = AT.XY,
		BorderSizePixel = 0,
	})
	List(textHolder, {
		FillDirection = FD.Horizontal,
		HorizontalFlex = UFA.SpaceBetween,
		Padding = UD(0, 7),
	})

	local title = Text(textHolder, {
		Name = "Title",
		LayoutOrder = 1,
		Text = options.Title or "slider",
		TextTruncate = ETT.SplitWord,
		AutomaticSize = AT.XY,
	})
	Padding(title, -3, -1)

	local current = Text(textHolder, {
		Name = "Current",
		LayoutOrder = 1,
		Text = "0" .. suffix,
		TextTruncate = ETT.SplitWord,
		AutomaticSize = AT.XY,
	})
	Padding(current, -3, -1)

	local track = Add("TextButton", {
		Parent = container,
		LayoutOrder = 1,
		Text = "",
		AutoButtonColor = false,
		Name = "Button",
		Size = UD2(1, 0, 0, 16),
		BorderSizePixel = 0,
	})
	Corner(track, 5)
	local trackStroke = Stroke(track, "Border", true)
	SurfaceGradient(track)

	local fill = Add("Frame", {
		Parent = track,
		Name = "Fill",
		Size = UD2(0, 0, 1, 0),
		BorderSizePixel = 0,
	})
	Corner(fill, 5)
	AccentGradient(fill)
	Shadow(fill, 0.65, "Accent")

	local function round(number: number): number
		local multiplier = 10 ^ decimals
		return MF(number * multiplier + 0.5) / multiplier
	end

	-- The fill's Size is the value readout — data, not decoration — so it is
	-- set instantly, never tweened. Dragging updates it every frame anyway.
	local function render()
		local progress = (value - minimum) / (maximum - minimum)
		fill.Size = UD2(progress, 0, 1, 0)
		current.Text = tostring(round(value)) .. suffix
	end

	local function set(newValue: number, silent: boolean?)
		value = MC(round(newValue), minimum, maximum)
		render()
		if options.Flag then
			Callisto.Flags[options.Flag] = value
		end
		if options.Callback and not silent then
			task.spawn(options.Callback, value)
		end
	end

	local dragging = false
	local function updateFromInput(position: Vector3 | Vector2)
		local progress = MC((position.X - track.AbsolutePosition.X) / track.AbsoluteSize.X, 0, 1)
		set(minimum + (maximum - minimum) * progress)
	end

	Connect(track.InputBegan, function(input)
		if input.UserInputType == UIT.MouseButton1 or input.UserInputType == UIT.Touch then
			dragging = true
			updateFromInput(input.Position)
		end
	end)
	Connect(UserInputService.InputEnded, function(input)
		if input.UserInputType == UIT.MouseButton1 or input.UserInputType == UIT.Touch then
			dragging = false
		end
	end)
	Connect(UserInputService.InputChanged, function(input)
		if dragging and (input.UserInputType == UIT.MouseMovement or input.UserInputType == UIT.Touch) then
			updateFromInput(input.Position)
		end
	end)

	-- hover feedback: stroke tint only
	Hover(track, function(hovering)
		Tween(trackStroke, Anim.Base, {
			Color = hovering and Callisto.Theme.Accent or Callisto.Theme.Border,
		})
	end)

	set(value, true)

	return {
		Instance = container,
		Get = function()
			return value
		end,
		Set = function(_, newValue: number)
			set(newValue)
		end,
	}
end

--== Input ====================================================================

function Section:AddInput(options: { [string]: any })
	local container = Add("Frame", {
		Parent = self.Content,
		Name = "Input",
		BackgroundTransparency = 1,
		Size = UFS(1, 0),
		AutomaticSize = AT.Y,
		BorderSizePixel = 0,
		LayoutOrder = self:_Order(),
	})
	List(container, { VerticalAlignment = VFA.Center, Padding = UD(0, 3) })
	Padding(container, 1)

	local title = Text(container, {
		Name = "Title",
		Text = options.Title or "Input",
		TextTransparency = 0.3,
		Position = UFO(21, 0),
		TextTruncate = ETT.SplitWord,
		AutomaticSize = AT.XY,
	})
	Padding(title, -5, -1)

	local box = Add("Frame", {
		Parent = container,
		LayoutOrder = 1,
		Active = true,
		Selectable = true,
		Name = "Button",
		Size = UD2(1, 0, 0, 25),
		BorderSizePixel = 0,
	})
	Corner(box, 5)
	local stroke = Stroke(box, "Border", true)
	Padding(box, 0, 0, 7, 7)
	Shadow(box, 0.65)
	SurfaceGradient(box)

	local input = Text(box, {
		ClassName = "TextBox",
		Name = "TextLabel",
		Text = options.Default or "",
		Size = UFS(1, 1),
		Selectable = false,
		TextXAlignment = TXA.Left,
		TextTruncate = ETT.SplitWord,
		Active = false,
		PlaceholderText = options.Placeholder or "something here....",
		ClearTextOnFocus = options.ClearOnFocus ~= false,
	})

	Connect(input.Focused, function()
		Tween(stroke, Anim.Base, { Color = Callisto.Theme.Accent })
	end)
	Connect(input.FocusLost, function(enter)
		Tween(stroke, Anim.Base, { Color = Callisto.Theme.Border })
		if options.Flag then
			Callisto.Flags[options.Flag] = input.Text
		end
		if options.Callback and (enter or not options.OnEnter) then
			task.spawn(options.Callback, input.Text, enter)
		end
	end)

	return {
		Instance = container,
		Get = function()
			return input.Text
		end,
		Set = function(_, value: string)
			input.Text = value
		end,
	}
end

--== Dropdown =================================================================

function Section:AddDropdown(options: { [string]: any })
	local values = options.Values or options.Options or {}
	local multi = options.Multi or options.MultiSelect or false
	local selected: { string } = {}

	if options.Default then
		if typeof(options.Default) == "table" then
			for _, item in next, options.Default do
				TIS(selected, item)
			end
		else
			TIS(selected, options.Default)
		end
	end

	local container = Add("Frame", {
		Parent = self.Content,
		Name = "Dropdown",
		BackgroundTransparency = 1,
		Size = UFS(1, 0),
		AutomaticSize = AT.Y,
		BorderSizePixel = 0,
		LayoutOrder = self:_Order(),
	})
	List(container, { VerticalAlignment = VFA.Center, Padding = UD(0, 3) })
	Padding(container, 1)

	local title = Text(container, {
		Name = "Title",
		Text = options.Title or "Dropdown",
		TextTransparency = 0.3,
		Position = UFO(21, 0),
		TextTruncate = ETT.SplitWord,
		AutomaticSize = AT.XY,
	})
	Padding(title, -5, -1)

	local button = Add("TextButton", {
		Parent = container,
		LayoutOrder = 1,
		Text = "",
		AutoButtonColor = false,
		Size = UD2(1, 0, 0, 25),
		Name = "Button",
		TextXAlignment = TXA.Left,
		TextTruncate = ETT.SplitWord,
		BorderSizePixel = 0,
	})
	Corner(button, 5)
	local stroke = Stroke(button, "Border", true)
	Padding(button, 0, 0, 7, 7)
	Shadow(button, 0.65)
	SurfaceGradient(button)
	List(button, {
		VerticalAlignment = VFA.Center,
		HorizontalFlex = UFA.Fill,
		FillDirection = FD.Horizontal,
	})

	local display = Text(button, {
		Text = "",
		Size = UFS(0, 1),
		TextXAlignment = TXA.Left,
		TextTruncate = ETT.SplitWord,
		AutomaticSize = AT.X,
	})

	local icon = Add("ImageLabel", {
		Parent = button,
		ScaleType = SCL.Fit,
		Name = "Icon",
		ResampleMode = RSM.Pixelated,
		AnchorPoint = V2(0.5, 0.5),
		Image = "rbxassetid://77930667227229",
		BackgroundTransparency = 1,
		Position = UFS(0.5, 0.5),
		Size = UFO(10, 10),
		ZIndex = 2,
		BorderSizePixel = 0,
	})
	Add("UISizeConstraint", { Parent = icon, MinSize = V2(10, 10), MaxSize = V2(10, 10) })

	--== popup list (plain Frame; the surface gradient only tints the frame's
	--== own background, so the option text stays untouched)
	local externals = self.Window.Externals
	local popup = PopupFrame(externals, "Dropdown")
	Corner(popup, 5)
	Stroke(popup, "Border", true)
	Padding(popup, 6, 5, 6, 7)
	Shadow(popup, 0.65)
	SurfaceGradient(popup)

	local inner = Add("ScrollingFrame", {
		Parent = popup,
		BackgroundTransparency = 1,
		Size = UFS(1, 1),
		CanvasSize = UFS(0, 0),
		AutomaticCanvasSize = AT.Y,
		ScrollBarThickness = 0,
		BorderSizePixel = 0,
		ZIndex = 41,
	})

	local ENTRY_HEIGHT = 14
	local ENTRY_GAP = 3
	List(inner, { Padding = UD(0, ENTRY_GAP) })

	local entries: { any } = {}

	local function displayText(): string
		if #selected == 0 then
			return options.Placeholder or "..."
		end
		return table.concat(selected, ", ")
	end

	local function render()
		display.Text = displayText()
		for _, entry in next, entries do
			local isSelected = TF(selected, entry.Value) ~= nil
			Tween(entry.Button, Anim.Fast, {
				TextTransparency = isSelected and 0 or 0.5,
				TextColor3 = isSelected and Callisto.Theme.Accent or Callisto.Theme.Text,
			})
		end
		if options.Flag then
			Callisto.Flags[options.Flag] = multi and table.clone(selected) or selected[1]
		end
	end

	local open = false
	local function setOpen(shouldOpen: boolean)
		if open == shouldOpen then
			return
		end
		open = shouldOpen

		-- Size is decided before the popup appears and never animated. It is
		-- computed from fixed entry metrics — TextBounds (and therefore
		-- AbsoluteContentSize) are NOT computed for elements that have never
		-- rendered, so measuring the hidden list would collapse the popup.
		local count = #entries
		local contentHeight = count * ENTRY_HEIGHT + math.max(count - 1, 0) * ENTRY_GAP
		local height = math.min(contentHeight + 11, options.MaxHeight or 160)
		popup.Size = UFO(MR(button.AbsoluteSize.X), height)

		local absolutePosition = button.AbsolutePosition
		local base = ToHolderSpace(externals, absolutePosition.X, absolutePosition.Y + 28)
		AnimatePopup(popup, open, base)
		Tween(icon, Anim.Slow, { Rotation = open and 180 or 0 })
	end

	local function AddOption(value: string)
		-- fixed height + full width instead of AutomaticSize: automatic sizing
		-- needs TextBounds, which stay 0 until the element first renders
		local entry = Text(inner, {
			ClassName = "TextButton",
			LayoutOrder = 1,
			Text = value,
			TextTransparency = 0.5,
			Size = UD2(1, 0, 0, ENTRY_HEIGHT),
			TextXAlignment = TXA.Left,
			TextTruncate = ETT.AtEnd,
			AutoButtonColor = false,
			ZIndex = 41,
		})

		Connect(entry.MouseButton1Click, function()
			local index = TF(selected, value)
			if multi then
				if index then
					TR(selected, index)
				else
					TIS(selected, value)
				end
			else
				selected = { value }
				setOpen(false)
			end
			render()
			if options.Callback then
				task.spawn(options.Callback, multi and table.clone(selected) or selected[1])
			end
		end)

		Hover(entry, function(hovering)
			if TF(selected, value) then
				return
			end
			Tween(entry, Anim.Fast, { TextTransparency = hovering and 0.2 or 0.5 })
		end)

		TIS(entries, { Button = entry, Value = value })
	end

	for _, value in ipairs(values) do
		AddOption(tostring(value))
	end

	-- prime the fader with the fully-built option list (see colorpicker note)
	Fader.Out(popup, TI(0))

	Connect(button.MouseButton1Click, function()
		setOpen(not open)
	end)

	Hover(button, function(hovering)
		Tween(stroke, Anim.Base, { Color = hovering and Callisto.Theme.Accent or Callisto.Theme.Border })
	end)

	Connect(UserInputService.InputBegan, function(input, processed)
		if processed or not open then
			return
		end
		if input.UserInputType ~= UIT.MouseButton1 and input.UserInputType ~= UIT.Touch then
			return
		end
		local mouse = V2(input.Position.X, input.Position.Y)
		if not InsideBounds(mouse, popup) and not InsideBounds(mouse, button) then
			setOpen(false)
		end
	end)

	render()

	return {
		Instance = container,
		Get = function()
			return multi and table.clone(selected) or selected[1]
		end,
		Set = function(_, value)
			selected = typeof(value) == "table" and table.clone(value) or { value }
			render()
		end,
		Refresh = function(_, newValues: { string })
			-- restore the shell to rest before rebuilding, so the re-prime
			-- below captures true rest values rather than mid-fade ones
			local hidden = Fader.State[popup] == "hidden"
			if hidden then
				Fader.In(popup, TI(0))
			end

			for _, entry in next, entries do
				entry.Button:Destroy()
			end
			table.clear(entries)
			selected = {}
			for _, value in ipairs(newValues) do
				AddOption(tostring(value))
			end
			render()

			if hidden then
				Fader.State[popup] = "shown"
				Fader.Out(popup, TI(0))
			end
		end,
		Close = function()
			setOpen(false)
		end,
	}
end

--== Switch (segmented button) ================================================

--[[
	Section:AddSwitch({
		Values = { "varation 1", "Disabled" },
		Default = 1,
		Compact = true,             -- SwitchButton2 (2px inset) vs SwitchButton (1px)
		Callback = function(value, index) end,
	})
]]
function Section:AddSwitch(options: { [string]: any })
	local values = options.Values or {}
	local index = options.Default or 1
	local inset = options.Compact and 2 or 1

	local container = Add("Frame", {
		Parent = self.Content,
		Size = UD2(1, 0, 0, 25),
		Name = "SwitchButton",
		Active = true,
		Selectable = true,
		BorderSizePixel = 0,
		LayoutOrder = self:_Order(),
	})
	Bind(container, { BackgroundColor3 = "Background" })
	Corner(container, 5)
	List(container, {
		VerticalAlignment = VFA.Center,
		FillDirection = FD.Horizontal,
		HorizontalAlignment = HFA.Center,
		HorizontalFlex = UFA.Fill,
	})
	Padding(container, inset, inset, inset, inset)
	Stroke(container, "Border", true)
	Shadow(container, 0.65)

	local buttons: { any } = {}

	-- Active segment = accent background (the button itself) + accent stroke.
	-- Inactive = the accent layer fades out, revealing the raised surface
	-- behind. Pure crossfade — no segment ever moves or resizes.
	local function render(animate: boolean?)
		local info = animate == false and TI(0) or Anim.Base
		for position, entry in next, buttons do
			local active = position == index
			Tween(entry.Button, info, { BackgroundTransparency = active and 0 or 1 })
			Tween(entry.Stroke, info, { Transparency = active and 0 or 1 })
			Tween(entry.Label, info, {
				TextTransparency = entry.Disabled and 0.9 or (active and 0 or 0.5),
			})
		end
	end

	-- ipairs, not next: LayoutOrder depends on a deterministic sequence
	for position, value in ipairs(values) do
		local disabled = typeof(value) == "table" and value.Disabled or false
		local title = typeof(value) == "table" and value.Title or tostring(value)

		local button = Add("TextButton", {
			Parent = container,
			Text = "",
			AutoButtonColor = false,
			Name = "Button",
			BackgroundTransparency = 1,
			TextTruncate = ETT.AtEnd,
			Size = UFS(1, 1),
			LayoutOrder = position,
			BorderSizePixel = 0,
		})
		Corner(button, 4)
		AccentGradient(button)
		local buttonStroke = Stroke(button, "AccentLight", true)
		buttonStroke.Transparency = 1

		local label = Text(button, {
			Name = "Label",
			Text = title,
			Size = UFS(1, 1),
			TextTruncate = ETT.SplitWord,
			Position = UFO(0, -1),
			TextTransparency = disabled and 0.9 or 0.5,
		})

		-- inactive segments keep the raised surface gradient
		local surface = Add("Frame", {
			Parent = button,
			BackgroundTransparency = 1,
			Size = UFS(1, 1),
			ZIndex = 0,
			BorderSizePixel = 0,
		})
		Corner(surface, 4)
		SurfaceGradient(surface)

		TIS(buttons, {
			Button = button,
			Label = label,
			Stroke = buttonStroke,
			Disabled = disabled,
		})

		if not disabled then
			Connect(button.MouseButton1Click, function()
				if index == position then
					return
				end
				index = position
				render()
				if options.Callback then
					task.spawn(options.Callback, title, position)
				end
			end)

			Hover(button, function(hovering)
				if index == position then
					return
				end
				Tween(label, Anim.Fast, { TextTransparency = hovering and 0.2 or 0.5 })
			end)
		end
	end

	render(false)

	return {
		Instance = container,
		Get = function()
			local value = values[index]
			return typeof(value) == "table" and value.Title or value, index
		end,
		Set = function(_, position: number)
			index = position
			render()
		end,
	}
end

--=============================================================================
-- Page
--=============================================================================

local Page = {}
Page.__index = Page

--[[
	Page:AddSection("Left", "Section #1")
	Page:AddSection("Section #1")          -- side omitted, defaults to Left
]]
function Page:AddSection(side: string, title: string?)
	local normalized = side and side:lower() or "left"

	-- Allow the side argument to be skipped entirely.
	if normalized ~= "left" and normalized ~= "right" then
		title = side
		normalized = "left"
	end

	local parent = (normalized == "right") and self.Right or self.Left

	local section = Add("Frame", {
		Parent = parent,
		Size = UFS(1, 0),
		Name = "Section",
		AutomaticSize = AT.Y,
		BorderSizePixel = 0,
	})
	Bind(section, { BackgroundColor3 = "Background" })
	Stroke(section, "Border", true)
	Corner(section, 5)
	Shadow(section, 0.6)

	local header = Add("Frame", {
		Parent = section,
		Name = "Header",
		Size = UD2(1, 0, 0, 25),
		BorderSizePixel = 0,
	})
	Bind(header, { BackgroundColor3 = "Foreground" })
	Add("UICorner", {
		Parent = header,
		TopLeftRadius = UD(0, 5),
		TopRightRadius = UD(0, 5),
		BottomRightRadius = UD(0, 0),
		BottomLeftRadius = UD(0, 0),
	})
	Stroke(header, "Border", true)

	Text(header, {
		Name = "Title",
		Text = title or "Section",
		Size = UFS(0, 1),
		Position = UFO(5, 0),
		TextTruncate = ETT.SplitWord,
		AutomaticSize = AT.X,
	})

	local content = Add("Frame", {
		Parent = section,
		ClipsDescendants = true,
		Name = "Content",
		BackgroundTransparency = 1,
		Position = UFO(0, 25),
		Size = UFS(1, 0),
		AutomaticSize = AT.Y,
		BorderSizePixel = 0,
	})
	Padding(content, 10, 11, 11, 11)
	List(content, { Padding = UD(0, 7) })

	return setmetatable({
		Instance = section,
		Content = content,
		Window = self.Window,
		Page = self,
		_order = 0,
	}, Section)
end

--=============================================================================
-- Window
--=============================================================================

local Window = {}
Window.__index = Window

function Window:AddPage(name: string)
	local frame = Add("Frame", {
		Parent = self.Pages,
		BackgroundTransparency = 1,
		Name = "PageFrame",
		Size = UFS(1, 1),
		Visible = false,
		BorderSizePixel = 0,
	})

	local left = Add("ScrollingFrame", {
		Parent = frame,
		MidImage = "rbxassetid://83323744952055",
		TopImage = "rbxassetid://86255327167604",
		BottomImage = "rbxassetid://79069740978089",
		ClipsDescendants = false,
		AutomaticCanvasSize = AT.Y,
		ScrollBarThickness = 0,
		Name = "Left",
		Size = UFS(0.5, 1),
		Selectable = false,
		BackgroundTransparency = 1,
		CanvasSize = UFS(0, 0),
		BorderSizePixel = 0,
	})
	Bind(left, { ScrollBarImageColor3 = "Accent" })
	Padding(left, 0, 0, 0, 5)
	List(left, { Padding = UD(0, 10) })

	local right = Add("ScrollingFrame", {
		Parent = frame,
		Selectable = false,
		AnchorPoint = V2(1, 0),
		CanvasSize = UFS(0, 0),
		MidImage = "rbxassetid://83323744952055",
		TopImage = "rbxassetid://86255327167604",
		BottomImage = "rbxassetid://79069740978089",
		ClipsDescendants = false,
		ScrollBarThickness = 0,
		Name = "Right",
		Size = UFS(0.5, 1),
		BackgroundTransparency = 1,
		Position = UFS(1, 0),
		AutomaticCanvasSize = AT.Y,
		BorderSizePixel = 0,
	})
	Bind(right, { ScrollBarImageColor3 = "Accent" })
	Padding(right, 0, 0, 5, 0)
	List(right, { Padding = UD(0, 10) })

	--== tab button (PageButtonD inactive <-> PageButtonE active) ==============
	local button = Add("TextButton", {
		Parent = self.ButtonHolder,
		FontFace = FN(FONT_ID, FW.Medium, FS.Normal),
		-- the dump had Active = false (static mockup); tabs must be clickable
		Active = true,
		Text = "",
		AutoButtonColor = false,
		Selectable = false,
		Size = UFS(0, 1),
		Name = "PageButton",
		BackgroundTransparency = 1,
		AutomaticSize = AT.X,
		BorderSizePixel = 0,
		LayoutOrder = #self.PageList + 1,
	})
	-- gradient carrier: white background, colours live in the gradient
	button.BackgroundColor3 = WHITE
	Corner(button, 5)
	Padding(button, 0, 0, 5, 5)
	local buttonShadow = Shadow(button, 1, "Accent")
	local buttonStroke = Stroke(button, "AccentLight", true)
	buttonStroke.Transparency = 1
	local buttonGradient = Add("UIGradient", { Parent = button, Rotation = 90 })
	BindGradient(buttonGradient, { { 0, "Accent" }, { 1, "AccentDark" } })

	local label = Text(button, {
		FontFace = FN(FONT_ID, FW.Medium, FS.Normal),
		Text = name,
		TextTransparency = 0.5,
		BackgroundTransparency = 1,
		Size = UFS(1, 1),
		AutomaticSize = AT.XY,
		TextSize = 15,
	})

	local page: any = setmetatable({
		Name = name,
		Instance = frame,
		Left = left,
		Right = right,
		Button = button,
		Window = self,
	}, Page)

	local function setActive(active: boolean, animate: boolean?)
		local info = animate == false and TI(0) or Anim.Base
		Tween(button, info, { BackgroundTransparency = active and 0 or 1 })
		Tween(buttonStroke, info, { Transparency = active and 0 or 1 })
		Tween(label, info, { TextTransparency = active and 0 or 0.5 })
		if buttonShadow then
			Tween(buttonShadow, info, { Transparency = active and 0.65 or 1 })
		end
	end

	page.SetActive = setActive

	Connect(button.MouseButton1Click, function()
		self:SelectPage(page)
	end)

	Hover(button, function(hovering)
		if self.CurrentPage == page then
			return
		end
		Tween(label, Anim.Fast, { TextTransparency = hovering and 0.2 or 0.5 })
	end)

	setActive(false, false)
	TIS(self.PageList, page)

	if not self.CurrentPage then
		self:SelectPage(page)
	end

	return page
end

function Window:SelectPage(page: any)
	if self.CurrentPage == page then
		return
	end

	local previous: any = self.CurrentPage
	self.CurrentPage = page

	for _, other in next, self.PageList do
		other.SetActive(other == page)
	end

	-- The outgoing page is captured and hidden instantly (no overlap frames);
	-- the incoming page fades back to its captured rest values while settling
	-- down from +8px. The first visit to a page has no capture yet, so it
	-- simply appears and slides — every later visit gets the full fade.
	if previous then
		local frame = previous.Instance
		Fader.Out(frame, TI(0))
		frame.Visible = false
		frame.Position = UFO(0, 0)
	end

	page.Instance.Position = UFO(0, 8)
	page.Instance.Visible = true
	Fader.In(page.Instance, Anim.Slow)
	Tween(page.Instance, Anim.Slow, { Position = UFO(0, 0) })
end

function Window:SetTitle(title: string)
	self.Title.Text = title
end

-- Open/close: Fader cascade + a 12px slide. The window's size is NEVER
-- animated.
function Window:Toggle(state: boolean?)
	local open = state
	if open == nil then
		open = not self.Visible
	end
	if open == self.Visible then
		return
	end
	self.Visible = open

	local canvas: any = self.Canvas

	if open then
		local home: UDim2 = self.HomePosition or canvas.Position
		self.HomePosition = home
		self.ScreenGui.Enabled = true
		canvas.Visible = true
		canvas.Position = home + UD2(0, 0, 0, 12)
		Tween(canvas, Anim.Slow, { Position = home })
		Fader.In(canvas, Anim.Slow)
	else
		-- capture wherever the user last dragged it, restore after the fade
		local home: UDim2 = canvas.Position
		self.HomePosition = home
		Fader.Out(canvas, Anim.Base)
		local tween = Tween(canvas, Anim.Base, { Position = home + UD2(0, 0, 0, 12) })
		tween.Completed:Once(function()
			if not self.Visible then
				self.ScreenGui.Enabled = false
				canvas.Position = home
			end
		end)
	end
end

-- Removes this window only. Connections are library-wide, so they are left
-- alone here; use Callisto:Unload() to tear everything down.
function Window:Destroy()
	local index = TF(Callisto.Windows, self)
	if index then
		TR(Callisto.Windows, index)
	end
	Fader.Forget(self.Root) -- before Destroy, while ancestry is intact
	self.Root:Destroy()
end

--=============================================================================
-- CreateWindow
--=============================================================================

function Callisto:CreateWindow(options: { [string]: any }?)
	local opts: { [string]: any } = options or {}
	local size = opts.Size or V2(591, 480)

	local root = Add("Folder", { Parent = GetParentGui(), Name = "Callisto" })

	local screenGui = Add("ScreenGui", {
		Parent = root,
		Enabled = true,
		Name = "Window",
		ZIndexBehavior = ZIB.Sibling,
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 999,
	})

	local canvas = Add("Frame", {
		Parent = screenGui,
		Name = "Canvas",
		AnchorPoint = V2(0.5, 0.5),
		Position = UFS(0.5, 0.5),
		Size = UFO(size.X, size.Y),
		BorderSizePixel = 0,
	})
	Bind(canvas, { BackgroundColor3 = "Background" })
	Stroke(canvas, "Border")
	Shadow(canvas, 0.65)
	Corner(canvas)

	--== header ===============================================================
	local header = Add("Frame", {
		Parent = canvas,
		Name = "Header",
		Size = UD2(1, 0, 0, 35),
		BorderSizePixel = 0,
	})
	Bind(header, { BackgroundColor3 = "Foreground" })
	Add("UICorner", { Parent = header, BottomRightRadius = UD(0, 0), BottomLeftRadius = UD(0, 0) })
	Stroke(header, "Border")
	List(header, {
		VerticalAlignment = VFA.Center,
		HorizontalFlex = UFA.SpaceBetween,
		FillDirection = FD.Horizontal,
	})
	Padding(header, 7, 7, 10, 10)
	local headerGradient = Add("UIGradient", { Parent = header, Enabled = false, Rotation = 90 })
	BindGradient(headerGradient, { { 0, "Background" }, { 1, "Foreground" } })

	local textHolder = Add("Frame", {
		Parent = header,
		Name = "TextHolder",
		BackgroundTransparency = 1,
		Size = UFS(0, 1),
		AutomaticSize = AT.X,
		BorderSizePixel = 0,
	})
	List(textHolder, { VerticalAlignment = VFA.Center, FillDirection = FD.Horizontal, Padding = UD(0, 5) })

	local title = Text(textHolder, {
		Name = "Title",
		Text = opts.Title or "Callisto",
		Size = UFS(0, 1),
		Position = UFO(10, 0),
		AutomaticSize = AT.X,
		TextSize = 17,
	})

	local buttonHolder = Add("Frame", {
		Parent = header,
		Name = "ButtonHolder",
		BackgroundTransparency = 1,
		Size = UFS(0, 1),
		AutomaticSize = AT.X,
		BorderSizePixel = 0,
	})
	List(buttonHolder, {
		VerticalAlignment = VFA.Center,
		FillDirection = FD.Horizontal,
		HorizontalAlignment = HFA.Right,
		Padding = UD(0, 5),
	})

	--== body =================================================================
	local pages = Add("Frame", {
		Parent = canvas,
		Name = "Pages",
		BackgroundTransparency = 1,
		Position = UFO(10, 45),
		Size = UD2(1, -20, 1, -80),
		ClipsDescendants = true,
		BorderSizePixel = 0,
	})
	Padding(pages, 1, 1)

	--== footer ===============================================================
	local footer = Add("Frame", {
		Parent = canvas,
		AnchorPoint = V2(0, 1),
		Name = "Footer",
		Position = UFS(0, 1),
		Size = UD2(1, 0, 0, 25),
		BorderSizePixel = 0,
	})
	Bind(footer, { BackgroundColor3 = "Foreground" })
	Add("UICorner", { Parent = footer, TopRightRadius = UD(0, 0), TopLeftRadius = UD(0, 0) })
	Stroke(footer, "Border")
	local footerGradient = Add("UIGradient", { Parent = footer, Enabled = false, Rotation = -90 })
	BindGradient(footerGradient, { { 0, "Background" }, { 1, "Foreground" } })

	local footerLabel = Text(footer, {
		Text = opts.Footer or "https://discord.gg/robloxuis",
		TextTransparency = 0.5,
		Name = "Label",
		Size = UFS(0, 1),
		RichText = true,
		AutomaticSize = AT.X,
	})
	Corner(footerLabel, 5)
	Padding(footerLabel, 0, 1, 10, 10)

	local resize = Add("ImageButton", {
		Parent = footer,
		ScaleType = SCL.Fit,
		ImageTransparency = 0.5,
		Name = "Resize",
		AnchorPoint = V2(1, 0),
		Image = "rbxassetid://89501307163630",
		BackgroundTransparency = 1,
		Position = UD2(1, -3, 0, 11),
		Size = UFO(10, 10),
		ResampleMode = RSM.Pixelated,
		BorderSizePixel = 0,
	})
	Hover(resize, function(hovering)
		Tween(resize, Anim.Fast, { ImageTransparency = hovering and 0 or 0.5 })
	end)

	--== externals (popups live above everything, outside the canvas group so
	--== they are not clipped or faded with the window) ========================
	local externals = Add("Frame", {
		Parent = screenGui,
		Name = "Externals",
		BackgroundTransparency = 1,
		Size = UFS(1, 1),
		ZIndex = 100,
		BorderSizePixel = 0,
	})

	local window: any = setmetatable({
		Root = root,
		ScreenGui = screenGui,
		Canvas = canvas,
		Header = header,
		Title = title,
		ButtonHolder = buttonHolder,
		Pages = pages,
		Footer = footer,
		Externals = externals,
		PageList = {},
		CurrentPage = nil,
		Visible = true,
		HomePosition = nil,
	}, Window)

	MakeDraggable(header, canvas)
	MakeResizable(resize, canvas, opts.MinSize or V2(420, 320))

	-- open/close keybind
	local toggleKey = opts.Keybind or EKC.RightShift
	Connect(UserInputService.InputBegan, function(input, processed)
		if processed then
			return
		end
		if input.UserInputType == UIT.Keyboard and input.KeyCode == toggleKey then
			window:Toggle()
		end
	end)

	-- entrance: capture the freshly-built shell, park it transparent, then
	-- fade + slide up into place; the size never animates
	local home = canvas.Position
	Fader.Out(canvas, TI(0))
	canvas.Position = home + UD2(0, 0, 0, 12)
	Tween(canvas, Anim.Slow, { Position = home })
	Fader.In(canvas, Anim.Slow)

	TIS(Callisto.Windows, window)
	return window
end

-- Full teardown: every window, every connection, every theme registration.
function Callisto:Unload()
	if ThemeTransition then
		ThemeTransition:Disconnect()
		ThemeTransition = nil
	end

	for _, connection in next, self.Connections do
		pcall(function()
			connection:Disconnect()
		end)
	end
	table.clear(self.Connections)

	for index = #self.Windows, 1, -1 do
		self.Windows[index].Root:Destroy()
		self.Windows[index] = nil
	end

	table.clear(ColorRegistry)
	table.clear(GradientRegistry)
	table.clear(self.Flags)
	Fader.Clear()
end

return Callisto
