--!strict

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local TextService = game:GetService("TextService")
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

local ConfigEntries: { [string]: any } = {}
local ConfigOrder: { any } = {}
local ConfigManager: any = nil
local CallbackContexts: { [thread]: any } = {}
local ActiveTweens: { [Tween]: RBXScriptConnection } = {}

local function SetFlag(flag: string, value: any)
    local previous = Callisto.Flags[flag]
    Callisto.Flags[flag] = value
    if previous ~= value then
        local entry = ConfigEntries[flag]
        if entry and entry.Sync then entry.Sync() end
    end
end

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
local BorderStates: { [Instance]: any } = {}
-- gradient -> { {time, themeKey}, ... }
local GradientRegistry: { [UIGradient]: { Stops: { { any } }, Signature: string } } = {}
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
    local signature = {}
    local keypoints = {}
    for _, stop in ipairs(stops) do
        TIS(signature, tostring(stop[1]) .. ":" .. stop[2])
        TIS(keypoints, CSK(stop[1], Callisto.Theme[stop[2]]))
    end
    GradientRegistry[gradient] = { Stops = stops, Signature = table.concat(signature, "|") }
    gradient.Color = CS(keypoints)
end

-- Paints every registered property/gradient at `alpha` between the previous
-- theme snapshot and the current one. Gradients are rebuilt keypoint-by-
-- keypoint, which is the only way to animate UIGradient.Color at all.
local function PaintTheme(alpha: number, previous: { [string]: Color3 }, changed: { [string]: boolean })
    local colors = {}
    for key in pairs(changed) do colors[key] = previous[key]:Lerp(Callisto.Theme[key], alpha) end
    local border = colors.Border or Callisto.Theme.Border
    local accent = colors.Accent or Callisto.Theme.Accent
    for instance, map in next, ColorRegistry do
        if not instance.Parent then
            ColorRegistry[instance] = nil
            BorderStates[instance] = nil
            continue
        end
        local borderState = BorderStates[instance]
        for property, key in next, map do
            if property == "Color" and borderState then
                if changed.Border or (changed.Accent and borderState.Weight.Value > 0) then
                    pcall(function() (instance :: any)[property] = border:Lerp(accent, borderState.Weight.Value) end)
                end
            elseif changed[key] then
                pcall(function() (instance :: any)[property] = colors[key] end)
            end
        end
    end
    local sequences = {}
    for gradient, binding in next, GradientRegistry do
        if not gradient.Parent then GradientRegistry[gradient] = nil; continue end
        local repaint = false
        for _, stop in ipairs(binding.Stops) do
            if changed[stop[2]] then repaint = true; break end
        end
        if repaint then
            local sequence = sequences[binding.Signature]
            if not sequence then
                local keypoints = {}
                for _, stop in ipairs(binding.Stops) do
                    TIS(keypoints, CSK(stop[1], colors[stop[2]] or Callisto.Theme[stop[2]]))
                end
                sequence = CS(keypoints)
                sequences[binding.Signature] = sequence
            end
            gradient.Color = sequence
        end
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

    local changed = {}
    for key, color in pairs(self.Theme) do
        if previous[key] ~= color then changed[key] = true end
    end
    if next(changed) == nil then return end
    if ThemeTransition then
        ThemeTransition:Disconnect()
        ThemeTransition = nil
    end

	if animate == false then
		PaintTheme(1, previous, changed)
		return
	end

	local elapsed = 0
	ThemeTransition = RunService.RenderStepped:Connect(function(dt)
		elapsed += dt
		local progress = MC(elapsed / 0.25, 0, 1)
		PaintTheme(1 - (1 - progress) ^ 3, previous, changed) -- cubic ease-out
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
    local connection
    connection = tween.Completed:Connect(function()
        if connection then connection:Disconnect() end
        ActiveTweens[tween] = nil
        task.defer(function() pcall(function() tween:Destroy() end) end)
    end)
    ActiveTweens[tween] = connection
    tween:Play()
    return tween
end

local function Connect(signal: RBXScriptSignal, callback)
	local connection = signal:Connect(callback)
	TIS(Callisto.Connections, connection)
	return connection
end

local function SetBorderActive(stroke: UIStroke, active: boolean)
    local state = BorderStates[stroke]
    if not state then
        local weight = Add("NumberValue", { Parent = stroke, Value = 0 })
        state = { Weight = weight }
        BorderStates[stroke] = state
        Connect(weight:GetPropertyChangedSignal("Value"), function()
            if stroke.Parent then
                stroke.Color = Callisto.Theme.Border:Lerp(Callisto.Theme.Accent, weight.Value)
            end
        end)
    end
    if state.Tween then state.Tween:Cancel() end
    state.Tween = Tween(state.Weight, Anim.Base, { Value = active and 1 or 0 })
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
    local frameConnection, inputConnection
    local function disconnect(connection)
        if not connection then return end
        connection:Disconnect()
        local index = TF(Callisto.Connections, connection)
        if index then TR(Callisto.Connections, index) end
    end
    local function step(dt)
        if not target.Parent then disconnect(frameConnection); frameConnection = nil; return end
        local position = target.Position
        local settled = not dragging
            and math.abs(goal.X.Offset - position.X.Offset) < 0.5
            and math.abs(goal.Y.Offset - position.Y.Offset) < 0.5
            and math.abs(goal.X.Scale - position.X.Scale) < 0.001
            and math.abs(goal.Y.Scale - position.Y.Scale) < 0.001
        if settled then
            target.Position = goal
            disconnect(frameConnection)
            frameConnection = nil
            return
        end
        target.Position = position:Lerp(goal, MC(dt * 20, 0, 1))
    end
    Connect(handle.InputBegan, function(input)
        if input.UserInputType == UIT.MouseButton1 or input.UserInputType == UIT.Touch then
            dragging = true
            dragStart = input.Position
            startPosition = target.Position
            goal = startPosition
            disconnect(inputConnection)
            inputConnection = Connect(input.Changed, function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                    disconnect(inputConnection)
                    inputConnection = nil
                end
            end)
            if not frameConnection then frameConnection = Connect(RunService.RenderStepped, step) end
        end
    end)
    Connect(UserInputService.InputChanged, function(input)
        if not dragging then return end
        if input.UserInputType ~= UIT.MouseMovement and input.UserInputType ~= UIT.Touch then return end
        local delta = input.Position - dragStart
        goal = UD2(startPosition.X.Scale, startPosition.X.Offset + delta.X,
            startPosition.Y.Scale, startPosition.Y.Offset + delta.Y)
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
			connection = Connect(input.Changed, function()
				if input.UserInputState == Enum.UserInputState.End then
					resizing = false
                    connection:Disconnect()
                    local index = TF(Callisto.Connections, connection)
                    if index then TR(Callisto.Connections, index) end
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
        if hue == position.X then return end
		hue = position.X
		render()
	end)
	BindTrack(alphaBar, function(position)
        if alpha == position.Y then return end
		alpha = position.Y
		render()
	end)
	BindTrack(sv, function(position)
        if saturation == position.X and value == 1 - position.Y then return end
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



local LockedStates = setmetatable({}, { __mode = "k" })
local LockedScrollers = setmetatable({}, { __mode = "k" })

function Callisto:SetLocked(element: any, locked: boolean)
    local root = typeof(element) == "Instance" and element or (element.Row or element.Instance)
    assert(root and root:IsA("GuiObject"), "SetLocked expects a Callisto control or GuiObject")

    if not locked then
        local state = LockedStates[root]
        if not state then return element end
        LockedStates[root] = nil
        for _, saved in ipairs(state.Objects) do
            pcall(function()
                saved.Object.Active = saved.Active
                saved.Object.Interactable = saved.Interactable
                if saved.TextEditable ~= nil then
                    saved.Object.TextEditable = saved.TextEditable
                end
            end)
        end
        for _, scroller in ipairs(state.Scrollers) do
            local saved = LockedScrollers[scroller]
            if saved then
                saved.Count -= 1
                if saved.Count == 0 then
                    pcall(function() scroller.Active = saved.Active end)
                    LockedScrollers[scroller] = nil
                end
            end
        end
        return element
    end

    if LockedStates[root] then return element end
    if typeof(element) == "table" and type(element.Close) == "function" then
        element.Close()
    end

    local state = { Objects = {}, Scrollers = {} }
    local objects = root:GetDescendants()
    TIS(objects, 1, root)
    for _, object in ipairs(objects) do
        if object:IsA("GuiObject") then
            local saved: any = {
                Object = object,
                Active = object.Active,
                Interactable = object.Interactable,
            }
            if object:IsA("TextBox") then saved.TextEditable = object.TextEditable end
            TIS(state.Objects, saved)
        end
    end
    LockedStates[root] = state
    for _, saved in ipairs(state.Objects) do
        saved.Object.Active = false
        saved.Object.Interactable = false
        if saved.TextEditable ~= nil then saved.Object.TextEditable = false end
    end

    local parent = root.Parent
    while parent and not parent:IsA("ScreenGui") do
        if parent:IsA("ScrollingFrame") then
            local saved = LockedScrollers[parent]
            if not saved then
                saved = { Active = parent.Active, Count = 0 }
                LockedScrollers[parent] = saved
            end
            saved.Count += 1
            parent.Active = false
            TIS(state.Scrollers, parent)
        end
        parent = parent.Parent
    end
    return element
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



function Section:AddDivider()
    local line = Add("Frame", {
        Parent = self.Content,
        Name = "Divider",
        Size = UD2(1, 0, 0, 1),
        BorderSizePixel = 0,
        LayoutOrder = self:_Order(),
    })
    Bind(line, { BackgroundColor3 = "Border" })
    return { Instance = line }
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
			SetBorderActive(stroke, hovering)
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
			SetFlag(flag, state)
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
		SetFlag(flag, options.Default or false)
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
				SetFlag(flag, color)
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

local KeybindAliases = {
    LEFTCONTROL = "LCTRL", RIGHTCONTROL = "RCTRL",
    LEFTSHIFT = "LSHIFT", RIGHTSHIFT = "RSHIFT",
    LEFTALT = "LALT", RIGHTALT = "RALT",
    PAGEUP = "PGUP", PAGEDOWN = "PGDN", CAPSLOCK = "CAPS",
}

function Section:AddKeybind(options: { [string]: any })
    local row, left, right, title = self:_Row(options.Title or "Keybind")
    local current: EnumItem? = options.Default
    if current == EKC.Unknown then current = nil end
    local binding, hovering = false, false

    row.AutomaticSize = AT.None
    row.Size = UD2(1, 0, 0, 24)
    left.AutomaticSize = AT.None
    title.AutomaticSize = AT.None
    title.Size = UFS(1, 1)
    title.TextXAlignment = TXA.Left
    title.TextTruncate = ETT.AtEnd
    right.AutomaticSize = AT.None
    right.AnchorPoint = V2(1, 0.5)
    right.Position = UFS(1, 0.5)

    local surface = Add("Frame", {
        Parent = right,
        Name = "ThemedKeybind",
        Size = UFO(28, 24),
        BackgroundColor3 = RGB(255, 255, 255),
        BackgroundTransparency = 0.12,
        BorderSizePixel = 0,
    })
    Corner(surface, 5)
    local gradient = Add("UIGradient", { Parent = surface, Rotation = 90 })
    BindGradient(gradient, { { 0, "Accent" }, { 1, "AccentDark" } })
    local stroke = Stroke(surface, "AccentLight", true)
    stroke.Transparency = 0.25

    local button = Text(surface, {
        ClassName = "TextButton",
        Name = "Keybind",
        Active = true,
        Selectable = false,
        AutoButtonColor = false,
        Size = UFS(1, 1),
        Text = "",
        TextTransparency = 1,
    })
    local keyLabel = Text(button, {
        Name = "KeyLabel",
        Text = "",
        TextColor3 = RGB(255, 255, 255),
        TextTransparency = 0,
        TextSize = 14,
        Size = UFS(1, 1),
        TextWrapped = false,
        TextScaled = false,
        TextTruncate = ETT.None,
        TextXAlignment = TXA.Center,
        ZIndex = button.ZIndex + 1,
    })

    local measureVersion = 0
    local function applyWidth(width: number)
        if not surface.Parent then return end
        local pixels = math.max(28, math.ceil(width) + 16)
        surface.Size = UFO(pixels, 24)
        right.Size = UFO(pixels, 24)
        left.Size = UD2(1, -pixels - 8, 1, 0)
    end
    local function fitKeyText()
        measureVersion += 1
        local version = measureVersion
        local text = keyLabel.Text
        local ok, bounds = pcall(function()
            return TextService:GetTextSize(text, keyLabel.TextSize, Enum.Font.Gotham, V2(100000, 100000))
        end)
        if ok then applyWidth(bounds.X) else applyWidth(#text * keyLabel.TextSize * 0.6) end
        task.spawn(function()
            local params = Instance.new("GetTextBoundsParams")
            local success, measured = pcall(function()
                params.Text = text
                params.Font = keyLabel.FontFace
                params.Size = keyLabel.TextSize
                params.Width = 100000
                params.RichText = false
                return TextService:GetTextBoundsAsync(params)
            end)
            params:Destroy()
            if success and version == measureVersion then applyWidth(measured.X) end
        end)
    end
    Connect(keyLabel:GetPropertyChangedSignal("FontFace"), fitKeyText)
    Connect(keyLabel:GetPropertyChangedSignal("TextSize"), fitKeyText)
    Connect(keyLabel:GetPropertyChangedSignal("Text"), fitKeyText)

    local function isLocked(): boolean
        return not row.Interactable or not button.Interactable
    end
    local function render()
        local name = current and current.Name:upper() or "NONE"
        local display = binding and "PRESS KEY" or (KeybindAliases[name] or name)
        button.Text = display
        keyLabel.Text = display
        local selected = current ~= nil
        local highlighted = hovering or binding
        surface.BackgroundTransparency = highlighted and 0 or (selected and 0.12 or 1)
        stroke.Transparency = highlighted and 0 or (selected and 0.25 or 1)
        if options.Flag then SetFlag(options.Flag, current) end
    end

    Connect(button.MouseButton1Click, function()
        if isLocked() then return end
        binding = true
        render()
    end)
    Hover(button, function(over)
        hovering = over and not isLocked()
        render()
    end)
    local function onLockChanged()
        if isLocked() then binding, hovering = false, false end
        render()
    end
    Connect(row:GetPropertyChangedSignal("Interactable"), onLockChanged)
    Connect(button:GetPropertyChangedSignal("Interactable"), onLockChanged)

    Connect(UserInputService.InputBegan, function(input, processed)
        if isLocked() then return end
        if binding then
            if input.UserInputType == UIT.Keyboard and not KeybindBlacklist[input.KeyCode] then
                if input.KeyCode == EKC.Backspace then current = nil else current = input.KeyCode end
                binding = false
                render()
            end
            return
        end
        if processed or not current then return end
        if input.UserInputType == UIT.Keyboard and input.KeyCode == current and options.Callback then
            task.spawn(options.Callback, current)
        end
    end)
    render()

    return {
        Instance = button,
        Row = row,
        Background = surface,
        Label = keyLabel,
        Get = function() return current end,
        Set = function(_, key: EnumItem?)
            assert(key == nil or (typeof(key) == "EnumItem" and key.EnumType == EKC),
                "Keybind:Set expects an Enum.KeyCode or nil")
            current = key
            if current == EKC.Unknown then current = nil end
            binding = false
            render()
        end,
    }
end

--== Slider ===================================================================

local function IsFiniteNumber(value: any): boolean
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function NormalizeNumber(value: number, minimum: number, maximum: number, decimals: number): number
    value = MC(value, minimum, maximum)
    local multiplier = 10 ^ decimals
    local scaled = value * multiplier
    local rounded = IsFiniteNumber(scaled) and MF(scaled + 0.5) / multiplier or value
    return MC(rounded, minimum, maximum)
end

local function FormatNumber(value: number, decimals: number): string
    local text = string.format("%." .. decimals .. "f", value)
    if decimals > 0 then text = text:gsub("0+$", ""):gsub("%.$", "") end
    return tonumber(text) == 0 and "0" or text
end

local function IsNumberDraft(text: string, negatives: boolean, decimals: number): boolean
    if not negatives and text:find("-", 1, true) then return false end
    if decimals == 0 and text:find(".", 1, true) then return false end
    return text:match("^%-?%d*%.?%d*$") ~= nil
end

function Section:AddSlider(options: { [string]: any })
    local minimum = options.Min or 0
    local maximum = options.Max or 100
    local decimals = options.Decimals or 0
    assert(IsFiniteNumber(minimum) and IsFiniteNumber(maximum) and minimum <= maximum, "Invalid slider range")
    assert(IsFiniteNumber(decimals) and decimals % 1 == 0 and decimals >= 0 and decimals <= 10, "Decimals must be between 0 and 10")
    local initial = tonumber(options.Default) or minimum
    local value = NormalizeNumber(IsFiniteNumber(initial) and initial or minimum, minimum, maximum, decimals)
    local suffix = options.Suffix or "%"
    local editing, dragging = false, false

    local container = Add("Frame", {
        Parent = self.Content, Name = "Slider", BackgroundTransparency = 1,
        Size = UFS(1, 0), AutomaticSize = AT.Y, BorderSizePixel = 0, LayoutOrder = self:_Order(),
    })
    List(container, { Padding = UD(0, 5) })
    local changed = Add("BindableEvent", { Parent = container, Name = "ValueChanged" })
    local textHolder = Add("Frame", {
        Parent = container, Name = "TextHolder", BackgroundTransparency = 1,
        Size = UFS(1, 0), AutomaticSize = AT.Y, BorderSizePixel = 0,
    })
    List(textHolder, { FillDirection = FD.Horizontal, HorizontalFlex = UFA.SpaceBetween, Padding = UD(0, 7) })
    local title = Text(textHolder, {
        Name = "Title", LayoutOrder = 1, Text = options.Title or "slider",
        TextTruncate = ETT.SplitWord, AutomaticSize = AT.XY,
    })
    Padding(title, -3, -1)
    local valueHolder = Add("Frame", {
        Parent = textHolder, Name = "ValueHolder", LayoutOrder = 2,
        BackgroundTransparency = 1, Size = UFO(0, 0), AutomaticSize = AT.XY, BorderSizePixel = 0,
    })
    List(valueHolder, { FillDirection = FD.Horizontal, VerticalAlignment = VFA.Center, Padding = UD(0, 0) })
    local current = Text(valueHolder, {
        ClassName = "TextButton", Name = "Current", LayoutOrder = 1, Text = "",
        AutoButtonColor = false, Active = true, AutomaticSize = AT.XY,
    })
    Padding(current, -3, -1)
    local editor = Text(valueHolder, {
        ClassName = "TextBox", Name = "ValueInput", LayoutOrder = 1, Text = "",
        Visible = false, Active = true, ClearTextOnFocus = false,
        MultiLine = false, TextWrapped = false, TextTruncate = ETT.None, AutomaticSize = AT.XY,
    })
    Add("UISizeConstraint", { Parent = editor, MinSize = V2(12, 0) })
    Padding(editor, -3, -1)
    local suffixLabel = Text(valueHolder, {
        Name = "Suffix", LayoutOrder = 2, Text = suffix, AutomaticSize = AT.XY, Active = false,
    })
    Padding(suffixLabel, -3, -1)
    local track = Add("TextButton", {
        Parent = container, LayoutOrder = 1, Name = "Button", Text = "",
        AutoButtonColor = false, Size = UD2(1, 0, 0, 16), BorderSizePixel = 0,
    })
    Corner(track, 5)
    local trackStroke = Stroke(track, "Border", true)
    SurfaceGradient(track)
    local fill = Add("Frame", {
        Parent = track, Name = "Fill", Size = UD2(0, 0, 1, 0), BorderSizePixel = 0,
    })
    Corner(fill, 5)
    AccentGradient(fill)
    Shadow(fill, 0.65, "Accent")

    local function render()
        local progress = maximum == minimum and 0 or (value - minimum) / (maximum - minimum)
        fill.Size = UD2(progress, 0, 1, 0)
        current.Text = FormatNumber(value, decimals)
        if not editing then editor.Text = current.Text end
    end
    local function set(newValue: number, silent: boolean?)
        if not IsFiniteNumber(newValue) then return value end
        local previous = value
        value = NormalizeNumber(newValue, minimum, maximum, decimals)
        render()
        if options.Flag then SetFlag(options.Flag, value) end
        if previous ~= value then changed:Fire(value) end
        if options.Callback and not silent then task.spawn(options.Callback, value) end
        return value
    end
    local function isLocked(): boolean
        return not container.Interactable or not track.Interactable
    end
    local function finishEditing(commit: boolean)
        if not editing then return end
        local parsed = tonumber(editor.Text)
        editing = false
        editor.Visible = false
        current.Visible = true
        if editor:IsFocused() then editor:ReleaseFocus() end
        if commit and not isLocked() and IsFiniteNumber(parsed) then set(parsed) else render() end
    end
    local lastClick = -math.huge
    Connect(current.MouseButton1Click, function()
        if isLocked() then return end
        local now = os.clock()
        if now - lastClick <= 0.3 then
            lastClick = -math.huge
            editing = true
            dragging = false
            editor.Text = FormatNumber(value, decimals)
            current.Visible = false
            editor.Visible = true
            editor:CaptureFocus()
            editor.CursorPosition = #editor.Text + 1
            editor.SelectionStart = -1
        else
            lastClick = now
        end
    end)
    local accepted = editor.Text
    local filtering = false
    Connect(editor:GetPropertyChangedSignal("Text"), function()
        if filtering then return end
        if IsNumberDraft(editor.Text, minimum < 0, decimals) then
            accepted = editor.Text
        else
            filtering = true
            editor.Text = accepted
            editor.CursorPosition = #editor.Text + 1
            filtering = false
        end
    end)
    Connect(editor.FocusLost, function() finishEditing(true) end)
    Connect(editor.InputBegan, function(input)
        if input.KeyCode == EKC.Escape then finishEditing(false) end
    end)
    local function stopIfLocked()
        if isLocked() then dragging = false; finishEditing(false) end
    end
    Connect(container:GetPropertyChangedSignal("Interactable"), stopIfLocked)
    Connect(track:GetPropertyChangedSignal("Interactable"), stopIfLocked)
    local function updateFromInput(position: Vector3 | Vector2)
        if isLocked() or track.AbsoluteSize.X <= 0 then return end
        local progress = MC((position.X - track.AbsolutePosition.X) / track.AbsoluteSize.X, 0, 1)
        set(minimum + (maximum - minimum) * progress)
    end
    Connect(track.InputBegan, function(input)
        if isLocked() then return end
        if input.UserInputType == UIT.MouseButton1 or input.UserInputType == UIT.Touch then
            finishEditing(true)
            dragging = true
            updateFromInput(input.Position)
        end
    end)
    Connect(UserInputService.InputEnded, function(input)
        if input.UserInputType == UIT.MouseButton1 or input.UserInputType == UIT.Touch then dragging = false end
    end)
    Connect(UserInputService.InputChanged, function(input)
        if dragging and (input.UserInputType == UIT.MouseMovement or input.UserInputType == UIT.Touch) then
            updateFromInput(input.Position)
        end
    end)
    Hover(track, function(over) SetBorderActive(trackStroke, over) end)
    set(value, true)
    return {
        Instance = container, ValueLabel = current, ValueInput = editor, SuffixLabel = suffixLabel,
        Min = minimum, Max = maximum, Decimals = decimals, Changed = changed.Event,
        Get = function() return value end,
        Set = function(_, newValue: number) return set(newValue) end,
    }
end

--== Input ====================================================================

function Section:AddInput(options: { [string]: any })
    local slider = options.Slider or options.LinkedSlider
    local numeric = options.NumbersOnly == true or slider ~= nil
    if slider then
        assert(type(slider) == "table" and type(slider.Get) == "function" and type(slider.Set) == "function"
            and slider.Changed, "Slider must be a Callisto slider")
    end
    local minimum = slider and slider.Min or options.Min or -math.huge
    local maximum = slider and slider.Max or options.Max or math.huge
    local decimals = slider and slider.Decimals or options.Decimals or 0
    if numeric then
        assert(type(minimum) == "number" and minimum == minimum and type(maximum) == "number"
            and maximum == maximum and minimum <= maximum, "Invalid input range")
        assert(IsFiniteNumber(decimals) and decimals % 1 == 0 and decimals >= 0 and decimals <= 10,
            "Decimals must be between 0 and 10")
    end
    local committed = numeric and (slider and slider.Get() or tonumber(options.Default) or 0) or nil
    if numeric then
        if not IsFiniteNumber(committed) then committed = 0 end
        committed = NormalizeNumber(committed, minimum, maximum, decimals)
    end
    local container = Add("Frame", {
        Parent = self.Content, Name = "Input", BackgroundTransparency = 1,
        Size = UFS(1, 0), AutomaticSize = AT.Y, BorderSizePixel = 0, LayoutOrder = self:_Order(),
    })
    List(container, { VerticalAlignment = VFA.Center, Padding = UD(0, 3) })
    Padding(container, 1)
    local title = Text(container, {
        Name = "Title", Text = options.Title or "Input", TextTransparency = 0.3, Position = UFO(21, 0),
        TextXAlignment = TXA.Left, TextTruncate = ETT.SplitWord, AutomaticSize = AT.XY,
    })
    Padding(title, -5, -1)
    local box = Add("Frame", {
        Parent = container, LayoutOrder = 1, Active = true, Selectable = true, Name = "Button",
        Size = UD2(1, 0, 0, 25), BorderSizePixel = 0,
    })
    Corner(box, 5)
    local stroke = Stroke(box, "Border", true)
    Padding(box, 0, 0, 7, 7)
    Shadow(box, 0.65)
    SurfaceGradient(box)
    local clearOnFocus = options.ClearOnFocus ~= false
    if numeric then clearOnFocus = options.ClearOnFocus == true end
    local input = Text(box, {
        ClassName = "TextBox", Name = "TextLabel",
        Text = numeric and FormatNumber(committed, decimals) or tostring(options.Default or ""),
        Size = UFS(1, 1), Selectable = false, TextXAlignment = TXA.Left, TextTruncate = ETT.SplitWord,
        Active = false, PlaceholderText = options.Placeholder or "something here....",
        ClearTextOnFocus = clearOnFocus, MultiLine = false,
    })
    local accepted = input.Text
    local filtering = false
    local function putText(text: string)
        filtering = true
        input.Text = text
        accepted = text
        filtering = false
    end
    local function syncFlag()
        if options.Flag then SetFlag(options.Flag, input.Text) end
    end
    local function setNumeric(value: any, updateSlider: boolean)
        local number = tonumber(value)
        if not IsFiniteNumber(number) then number = committed end
        number = NormalizeNumber(number, minimum, maximum, decimals)
        if slider and updateSlider and slider.Get() ~= number then slider:Set(number) end
        if slider then number = slider.Get() end
        committed = number
        putText(FormatNumber(number, decimals))
        syncFlag()
    end
    Connect(input:GetPropertyChangedSignal("Text"), function()
        if not numeric or filtering then return end
        if IsNumberDraft(input.Text, minimum < 0, decimals) then
            accepted = input.Text
        else
            putText(accepted)
            input.CursorPosition = #input.Text + 1
        end
    end)
    Connect(input.Focused, function() SetBorderActive(stroke, true) end)
    Connect(input.FocusLost, function(enter)
        SetBorderActive(stroke, false)
        if not container.Interactable or not input.Interactable then
            if numeric then setNumeric(committed, false) end
            return
        end
        if numeric then setNumeric(input.Text, true) else syncFlag() end
        if options.Callback and (enter or not options.OnEnter) then task.spawn(options.Callback, input.Text, enter) end
    end)
    if slider then
        Connect(slider.Changed, function(value)
            committed = value
            putText(FormatNumber(value, decimals))
            syncFlag()
        end)
    end
    if numeric then syncFlag() end
    return {
        Instance = container, Input = input,
        Get = function() return input.Text end,
        GetNumber = function() return tonumber(input.Text) end,
        Set = function(_, value: any)
            if numeric then setNumeric(value, true) else input.Text = tostring(value) end
        end,
    }
end

--== Dropdown =================================================================

function Section:AddDropdown(options: { [string]: any })
	local valuesSource = options.Values or options.Options or {}
    local currentValues: { string } = {}
	local multi = options.Multi or options.MultiSelect or false
	local selected: { string } = {}

    local function toLabel(value: any): string
        if typeof(value) == "Instance" then return value.Name end
        return tostring(value)
    end
    if options.Default ~= nil then
        if typeof(options.Default) == "table" then
            for _, item in ipairs(options.Default) do TIS(selected, toLabel(item)) end
        else
            TIS(selected, toLabel(options.Default))
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
            local color = isSelected and Callisto.Theme.Accent or Callisto.Theme.Text
            if entry.Button.TextTransparency ~= (isSelected and 0 or 0.5) or entry.Button.TextColor3 ~= color then
                Tween(entry.Button, Anim.Fast, {
                    TextTransparency = isSelected and 0 or 0.5,
                    TextColor3 = color,
                })
            end
		end
		if options.Flag then
			SetFlag(options.Flag, multi and table.clone(selected) or selected[1])
		end
	end

	local open = false
    local loading = false
    local reloadValues: any
	local function setOpen(shouldOpen: boolean)
		if open == shouldOpen then
			return
		end
        if shouldOpen then
            if loading or not container.Interactable or not button.Interactable then return end
            loading = true
            reloadValues(true)
            loading = false
            if not container.Parent or not container.Interactable or not button.Interactable then return end
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

        local connections = {}
        local function connectEntry(event, callback)
            local connection = Connect(event, callback)
            TIS(connections, connection)
        end
        connectEntry(entry.MouseButton1Click, function()
            if not container.Interactable or not button.Interactable or not entry.Interactable then return end
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

        local function hoverEntry(hovering)
            if TF(selected, value) then return end
            Tween(entry, Anim.Fast, { TextTransparency = hovering and 0.2 or 0.5 })
        end
        connectEntry(entry.MouseEnter, function() hoverEntry(true) end)
        connectEntry(entry.MouseLeave, function() hoverEntry(false) end)
        TIS(entries, { Button = entry, Value = value, Connections = connections })
	end

    local function readValues()
        local result = valuesSource
        if type(result) == "function" then result = result() end
        assert(type(result) == "table", "Dropdown Values must be a table or a function returning a table")
        local count = 0
        for _ in pairs(result) do count += 1 end
        local array = true
        for key in pairs(result) do
            if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > count then
                array = false
                break
            end
        end
        local labels, seen = {}, {}
        local function add(value)
            local label = toLabel(value)
            if not seen[label] then seen[label] = true; TIS(labels, label) end
        end
        if array then
            for index = 1, count do add(result[index]) end
        else
            for key in pairs(result) do add(key) end
            table.sort(labels, function(a, b)
                local lowerA, lowerB = a:lower(), b:lower()
                return lowerA == lowerB and a < b or lowerA < lowerB
            end)
        end
        return labels
    end
    local function clearEntries()
        local removed = {}
        for _, entry in ipairs(entries) do
            for _, connection in ipairs(entry.Connections) do
                connection:Disconnect()
                removed[connection] = true
            end
            entry.Button:Destroy()
        end
        table.clear(entries)
        local write = 1
        for read = 1, #Callisto.Connections do
            local connection = Callisto.Connections[read]
            if not removed[connection] then
                Callisto.Connections[write] = connection
                write += 1
            end
        end
        for index = #Callisto.Connections, write, -1 do Callisto.Connections[index] = nil end
    end
    reloadValues = function(preserveSelection: boolean)
        local ok, labels = pcall(readValues)
        if not ok then
            warn("[Callisto dropdown: " .. (options.Title or "Dropdown") .. "] " .. tostring(labels))
            return false
        end
        if not container.Parent then return false end
        local unchanged = #labels == #currentValues
        if unchanged then
            for index, label in ipairs(labels) do
                if currentValues[index] ~= label then unchanged = false; break end
            end
        end
        local retained = {}
        if preserveSelection then
            for _, value in ipairs(selected) do
                if TF(labels, value) and not TF(retained, value) then
                    TIS(retained, value)
                    if not multi then break end
                end
            end
        end
        selected = retained
        currentValues = labels
        options.Values = table.clone(labels)
        if unchanged then render(); return true end
        local state = Fader.State[popup]
        if state ~= nil and state ~= "shown" then Fader.In(popup, TI(0)) end
        clearEntries()
        for _, label in ipairs(labels) do AddOption(label) end
        inner.CanvasPosition = V2(0, 0)
        render()
        if state == "hidden" then
            Fader.State[popup] = "shown"
            Fader.Out(popup, TI(0))
        elseif state ~= nil then
            Fader.State[popup] = "shown"
            Fader.Out(popup, TI(0))
            Fader.In(popup, TI(0))
        end
        if open then
            local height = math.min(#entries * ENTRY_HEIGHT + math.max(#entries - 1, 0) * ENTRY_GAP + 11,
                options.MaxHeight or 160)
            popup.Size = UFO(MR(button.AbsoluteSize.X), height)
        end
        return true
    end
    reloadValues(true)

	-- prime the fader with the fully-built option list (see colorpicker note)
	Fader.Out(popup, TI(0))

	Connect(button.MouseButton1Click, function()
		setOpen(not open)
	end)

	Hover(button, function(hovering)
		SetBorderActive(stroke, hovering)
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
            selected = {}
            if typeof(value) == "table" then
                for _, item in ipairs(value) do
                    local label = toLabel(item)
                    if not TF(selected, label) then TIS(selected, label) end
                    if not multi then break end
                end
            elseif value ~= nil then
                TIS(selected, toLabel(value))
            end
            render()
        end,
        Refresh = function(_, newValues)
            if newValues ~= nil then valuesSource = newValues end
            return reloadValues(newValues == nil)
        end,
        GetValues = function() return table.clone(currentValues) end,
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
    if #Callisto.Windows == 1 and Callisto.Windows[1] == self then
        Callisto:Unload()
        return
    end
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

do
    local order = ConfigOrder
    local applying = 0

    local function equal(a, b)
        if typeof(a) ~= typeof(b) then return false end
        if typeof(a) ~= "table" then return a == b end
        for key, value in pairs(a) do if not equal(value, b[key]) then return false end end
        for key in pairs(b) do if a[key] == nil then return false end end
        return true
    end

    local function finite(value)
        return type(value) == "number" and value == value and math.abs(value) < math.huge
    end

    local function read(entry)
        local value, extra = entry.Control.Get()
        if entry.Kind == "Colorpicker" then return { Color = value, Alpha = extra or 0 } end
        if entry.Kind == "Switch" then return extra end
        return typeof(value) == "table" and table.clone(value) or value
    end

    local function encode(entry, value)
        local record = { Kind = entry.Kind }
        if value == nil then record.None = true
        elseif entry.Kind == "Keybind" then record.Value = value.Name
        elseif entry.Kind == "Colorpicker" then
            record.Value = { value.Color.R, value.Color.G, value.Color.B, value.Alpha }
        else
            record.Value = typeof(value) == "table" and table.clone(value) or value
        end
        return record
    end

    local function sync(entry)
        if applying > 0 then return end
        local value = read(entry)
        Callisto.Flags[entry.Flag] = entry.Kind == "Colorpicker" and value.Color or value
        local record = encode(entry, value)
        if equal(record, entry.Record) then return end
        entry.Record = record
        if ConfigManager and not ConfigManager.Stopped then ConfigManager:_Changed() end
    end

    local function normalize(entry, value)
        local kind, opts = entry.Kind, entry.Options
        if kind == "Toggle" then return type(value) == "boolean", value end
        if kind == "Slider" then
            if not finite(value) then return false end
            return true, MC(value, opts.Min or 0, opts.Max or 100)
        end
        if kind == "Input" then return type(value) == "string", value end
        if kind == "Keybind" then
            if value == nil or value == EKC.Unknown then return true, nil end
            return typeof(value) == "EnumItem" and value.EnumType == EKC, value
        end
        if kind == "Colorpicker" then
            if type(value) ~= "table" or typeof(value.Color) ~= "Color3" or not finite(value.Alpha) then return false end
            return true, { Color = value.Color, Alpha = MC(value.Alpha, 0, 1) }
        end
        if kind == "Switch" then
            if not finite(value) or value % 1 ~= 0 then return false end
            local item = (opts.Values or {})[value]
            return item ~= nil and not (type(item) == "table" and item.Disabled), value
        end
        if kind == "Dropdown" then
            local values = entry.Control.GetValues and entry.Control.GetValues() or opts.Values or opts.Options or {}
            local function exists(item)
                for _, candidate in ipairs(values) do if tostring(candidate) == item then return true end end
                return false
            end
            if opts.Multi or opts.MultiSelect then
                if type(value) ~= "table" then return false end
                local filtered = {}
                for _, item in ipairs(value) do
                    if type(item) == "string" and exists(item) and not TF(filtered, item) then TIS(filtered, item) end
                end
                return true, filtered
            end
            if value == nil then return true, nil end
            return type(value) == "string" and exists(value), value
        end
        return false
    end

    local function dispatch(entry, args)
        local parent = CallbackContexts[coroutine.running()]
        if parent and parent[entry] then return end
        if entry.CallbackRunning and entry.Worker and coroutine.status(entry.Worker) == "dead" then
            entry.CallbackRunning = false
        end
        entry.PendingCallback = { Args = args, Context = parent }
        if entry.CallbackRunning then return end
        entry.CallbackRunning = true
        task.spawn(function()
            local worker = coroutine.running()
            entry.Worker = worker
            while entry.PendingCallback do
                local job = entry.PendingCallback
                entry.PendingCallback = nil
                local context = job.Context and table.clone(job.Context) or {}
                context[entry] = true
                CallbackContexts[worker] = context
                local ok, err = pcall(entry.Callback, table.unpack(job.Args, 1, job.Args.n))
                CallbackContexts[worker] = nil
                if not ok then warn("[Callisto callback: " .. entry.Flag .. "] " .. tostring(err)) end
            end
            entry.CallbackRunning = false
            entry.Worker = nil
        end)
    end

    local function notify(entry)
        local manager = ConfigManager
        if not entry.Callback or entry.Kind == "Keybind" or (entry.VIP and manager and not manager:_Premium()) then return end
        local args
        if entry.Kind == "Colorpicker" then
            local value = read(entry)
            args = table.pack(value.Color, value.Alpha)
        elseif entry.Kind == "Switch" then args = table.pack(entry.Control.Get())
        elseif entry.Kind == "Input" then args = table.pack(read(entry), false)
        else args = table.pack(read(entry)) end
        dispatch(entry, args)
    end

    local methods = {
        AddToggle = "Toggle", AddSlider = "Slider", AddInput = "Input", AddDropdown = "Dropdown",
        AddColorpicker = "Colorpicker", AddKeybind = "Keybind", AddSwitch = "Switch",
    }
    for method, kind in pairs(methods) do
        local original = Section[method]
        Section[method] = function(self, options)
            if not options.Flag or options.Config == false then return original(self, options) end
            assert(type(options.Flag) == "string" and options.Flag ~= "", "Flag must be a nonempty string")
            assert(not ConfigEntries[options.Flag], "Duplicate config Flag: " .. options.Flag)
            local opts = table.clone(options)
            local entry = { Flag = opts.Flag, Kind = kind, Options = opts, VIP = opts.VIP == true, Callback = opts.Callback }
            opts.Callback = function(...)
                if not entry.Control or applying > 0 then return end
                local manager = ConfigManager
                if manager and not manager.Stopped and entry.VIP and not manager:_Premium() then
                    manager:_Apply(entry, entry.Fallback, false)
                    return
                end
                if kind == "Colorpicker" or kind == "Switch" then sync(entry) end
                if entry.Callback then dispatch(entry, table.pack(...)) end
            end
            entry.Control = original(self, opts)
            entry.NativeSet = entry.Control.Set
            entry.Fallback = read(entry)
            if kind == "Toggle" then entry.Fallback = false
            elseif kind == "Keybind" then entry.Fallback = nil
            elseif kind == "Dropdown" then entry.Fallback = (opts.Multi or opts.MultiSelect) and {} or nil end
            entry.Sync = function() sync(entry) end
            ConfigEntries[entry.Flag] = entry
            TIS(order, entry)
            sync(entry)
            entry.Control.Set = function(control, value, extra)
                local manager = ConfigManager
                if manager and not manager.Stopped then
                    if kind == "Colorpicker" then
                        local current = read(entry)
                        value = { Color = value, Alpha = extra == nil and current.Alpha or extra }
                    end
                    local ok, err = manager:_Apply(entry, value, true)
                    if not ok then warn("[Callisto config] " .. tostring(err)) end
                    return
                end
                local results = table.pack(entry.NativeSet(control, value, extra))
                sync(entry)
                return table.unpack(results, 1, results.n)
            end
            if entry.Control.Refresh then
                local refresh = entry.Control.Refresh
                entry.Control.Refresh = function(control, ...)
                    local results = table.pack(refresh(control, ...))
                    sync(entry)
                    return table.unpack(results, 1, results.n)
                end
            end
            if ConfigManager and not ConfigManager.Stopped and entry.VIP and not ConfigManager:_Premium() then
                ConfigManager:_Apply(entry, entry.Fallback, false)
            end
            return entry.Control
        end
    end

    function Callisto:CreateConfig(settings)
        assert(not ConfigManager or ConfigManager.Stopped, "Callisto config is already active")
        settings = settings or {}
        local http = game:GetService("HttpService")
        local folder, filename = settings.Folder or "bxor", settings.File or "config.json"
        local name = settings.Name or "san-aurie"
        local delay = settings.SaveDelay or settings.Interval or 0.75
        assert(type(folder) == "string", "Folder must be a string")
        assert(type(filename) == "string" and filename:match("^[%w_%-%.]+$") and not filename:find("..", 1, true),
            "File must be a simple filename")
        assert(type(name) == "string" and name ~= "", "Name must be a nonempty string")
        assert(finite(delay) and delay >= 0.05, "SaveDelay must be at least 0.05 seconds")
        local manager = { Name = name, Path = folder ~= "" and folder .. "/" .. filename or filename,
            Dirty = true, Ready = false, Stopped = false }
        local lastSaved, pending, token, lastChange, lastError = nil, nil, 0, 0, nil
        local loading = false
        ConfigManager = manager

        function manager:_Premium()
            local ok, value = pcall(settings.IsPremium or function() return false end)
            return ok and value == true
        end

        local function cancelPending()
            token += 1
            if pending and task.cancel then pcall(task.cancel, pending) end
            pending = nil
        end

        function manager:_Schedule()
            if self.Stopped or not self.Ready or loading or settings.AutoSave == false or pending then return end
            local generation = token
            local flush
            flush = function()
                pending = nil
                if self.Stopped or not self.Ready or generation ~= token then return end
                local remaining = delay - (os.clock() - lastChange)
                if remaining > 0.0001 then pending = task.delay(remaining, flush); return end
                if not self.Dirty then return end
                local ok, err = self:Save()
                if not ok and err ~= lastError then warn("[Callisto config] " .. tostring(err)) end
                lastError = not ok and err or nil
            end
            pending = task.delay(delay, flush)
        end

        function manager:_Changed()
            if self.Stopped then return end
            self.Dirty = true
            lastChange = os.clock()
            self:_Schedule()
        end

        function manager:_Apply(entry, value, fireCallback)
            local permit = not entry.VIP or self:_Premium()
            if not permit then value = entry.Fallback end
            local valid, normalized = normalize(entry, value)
            if not valid then return false, "Invalid value for " .. entry.Flag end
            if (not permit or entry.CallbackRunning) and equal(entry.Record, encode(entry, normalized)) then return true end
            applying += 1
            local ok, err = pcall(function()
                if entry.Kind == "Colorpicker" then entry.NativeSet(entry.Control, normalized.Color, normalized.Alpha)
                else entry.NativeSet(entry.Control, normalized) end
            end)
            applying -= 1
            if not ok then return false, tostring(err) end
            sync(entry)
            if permit and fireCallback then notify(entry) end
            return true
        end

        function manager:RefreshAccess()
            if self.Stopped then return false, "Config manager has stopped" end
            if not self:_Premium() then
                for _, entry in ipairs(order) do
                    if entry.VIP then self:_Apply(entry, entry.Fallback, false) end
                end
            end
            return true
        end

        local function readDocument()
            assert(type(isfile) == "function" and type(readfile) == "function", "File APIs are unavailable")
            if not isfile(manager.Path) then return { Version = 1, Profiles = {} } end
            local document = http:JSONDecode(readfile(manager.Path))
            assert(type(document) == "table" and document.Version == 1, "Unsupported config format")
            if type(document.Profiles) ~= "table" then
                assert(type(document.Values) == "table", "Unsupported config format")
                document = { Version = 1, Profiles = { [name] = { Values = document.Values } } }
            end
            return document
        end

        function manager:Save()
            if self.Stopped then return false, "Config manager has stopped" end
            cancelPending()
            self:RefreshAccess()
            cancelPending()
            local profile, premium = { Values = {} }, self:_Premium()
            for _, entry in ipairs(order) do
                if not entry.VIP or premium then profile.Values[entry.Flag] = entry.Record end
            end
            if lastSaved and equal(profile, lastSaved) then self.Dirty = false; self.Ready = true; return true end
            local ok, err = pcall(function()
                assert(type(writefile) == "function", "writefile is unavailable")
                if folder ~= "" then
                    assert(type(isfolder) == "function" and type(makefolder) == "function", "Folder APIs are unavailable")
                    if not isfolder(folder) then makefolder(folder) end
                end
                local document = readDocument()
                document.Profiles[name] = profile
                writefile(self.Path, http:JSONEncode(document))
            end)
            if not ok then return false, tostring(err) end
            lastSaved = profile
            self.Dirty, self.Ready = false, true
            return true
        end

        local function decode(entry, record)
            if type(record) ~= "table" or record.Kind ~= entry.Kind then return false end
            if record.None == true then
                if entry.Kind == "Keybind" or (entry.Kind == "Dropdown"
                    and not (entry.Options.Multi or entry.Options.MultiSelect)) then return true, nil end
                return false
            end
            local value = record.Value
            if entry.Kind == "Keybind" then
                if type(value) ~= "string" then return false end
                local ok, item = pcall(function() return EKC[value] end)
                if not ok or typeof(item) ~= "EnumItem" then return false end
                value = item
            elseif entry.Kind == "Colorpicker" then
                if type(value) ~= "table" then return false end
                for i = 1, 4 do if not finite(value[i]) or value[i] < 0 or value[i] > 1 then return false end end
                value = { Color = Color3.new(value[1], value[2], value[3]), Alpha = value[4] }
            end
            return normalize(entry, value)
        end

        function manager:Load()
            if self.Stopped then return false, "Config manager has stopped" end
            cancelPending()
            loading = true
            self:RefreshAccess()
            local ok, profile = pcall(function()
                local document = readDocument()
                local value = document.Profiles[name]
                if value == nil then return nil end
                assert(type(value) == "table" and type(value.Values) == "table", "Invalid named config")
                return value
            end)
            if not ok then self.Ready = false; loading = false; return false, tostring(profile) end
            local restored, skipped = {}, {}
            if profile then
                local premium = self:_Premium()
                for _, entry in ipairs(order) do
                    local record = profile.Values[entry.Flag]
                    if record ~= nil and (not entry.VIP or premium) then
                        local valid, value = decode(entry, record)
                        if valid then
                            local applied, err = self:_Apply(entry, value, false)
                            if applied then TIS(restored, entry) else TIS(skipped, entry.Flag .. ": " .. tostring(err)) end
                        else TIS(skipped, entry.Flag) end
                    end
                end
            end
            lastSaved = profile
            self.Ready, self.Dirty = true, true
            loading = false
            for _, entry in ipairs(restored) do notify(entry) end
            if #skipped > 0 then warn("[Callisto config] Skipped invalid values: " .. table.concat(skipped, ", ")) end
            self:_Changed()
            return true, not profile and "No saved config yet" or nil
        end

        function manager:Stop()
            if self.Stopped then return end
            cancelPending()
            self.Stopped = true
        end

        self.Config = manager
        manager:RefreshAccess()
        return manager
    end
end

-- Full teardown: every window, every connection, every theme registration.
function Callisto:Unload()
    if ConfigManager and not ConfigManager.Stopped then
        if ConfigManager.Ready then ConfigManager:Save() end
        ConfigManager:Stop()
    end
    for _, entry in ipairs(ConfigOrder) do
        entry.PendingCallback = nil
        local worker = entry.Worker
        if worker and worker ~= coroutine.running() and coroutine.status(worker) ~= "dead" and task.cancel then
            pcall(task.cancel, worker)
        end
        entry.Worker = nil
        entry.CallbackRunning = false
    end
    table.clear(CallbackContexts)
    local tweens = {}
    for tween in pairs(ActiveTweens) do TIS(tweens, tween) end
    for _, tween in ipairs(tweens) do
        local connection = ActiveTweens[tween]
        if connection then connection:Disconnect() end
        pcall(function() tween:Cancel(); tween:Destroy() end)
        ActiveTweens[tween] = nil
    end
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
	table.clear(BorderStates)
	table.clear(GradientRegistry)
	table.clear(self.Flags)
	table.clear(ConfigEntries)
	table.clear(ConfigOrder)
    ConfigManager = nil
    self.Config = nil
	table.clear(LockedStates)
	table.clear(LockedScrollers)
	Fader.Clear()
end

return Callisto
