--[[
  Fluent Renew - Single file, no venv.
  Source: https://github.com/dawid-scripts/Fluent (MIT)
  Use: loadstring(readfile("fluent_renew.lua"))()
]]

local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local LocalPlayer = game:GetService("Players").LocalPlayer
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local Camera = game:GetService("Workspace").CurrentCamera
local Mouse = LocalPlayer:GetMouse()

-- Library ref for circular deps (Creator, Notification, Tab use it)
local LibraryRef = {}
local function getLibrary()
  return LibraryRef[1]
end

-- ============ Flipper ============
local Connection = {}
Connection.__index = Connection
function Connection.new(signal, handler)
  return setmetatable({ signal = signal, connected = true, _handler = handler }, Connection)
end
function Connection:disconnect()
  if self.connected then
    self.connected = false
    for i, c in pairs(self.signal._connections) do
      if c == self then table.remove(self.signal._connections, i) return end
    end
  end
end

local Signal = {}
Signal.__index = Signal
function Signal.new()
  return setmetatable({ _connections = {}, _threads = {} }, Signal)
end
function Signal:fire(...)
  for _, c in pairs(self._connections) do c._handler(...) end
  for _, t in pairs(self._threads) do coroutine.resume(t, ...) end
  self._threads = {}
end
function Signal:connect(handler)
  local c = Connection.new(self, handler)
  table.insert(self._connections, c)
  return c
end
function Signal:wait()
  table.insert(self._threads, coroutine.running())
  return coroutine.yield()
end

local BaseMotor = {}
BaseMotor.__index = BaseMotor
function BaseMotor.new()
  return setmetatable({
    _onStep = Signal.new(),
    _onStart = Signal.new(),
    _onComplete = Signal.new(),
  }, BaseMotor)
end
function BaseMotor:onStep(h) return self._onStep:connect(h) end
function BaseMotor:onStart(h) return self._onStart:connect(h) end
function BaseMotor:onComplete(h) return self._onComplete:connect(h) end
function BaseMotor:start()
  if not self._connection then
    self._connection = RunService.RenderStepped:Connect(function(dt) self:step(dt) end)
  end
end
function BaseMotor:stop()
  if self._connection then self._connection:Disconnect() self._connection = nil end
end
BaseMotor.destroy = BaseMotor.stop
BaseMotor.step = function() end
BaseMotor.getValue = function() end
BaseMotor.setGoal = function() end

local Instant = {}
Instant.__index = Instant
function Instant.new(targetValue)
  return setmetatable({ _targetValue = targetValue }, Instant)
end
function Instant:step()
  return { complete = true, value = self._targetValue }
end

local VELOCITY_THRESHOLD, POSITION_THRESHOLD, EPS = 0.001, 0.001, 0.0001
local Spring = {}
Spring.__index = Spring
function Spring.new(targetValue, options)
  options = options or {}
  return setmetatable({
    _targetValue = targetValue,
    _frequency = options.frequency or 4,
    _dampingRatio = options.dampingRatio or 1,
  }, Spring)
end
function Spring:step(state, dt)
  local d, f, g = self._dampingRatio, self._frequency * 2 * math.pi, self._targetValue
  local p0, v0 = state.value, state.velocity or 0
  local offset, decay = p0 - g, math.exp(-d * f * dt)
  local p1, v1
  if d == 1 then
    p1 = (offset * (1 + f * dt) + v0 * dt) * decay + g
    v1 = (v0 * (1 - f * dt) - offset * (f * f * dt)) * decay
  elseif d < 1 then
    local c = math.sqrt(1 - d * d)
    local i, j = math.cos(f * c * dt), math.sin(f * c * dt)
    local z = c > EPS and j / c or (dt * f) + ((dt * f) ^ 3 * (c * c) / 6)
    local y = (f * c > EPS) and (j / (f * c)) or (dt + (dt * dt * dt * (f * c) ^ 2 / 6))
    p1 = (offset * (i + d * z) + v0 * y) * decay + g
    v1 = (v0 * (i - z * d) - offset * (z * f)) * decay
  else
    local c = math.sqrt(d * d - 1)
    local r1, r2 = -f * (d - c), -f * (d + c)
    local co2 = (v0 - offset * r1) / (2 * f * c)
    local co1 = offset - co2
    p1 = co1 * math.exp(r1 * dt) + co2 * math.exp(r2 * dt) + g
    v1 = co1 * r1 * math.exp(r1 * dt) + co2 * r2 * math.exp(r2 * dt)
  end
  local complete = math.abs(v1) < VELOCITY_THRESHOLD and math.abs(p1 - g) < POSITION_THRESHOLD
  return { complete = complete, value = complete and g or p1, velocity = v1 }
end

local Linear = {}
Linear.__index = Linear
function Linear.new(targetValue, options)
  options = options or {}
  return setmetatable({ _targetValue = targetValue, _velocity = options.velocity or 1 }, Linear)
end
function Linear:step(state, dt)
  local pos, vel, goal = state.value, self._velocity, self._targetValue
  local dPos = dt * vel
  local complete = dPos >= math.abs(goal - pos)
  pos = pos + dPos * (goal > pos and 1 or -1)
  if complete then pos, vel = goal, 0 end
  return { complete = complete, value = pos, velocity = vel }
end

local SingleMotor = setmetatable({}, BaseMotor)
SingleMotor.__index = SingleMotor
function SingleMotor.new(initialValue, useImplicitConnections)
  assert(typeof(initialValue) == "number", "initialValue must be a number")
  local self = setmetatable(BaseMotor.new(), SingleMotor)
  self._useImplicitConnections = useImplicitConnections ~= nil and useImplicitConnections or true
  self._goal = nil
  self._state = { complete = true, value = initialValue }
  return self
end
function SingleMotor:step(dt)
  if self._state.complete then return true end
  local newState = self._goal:step(self._state, dt)
  self._state = newState
  self._onStep:fire(newState.value)
  if newState.complete then
    if self._useImplicitConnections then self:stop() end
    self._onComplete:fire()
  end
  return newState.complete
end
function SingleMotor:getValue() return self._state.value end
function SingleMotor:setGoal(goal)
  self._state.complete = false
  self._goal = goal
  self._onStart:fire()
  if self._useImplicitConnections then self:start() end
end

local isMotor = function(v)
  local t = tostring(v):match("^Motor%((.+)%)$")
  return t and true or false, t
end

local GroupMotor = setmetatable({}, BaseMotor)
GroupMotor.__index = GroupMotor
local function toMotor(value)
  if isMotor(value) then return value end
  if typeof(value) == "number" then return SingleMotor.new(value, false) end
  if typeof(value) == "table" then return GroupMotor.new(value, false) end
  error("Unable to convert to motor", 2)
end
function GroupMotor.new(initialValues, useImplicitConnections)
  assert(typeof(initialValues) == "table", "initialValues must be a table")
  local self = setmetatable(BaseMotor.new(), GroupMotor)
  self._useImplicitConnections = useImplicitConnections ~= nil and useImplicitConnections or true
  self._complete = true
  self._motors = {}
  for k, v in pairs(initialValues) do self._motors[k] = toMotor(v) end
  return self
end
function GroupMotor:step(dt)
  if self._complete then return true end
  local all = true
  for _, m in pairs(self._motors) do if not m:step(dt) then all = false end end
  self._onStep:fire(self:getValue())
  if all then
    if self._useImplicitConnections then self:stop() end
    self._complete = true
    self._onComplete:fire()
  end
  return all
end
function GroupMotor:setGoal(goals)
  self._complete = false
  self._onStart:fire()
  for k, goal in pairs(goals) do self._motors[k]:setGoal(goal) end
  if self._useImplicitConnections then self:start() end
end
function GroupMotor:getValue()
  local r = {}
  for k, m in pairs(self._motors) do r[k] = m:getValue() end
  return r
end

local Flipper = {
  SingleMotor = SingleMotor,
  GroupMotor = GroupMotor,
  Instant = Instant,
  Linear = Linear,
  Spring = Spring,
  isMotor = isMotor,
}

-- ============ Themes ============
local ThemeDark = {
  Name = "Dark",
  Accent = Color3.fromRGB(96, 205, 255),
  AcrylicMain = Color3.fromRGB(60, 60, 60),
  AcrylicBorder = Color3.fromRGB(90, 90, 90),
  AcrylicGradient = ColorSequence.new(Color3.fromRGB(40, 40, 40), Color3.fromRGB(40, 40, 40)),
  AcrylicNoise = 0.9,
  TitleBarLine = Color3.fromRGB(75, 75, 75),
  Tab = Color3.fromRGB(120, 120, 120),
  Element = Color3.fromRGB(120, 120, 120),
  ElementBorder = Color3.fromRGB(35, 35, 35),
  InElementBorder = Color3.fromRGB(90, 90, 90),
  ElementTransparency = 0.87,
  ToggleSlider = Color3.fromRGB(120, 120, 120),
  ToggleToggled = Color3.fromRGB(0, 0, 0),
  SliderRail = Color3.fromRGB(120, 120, 120),
  DropdownFrame = Color3.fromRGB(160, 160, 160),
  DropdownHolder = Color3.fromRGB(45, 45, 45),
  DropdownBorder = Color3.fromRGB(35, 35, 35),
  DropdownOption = Color3.fromRGB(120, 120, 120),
  Keybind = Color3.fromRGB(120, 120, 120),
  Input = Color3.fromRGB(160, 160, 160),
  InputFocused = Color3.fromRGB(10, 10, 10),
  InputIndicator = Color3.fromRGB(150, 150, 150),
  Dialog = Color3.fromRGB(45, 45, 45),
  DialogHolder = Color3.fromRGB(35, 35, 35),
  DialogHolderLine = Color3.fromRGB(30, 30, 30),
  DialogButton = Color3.fromRGB(45, 45, 45),
  DialogButtonBorder = Color3.fromRGB(80, 80, 80),
  DialogBorder = Color3.fromRGB(70, 70, 70),
  DialogInput = Color3.fromRGB(55, 55, 55),
  DialogInputLine = Color3.fromRGB(160, 160, 160),
  Text = Color3.fromRGB(240, 240, 240),
  SubText = Color3.fromRGB(170, 170, 170),
  Hover = Color3.fromRGB(120, 120, 120),
  HoverChange = 0.07,
}

local ThemeDarker = {
  Name = "Darker",
  Accent = Color3.fromRGB(72, 138, 182),
  AcrylicMain = Color3.fromRGB(30, 30, 30),
  AcrylicBorder = Color3.fromRGB(60, 60, 60),
  AcrylicGradient = ColorSequence.new(Color3.fromRGB(25, 25, 25), Color3.fromRGB(15, 15, 15)),
  AcrylicNoise = 0.94,
  TitleBarLine = Color3.fromRGB(65, 65, 65),
  Tab = Color3.fromRGB(100, 100, 100),
  Element = Color3.fromRGB(70, 70, 70),
  ElementBorder = Color3.fromRGB(25, 25, 25),
  InElementBorder = Color3.fromRGB(55, 55, 55),
  ElementTransparency = 0.82,
  ToggleSlider = Color3.fromRGB(100, 100, 100),
  ToggleToggled = Color3.fromRGB(0, 0, 0),
  SliderRail = Color3.fromRGB(100, 100, 100),
  DropdownFrame = Color3.fromRGB(120, 120, 120),
  DropdownHolder = Color3.fromRGB(35, 35, 35),
  DropdownBorder = Color3.fromRGB(25, 25, 25),
  DropdownOption = Color3.fromRGB(100, 100, 100),
  Keybind = Color3.fromRGB(100, 100, 100),
  Input = Color3.fromRGB(120, 120, 120),
  InputFocused = Color3.fromRGB(10, 10, 10),
  InputIndicator = Color3.fromRGB(120, 120, 120),
  Dialog = Color3.fromRGB(35, 35, 35),
  DialogHolder = Color3.fromRGB(25, 25, 25),
  DialogHolderLine = Color3.fromRGB(20, 20, 20),
  DialogButton = Color3.fromRGB(35, 35, 35),
  DialogButtonBorder = Color3.fromRGB(55, 55, 55),
  DialogBorder = Color3.fromRGB(50, 50, 50),
  DialogInput = Color3.fromRGB(45, 45, 45),
  DialogInputLine = Color3.fromRGB(120, 120, 120),
  Text = Color3.fromRGB(230, 230, 230),
  SubText = Color3.fromRGB(150, 150, 150),
  Hover = Color3.fromRGB(100, 100, 100),
  HoverChange = 0.07,
}

local ThemeLight = {
  Name = "Light",
  Accent = Color3.fromRGB(0, 103, 192),
  AcrylicMain = Color3.fromRGB(200, 200, 200),
  AcrylicBorder = Color3.fromRGB(120, 120, 120),
  AcrylicGradient = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(255, 255, 255)),
  AcrylicNoise = 0.96,
  TitleBarLine = Color3.fromRGB(160, 160, 160),
  Tab = Color3.fromRGB(90, 90, 90),
  Element = Color3.fromRGB(255, 255, 255),
  ElementBorder = Color3.fromRGB(180, 180, 180),
  InElementBorder = Color3.fromRGB(150, 150, 150),
  ElementTransparency = 0.65,
  ToggleSlider = Color3.fromRGB(40, 40, 40),
  ToggleToggled = Color3.fromRGB(255, 255, 255),
  SliderRail = Color3.fromRGB(40, 40, 40),
  DropdownFrame = Color3.fromRGB(200, 200, 200),
  DropdownHolder = Color3.fromRGB(240, 240, 240),
  DropdownBorder = Color3.fromRGB(200, 200, 200),
  DropdownOption = Color3.fromRGB(150, 150, 150),
  Keybind = Color3.fromRGB(120, 120, 120),
  Input = Color3.fromRGB(200, 200, 200),
  InputFocused = Color3.fromRGB(100, 100, 100),
  InputIndicator = Color3.fromRGB(80, 80, 80),
  Dialog = Color3.fromRGB(255, 255, 255),
  DialogHolder = Color3.fromRGB(240, 240, 240),
  DialogHolderLine = Color3.fromRGB(228, 228, 228),
  DialogButton = Color3.fromRGB(255, 255, 255),
  DialogButtonBorder = Color3.fromRGB(190, 190, 190),
  DialogBorder = Color3.fromRGB(140, 140, 140),
  DialogInput = Color3.fromRGB(250, 250, 250),
  DialogInputLine = Color3.fromRGB(160, 160, 160),
  Text = Color3.fromRGB(0, 0, 0),
  SubText = Color3.fromRGB(40, 40, 40),
  Hover = Color3.fromRGB(50, 50, 50),
  HoverChange = 0.16,
}

local ThemeAqua = {
  Name = "Aqua",
  Accent = Color3.fromRGB(60, 165, 165),
  AcrylicMain = Color3.fromRGB(20, 20, 20),
  AcrylicBorder = Color3.fromRGB(50, 100, 100),
  AcrylicGradient = ColorSequence.new(Color3.fromRGB(60, 140, 140), Color3.fromRGB(40, 80, 80)),
  AcrylicNoise = 0.92,
  TitleBarLine = Color3.fromRGB(60, 120, 120),
  Tab = Color3.fromRGB(140, 180, 180),
  Element = Color3.fromRGB(110, 160, 160),
  ElementBorder = Color3.fromRGB(40, 70, 70),
  InElementBorder = Color3.fromRGB(80, 110, 110),
  ElementTransparency = 0.84,
  ToggleSlider = Color3.fromRGB(110, 160, 160),
  ToggleToggled = Color3.fromRGB(0, 0, 0),
  SliderRail = Color3.fromRGB(110, 160, 160),
  DropdownFrame = Color3.fromRGB(160, 200, 200),
  DropdownHolder = Color3.fromRGB(40, 80, 80),
  DropdownBorder = Color3.fromRGB(40, 65, 65),
  DropdownOption = Color3.fromRGB(110, 160, 160),
  Keybind = Color3.fromRGB(110, 160, 160),
  Input = Color3.fromRGB(110, 160, 160),
  InputFocused = Color3.fromRGB(20, 10, 30),
  InputIndicator = Color3.fromRGB(130, 170, 170),
  Dialog = Color3.fromRGB(40, 80, 80),
  DialogHolder = Color3.fromRGB(30, 60, 60),
  DialogHolderLine = Color3.fromRGB(25, 50, 50),
  DialogButton = Color3.fromRGB(40, 80, 80),
  DialogButtonBorder = Color3.fromRGB(80, 110, 110),
  DialogBorder = Color3.fromRGB(50, 100, 100),
  DialogInput = Color3.fromRGB(45, 90, 90),
  DialogInputLine = Color3.fromRGB(130, 170, 170),
  Text = Color3.fromRGB(240, 240, 240),
  SubText = Color3.fromRGB(170, 170, 170),
  Hover = Color3.fromRGB(110, 160, 160),
  HoverChange = 0.04,
}

local ThemeAmethyst = {
  Name = "Amethyst",
  Accent = Color3.fromRGB(97, 62, 167),
  AcrylicMain = Color3.fromRGB(20, 20, 20),
  AcrylicBorder = Color3.fromRGB(110, 90, 130),
  AcrylicGradient = ColorSequence.new(Color3.fromRGB(85, 57, 139), Color3.fromRGB(40, 25, 65)),
  AcrylicNoise = 0.92,
  TitleBarLine = Color3.fromRGB(95, 75, 110),
  Tab = Color3.fromRGB(160, 140, 180),
  Element = Color3.fromRGB(140, 120, 160),
  ElementBorder = Color3.fromRGB(60, 50, 70),
  InElementBorder = Color3.fromRGB(100, 90, 110),
  ElementTransparency = 0.87,
  ToggleSlider = Color3.fromRGB(140, 120, 160),
  ToggleToggled = Color3.fromRGB(0, 0, 0),
  SliderRail = Color3.fromRGB(140, 120, 160),
  DropdownFrame = Color3.fromRGB(170, 160, 200),
  DropdownHolder = Color3.fromRGB(60, 45, 80),
  DropdownBorder = Color3.fromRGB(50, 40, 65),
  DropdownOption = Color3.fromRGB(140, 120, 160),
  Keybind = Color3.fromRGB(140, 120, 160),
  Input = Color3.fromRGB(140, 120, 160),
  InputFocused = Color3.fromRGB(20, 10, 30),
  InputIndicator = Color3.fromRGB(170, 150, 190),
  Dialog = Color3.fromRGB(60, 45, 80),
  DialogHolder = Color3.fromRGB(45, 30, 65),
  DialogHolderLine = Color3.fromRGB(40, 25, 60),
  DialogButton = Color3.fromRGB(60, 45, 80),
  DialogButtonBorder = Color3.fromRGB(95, 80, 110),
  DialogBorder = Color3.fromRGB(85, 70, 100),
  DialogInput = Color3.fromRGB(70, 55, 85),
  DialogInputLine = Color3.fromRGB(175, 160, 190),
  Text = Color3.fromRGB(240, 240, 240),
  SubText = Color3.fromRGB(170, 170, 170),
  Hover = Color3.fromRGB(140, 120, 160),
  HoverChange = 0.04,
}

local ThemeRose = {
  Name = "Rose",
  Accent = Color3.fromRGB(180, 55, 90),
  AcrylicMain = Color3.fromRGB(40, 40, 40),
  AcrylicBorder = Color3.fromRGB(130, 90, 110),
  AcrylicGradient = ColorSequence.new(Color3.fromRGB(190, 60, 135), Color3.fromRGB(165, 50, 70)),
  AcrylicNoise = 0.92,
  TitleBarLine = Color3.fromRGB(140, 85, 105),
  Tab = Color3.fromRGB(180, 140, 160),
  Element = Color3.fromRGB(200, 120, 170),
  ElementBorder = Color3.fromRGB(110, 70, 85),
  InElementBorder = Color3.fromRGB(120, 90, 90),
  ElementTransparency = 0.86,
  ToggleSlider = Color3.fromRGB(200, 120, 170),
  ToggleToggled = Color3.fromRGB(0, 0, 0),
  SliderRail = Color3.fromRGB(200, 120, 170),
  DropdownFrame = Color3.fromRGB(200, 160, 180),
  DropdownHolder = Color3.fromRGB(120, 50, 75),
  DropdownBorder = Color3.fromRGB(90, 40, 55),
  DropdownOption = Color3.fromRGB(200, 120, 170),
  Keybind = Color3.fromRGB(200, 120, 170),
  Input = Color3.fromRGB(200, 120, 170),
  InputFocused = Color3.fromRGB(20, 10, 30),
  InputIndicator = Color3.fromRGB(170, 150, 190),
  Dialog = Color3.fromRGB(120, 50, 75),
  DialogHolder = Color3.fromRGB(95, 40, 60),
  DialogHolderLine = Color3.fromRGB(90, 35, 55),
  DialogButton = Color3.fromRGB(120, 50, 75),
  DialogButtonBorder = Color3.fromRGB(155, 90, 115),
  DialogBorder = Color3.fromRGB(100, 70, 90),
  DialogInput = Color3.fromRGB(135, 55, 80),
  DialogInputLine = Color3.fromRGB(190, 160, 180),
  Text = Color3.fromRGB(240, 240, 240),
  SubText = Color3.fromRGB(170, 170, 170),
  Hover = Color3.fromRGB(200, 120, 170),
  HoverChange = 0.04,
}

local ThemeNeon = {
  Name = "Neon",
  Accent = Color3.fromRGB(57, 255, 20),
  AcrylicMain = Color3.fromRGB(8, 8, 12),
  AcrylicBorder = Color3.fromRGB(30, 80, 30),
  AcrylicGradient = ColorSequence.new(Color3.fromRGB(5, 20, 5), Color3.fromRGB(0, 0, 0)),
  AcrylicNoise = 0.96,
  TitleBarLine = Color3.fromRGB(30, 80, 30),
  Tab = Color3.fromRGB(80, 200, 80),
  Element = Color3.fromRGB(50, 150, 50),
  ElementBorder = Color3.fromRGB(10, 30, 10),
  InElementBorder = Color3.fromRGB(30, 90, 30),
  ElementTransparency = 0.88,
  ToggleSlider = Color3.fromRGB(50, 150, 50),
  ToggleToggled = Color3.fromRGB(0, 0, 0),
  SliderRail = Color3.fromRGB(50, 150, 50),
  DropdownFrame = Color3.fromRGB(80, 200, 80),
  DropdownHolder = Color3.fromRGB(12, 30, 12),
  DropdownBorder = Color3.fromRGB(10, 25, 10),
  DropdownOption = Color3.fromRGB(50, 150, 50),
  Keybind = Color3.fromRGB(50, 150, 50),
  Input = Color3.fromRGB(80, 200, 80),
  InputFocused = Color3.fromRGB(5, 10, 5),
  InputIndicator = Color3.fromRGB(60, 180, 60),
  Dialog = Color3.fromRGB(12, 30, 12),
  DialogHolder = Color3.fromRGB(8, 20, 8),
  DialogHolderLine = Color3.fromRGB(5, 15, 5),
  DialogButton = Color3.fromRGB(12, 30, 12),
  DialogButtonBorder = Color3.fromRGB(30, 90, 30),
  DialogBorder = Color3.fromRGB(25, 70, 25),
  DialogInput = Color3.fromRGB(15, 40, 15),
  DialogInputLine = Color3.fromRGB(60, 180, 60),
  Text = Color3.fromRGB(200, 255, 200),
  SubText = Color3.fromRGB(100, 200, 100),
  Hover = Color3.fromRGB(50, 150, 50),
  HoverChange = 0.06,
}

local ThemeOcean = {
  Name = "Ocean",
  Accent = Color3.fromRGB(0, 150, 255),
  AcrylicMain = Color3.fromRGB(8, 15, 30),
  AcrylicBorder = Color3.fromRGB(20, 50, 100),
  AcrylicGradient = ColorSequence.new(Color3.fromRGB(5, 15, 40), Color3.fromRGB(2, 8, 20)),
  AcrylicNoise = 0.94,
  TitleBarLine = Color3.fromRGB(20, 50, 100),
  Tab = Color3.fromRGB(80, 150, 220),
  Element = Color3.fromRGB(40, 100, 180),
  ElementBorder = Color3.fromRGB(10, 25, 50),
  InElementBorder = Color3.fromRGB(30, 70, 130),
  ElementTransparency = 0.86,
  ToggleSlider = Color3.fromRGB(40, 100, 180),
  ToggleToggled = Color3.fromRGB(0, 0, 0),
  SliderRail = Color3.fromRGB(40, 100, 180),
  DropdownFrame = Color3.fromRGB(80, 150, 220),
  DropdownHolder = Color3.fromRGB(10, 25, 55),
  DropdownBorder = Color3.fromRGB(8, 20, 45),
  DropdownOption = Color3.fromRGB(40, 100, 180),
  Keybind = Color3.fromRGB(40, 100, 180),
  Input = Color3.fromRGB(80, 150, 220),
  InputFocused = Color3.fromRGB(5, 10, 25),
  InputIndicator = Color3.fromRGB(60, 130, 210),
  Dialog = Color3.fromRGB(10, 25, 55),
  DialogHolder = Color3.fromRGB(8, 18, 40),
  DialogHolderLine = Color3.fromRGB(5, 12, 30),
  DialogButton = Color3.fromRGB(10, 25, 55),
  DialogButtonBorder = Color3.fromRGB(30, 70, 130),
  DialogBorder = Color3.fromRGB(25, 60, 110),
  DialogInput = Color3.fromRGB(12, 30, 60),
  DialogInputLine = Color3.fromRGB(60, 130, 210),
  Text = Color3.fromRGB(210, 230, 255),
  SubText = Color3.fromRGB(120, 170, 220),
  Hover = Color3.fromRGB(40, 100, 180),
  HoverChange = 0.06,
}

local ThemeSunset = {
  Name = "Sunset",
  Accent = Color3.fromRGB(255, 100, 50),
  AcrylicMain = Color3.fromRGB(30, 15, 10),
  AcrylicBorder = Color3.fromRGB(100, 50, 30),
  AcrylicGradient = ColorSequence.new(Color3.fromRGB(60, 25, 10), Color3.fromRGB(30, 10, 5)),
  AcrylicNoise = 0.93,
  TitleBarLine = Color3.fromRGB(100, 50, 30),
  Tab = Color3.fromRGB(220, 130, 90),
  Element = Color3.fromRGB(180, 90, 50),
  ElementBorder = Color3.fromRGB(50, 25, 15),
  InElementBorder = Color3.fromRGB(130, 65, 35),
  ElementTransparency = 0.86,
  ToggleSlider = Color3.fromRGB(180, 90, 50),
  ToggleToggled = Color3.fromRGB(0, 0, 0),
  SliderRail = Color3.fromRGB(180, 90, 50),
  DropdownFrame = Color3.fromRGB(220, 130, 90),
  DropdownHolder = Color3.fromRGB(50, 25, 12),
  DropdownBorder = Color3.fromRGB(40, 20, 10),
  DropdownOption = Color3.fromRGB(180, 90, 50),
  Keybind = Color3.fromRGB(180, 90, 50),
  Input = Color3.fromRGB(220, 130, 90),
  InputFocused = Color3.fromRGB(20, 10, 5),
  InputIndicator = Color3.fromRGB(200, 110, 70),
  Dialog = Color3.fromRGB(50, 25, 12),
  DialogHolder = Color3.fromRGB(40, 18, 8),
  DialogHolderLine = Color3.fromRGB(35, 15, 6),
  DialogButton = Color3.fromRGB(50, 25, 12),
  DialogButtonBorder = Color3.fromRGB(130, 65, 35),
  DialogBorder = Color3.fromRGB(110, 55, 30),
  DialogInput = Color3.fromRGB(60, 30, 15),
  DialogInputLine = Color3.fromRGB(200, 110, 70),
  Text = Color3.fromRGB(255, 230, 210),
  SubText = Color3.fromRGB(220, 160, 120),
  Hover = Color3.fromRGB(180, 90, 50),
  HoverChange = 0.06,
}

local Themes = {
  Names = { "Dark", "Darker", "Light", "Aqua", "Amethyst", "Rose", "Neon", "Ocean", "Sunset" },
  Dark = ThemeDark,
  Darker = ThemeDarker,
  Light = ThemeLight,
  Aqua = ThemeAqua,
  Amethyst = ThemeAmethyst,
  Rose = ThemeRose,
  Neon = ThemeNeon,
  Ocean = ThemeOcean,
  Sunset = ThemeSunset,
}

-- ============ Creator ============
local Creator = {
  Registry = {},
  Signals = {},
  TransparencyMotors = {},
  DefaultProperties = {
    ScreenGui = { ResetOnSpawn = false, ZIndexBehavior = Enum.ZIndexBehavior.Sibling },
    Frame = { BackgroundColor3 = Color3.new(1,1,1), BorderColor3 = Color3.new(0,0,0), BorderSizePixel = 0 },
    ScrollingFrame = { BackgroundColor3 = Color3.new(1,1,1), BorderColor3 = Color3.new(0,0,0), ScrollBarImageColor3 = Color3.new(0,0,0) },
    TextLabel = { BackgroundColor3 = Color3.new(1,1,1), BorderColor3 = Color3.new(0,0,0), Font = Enum.Font.SourceSans, Text = "", TextColor3 = Color3.new(0,0,0), BackgroundTransparency = 1, TextSize = 14 },
    TextButton = { BackgroundColor3 = Color3.new(1,1,1), BorderColor3 = Color3.new(0,0,0), AutoButtonColor = false, Font = Enum.Font.SourceSans, Text = "", TextColor3 = Color3.new(0,0,0), TextSize = 14 },
    TextBox = { BackgroundColor3 = Color3.new(1,1,1), BorderColor3 = Color3.new(0,0,0), ClearTextOnFocus = false, Font = Enum.Font.SourceSans, Text = "", TextColor3 = Color3.new(0,0,0), TextSize = 14 },
    ImageLabel = { BackgroundTransparency = 1, BackgroundColor3 = Color3.new(1,1,1), BorderColor3 = Color3.new(0,0,0), BorderSizePixel = 0 },
    ImageButton = { BackgroundColor3 = Color3.new(1,1,1), BorderColor3 = Color3.new(0,0,0), AutoButtonColor = false },
    CanvasGroup = { BackgroundColor3 = Color3.new(1,1,1), BorderColor3 = Color3.new(0,0,0), BorderSizePixel = 0 },
  },
}

local function ApplyCustomProps(obj, props)
  if props.ThemeTag then Creator.AddThemeObject(obj, props.ThemeTag) end
end

function Creator.AddSignal(sig, fn)
  table.insert(Creator.Signals, sig:Connect(fn))
end

function Creator.Disconnect()
  for i = #Creator.Signals, 1, -1 do
    table.remove(Creator.Signals, i):Disconnect()
  end
end

function Creator.GetThemeProperty(prop)
  local L = getLibrary()
  local theme = (L and Themes[L.Theme] and Themes[L.Theme][prop]) and Themes[L.Theme] or ThemeDark
  return theme[prop] or ThemeDark[prop]
end

function Creator.UpdateTheme()
  for inst, data in next, Creator.Registry do
    for prop, key in next, data.Properties do
      inst[prop] = Creator.GetThemeProperty(key)
    end
  end
  for _, motor in next, Creator.TransparencyMotors do
    motor:setGoal(Flipper.Instant.new(Creator.GetThemeProperty("ElementTransparency")))
  end
end

function Creator.AddThemeObject(obj, props)
  Creator.Registry[obj] = { Object = obj, Properties = props }
  Creator.UpdateTheme()
  return obj
end

function Creator.OverrideTag(obj, props)
  Creator.Registry[obj].Properties = props
  Creator.UpdateTheme()
end

function Creator.New(name, props, children)
  local obj = Instance.new(name)
  for k, v in next, Creator.DefaultProperties[name] or {} do obj[k] = v end
  for k, v in next, props or {} do if k ~= "ThemeTag" then obj[k] = v end end
  for _, c in next, children or {} do c.Parent = obj end
  ApplyCustomProps(obj, props)
  return obj
end

function Creator.SpringMotor(initial, inst, prop, ignoreDialog, resetOnTheme)
  ignoreDialog = ignoreDialog or false
  resetOnTheme = resetOnTheme or false
  local motor = Flipper.SingleMotor.new(initial)
  motor:onStep(function(v) inst[prop] = v end)
  if resetOnTheme then table.insert(Creator.TransparencyMotors, motor) end
  local function setVal(val, ignore)
    if not ignoreDialog and not ignore and prop == "BackgroundTransparency" and getLibrary() and getLibrary().DialogOpen then return end
    motor:setGoal(Flipper.Spring.new(val, { frequency = 8 }))
  end
  return motor, setVal
end

local function CreateRipple(parent)
  local absPos = parent.AbsolutePosition
  local absSize = parent.AbsoluteSize
  local mx, my = Mouse.X - absPos.X, Mouse.Y - absPos.Y
  local maxDist = math.max(
    math.sqrt(mx^2 + my^2),
    math.sqrt((absSize.X - mx)^2 + my^2),
    math.sqrt(mx^2 + (absSize.Y - my)^2),
    math.sqrt((absSize.X - mx)^2 + (absSize.Y - my)^2)
  ) * 2
  local ripple = Creator.New("Frame", {
    Position = UDim2.fromOffset(mx, my),
    AnchorPoint = Vector2.new(0.5, 0.5),
    Size = UDim2.fromOffset(0, 0),
    BackgroundColor3 = Color3.fromRGB(255, 255, 255),
    BackgroundTransparency = 0.75,
    Parent = parent,
    ZIndex = 99,
  }, {
    Creator.New("UICorner", { CornerRadius = UDim.new(1, 0) }),
  })
  local ti = TweenInfo.new(0.5, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
  local tween1 = TweenService:Create(ripple, ti, { Size = UDim2.fromOffset(maxDist, maxDist), BackgroundTransparency = 1 })
  tween1:Play()
  tween1.Completed:Connect(function() ripple:Destroy() end)
end
Creator.CreateRipple = CreateRipple

-- ============ Icons (820 Lucide icons) ============
local Icons = {
  assets = {
    ["lucide-accessibility"] = "rbxassetid://10709751939",
    ["lucide-activity"] = "rbxassetid://10709752035",
    ["lucide-air-vent"] = "rbxassetid://10709752131",
    ["lucide-airplay"] = "rbxassetid://10709752254",
    ["lucide-alarm-check"] = "rbxassetid://10709752405",
    ["lucide-alarm-clock"] = "rbxassetid://10709752630",
    ["lucide-alarm-clock-off"] = "rbxassetid://10709752508",
    ["lucide-alarm-minus"] = "rbxassetid://10709752732",
    ["lucide-alarm-plus"] = "rbxassetid://10709752825",
    ["lucide-album"] = "rbxassetid://10709752906",
    ["lucide-alert-circle"] = "rbxassetid://10709752996",
    ["lucide-alert-octagon"] = "rbxassetid://10709753064",
    ["lucide-alert-triangle"] = "rbxassetid://10709753149",
    ["lucide-align-center"] = "rbxassetid://10709753570",
    ["lucide-align-center-horizontal"] = "rbxassetid://10709753272",
    ["lucide-align-center-vertical"] = "rbxassetid://10709753421",
    ["lucide-align-end-horizontal"] = "rbxassetid://10709753692",
    ["lucide-align-end-vertical"] = "rbxassetid://10709753808",
    ["lucide-align-horizontal-distribute-center"] = "rbxassetid://10747779791",
    ["lucide-align-horizontal-distribute-end"] = "rbxassetid://10747784534",
    ["lucide-align-horizontal-distribute-start"] = "rbxassetid://10709754118",
    ["lucide-align-horizontal-justify-center"] = "rbxassetid://10709754204",
    ["lucide-align-horizontal-justify-end"] = "rbxassetid://10709754317",
    ["lucide-align-horizontal-justify-start"] = "rbxassetid://10709754436",
    ["lucide-align-horizontal-space-around"] = "rbxassetid://10709754590",
    ["lucide-align-horizontal-space-between"] = "rbxassetid://10709754749",
    ["lucide-align-justify"] = "rbxassetid://10709759610",
    ["lucide-align-left"] = "rbxassetid://10709759764",
    ["lucide-align-right"] = "rbxassetid://10709759895",
    ["lucide-align-start-horizontal"] = "rbxassetid://10709760051",
    ["lucide-align-start-vertical"] = "rbxassetid://10709760244",
    ["lucide-align-vertical-distribute-center"] = "rbxassetid://10709760351",
    ["lucide-align-vertical-distribute-end"] = "rbxassetid://10709760434",
    ["lucide-align-vertical-distribute-start"] = "rbxassetid://10709760612",
    ["lucide-align-vertical-justify-center"] = "rbxassetid://10709760814",
    ["lucide-align-vertical-justify-end"] = "rbxassetid://10709761003",
    ["lucide-align-vertical-justify-start"] = "rbxassetid://10709761176",
    ["lucide-align-vertical-space-around"] = "rbxassetid://10709761324",
    ["lucide-align-vertical-space-between"] = "rbxassetid://10709761434",
    ["lucide-anchor"] = "rbxassetid://10709761530",
    ["lucide-angry"] = "rbxassetid://10709761629",
    ["lucide-annoyed"] = "rbxassetid://10709761722",
    ["lucide-aperture"] = "rbxassetid://10709761813",
    ["lucide-apple"] = "rbxassetid://10709761889",
    ["lucide-archive"] = "rbxassetid://10709762233",
    ["lucide-archive-restore"] = "rbxassetid://10709762058",
    ["lucide-armchair"] = "rbxassetid://10709762327",
    ["lucide-arrow-big-down"] = "rbxassetid://10747796644",
    ["lucide-arrow-big-left"] = "rbxassetid://10709762574",
    ["lucide-arrow-big-right"] = "rbxassetid://10709762727",
    ["lucide-arrow-big-up"] = "rbxassetid://10709762879",
    ["lucide-arrow-down"] = "rbxassetid://10709767827",
    ["lucide-arrow-down-circle"] = "rbxassetid://10709763034",
    ["lucide-arrow-down-left"] = "rbxassetid://10709767656",
    ["lucide-arrow-down-right"] = "rbxassetid://10709767750",
    ["lucide-arrow-left"] = "rbxassetid://10709768114",
    ["lucide-arrow-left-circle"] = "rbxassetid://10709767936",
    ["lucide-arrow-left-right"] = "rbxassetid://10709768019",
    ["lucide-arrow-right"] = "rbxassetid://10709768347",
    ["lucide-arrow-right-circle"] = "rbxassetid://10709768226",
    ["lucide-arrow-up"] = "rbxassetid://10709768939",
    ["lucide-arrow-up-circle"] = "rbxassetid://10709768432",
    ["lucide-arrow-up-down"] = "rbxassetid://10709768538",
    ["lucide-arrow-up-left"] = "rbxassetid://10709768661",
    ["lucide-arrow-up-right"] = "rbxassetid://10709768787",
    ["lucide-asterisk"] = "rbxassetid://10709769095",
    ["lucide-at-sign"] = "rbxassetid://10709769286",
    ["lucide-award"] = "rbxassetid://10709769406",
    ["lucide-axe"] = "rbxassetid://10709769508",
    ["lucide-axis-3d"] = "rbxassetid://10709769598",
    ["lucide-baby"] = "rbxassetid://10709769732",
    ["lucide-backpack"] = "rbxassetid://10709769841",
    ["lucide-baggage-claim"] = "rbxassetid://10709769935",
    ["lucide-banana"] = "rbxassetid://10709770005",
    ["lucide-banknote"] = "rbxassetid://10709770178",
    ["lucide-bar-chart"] = "rbxassetid://10709773755",
    ["lucide-bar-chart-2"] = "rbxassetid://10709770317",
    ["lucide-bar-chart-3"] = "rbxassetid://10709770431",
    ["lucide-bar-chart-4"] = "rbxassetid://10709770560",
    ["lucide-bar-chart-horizontal"] = "rbxassetid://10709773669",
    ["lucide-barcode"] = "rbxassetid://10747360675",
    ["lucide-baseline"] = "rbxassetid://10709773863",
    ["lucide-bath"] = "rbxassetid://10709773963",
    ["lucide-battery"] = "rbxassetid://10709774640",
    ["lucide-battery-charging"] = "rbxassetid://10709774068",
    ["lucide-battery-full"] = "rbxassetid://10709774206",
    ["lucide-battery-low"] = "rbxassetid://10709774370",
    ["lucide-battery-medium"] = "rbxassetid://10709774513",
    ["lucide-beaker"] = "rbxassetid://10709774756",
    ["lucide-bed"] = "rbxassetid://10709775036",
    ["lucide-bed-double"] = "rbxassetid://10709774864",
    ["lucide-bed-single"] = "rbxassetid://10709774968",
    ["lucide-beer"] = "rbxassetid://10709775167",
    ["lucide-bell"] = "rbxassetid://10709775704",
    ["lucide-bell-minus"] = "rbxassetid://10709775241",
    ["lucide-bell-off"] = "rbxassetid://10709775320",
    ["lucide-bell-plus"] = "rbxassetid://10709775448",
    ["lucide-bell-ring"] = "rbxassetid://10709775560",
    ["lucide-bike"] = "rbxassetid://10709775894",
    ["lucide-binary"] = "rbxassetid://10709776050",
    ["lucide-bitcoin"] = "rbxassetid://10709776126",
    ["lucide-bluetooth"] = "rbxassetid://10709776655",
    ["lucide-bluetooth-connected"] = "rbxassetid://10709776240",
    ["lucide-bluetooth-off"] = "rbxassetid://10709776344",
    ["lucide-bluetooth-searching"] = "rbxassetid://10709776501",
    ["lucide-bold"] = "rbxassetid://10747813908",
    ["lucide-bomb"] = "rbxassetid://10709781460",
    ["lucide-bone"] = "rbxassetid://10709781605",
    ["lucide-book"] = "rbxassetid://10709781824",
    ["lucide-book-open"] = "rbxassetid://10709781717",
    ["lucide-bookmark"] = "rbxassetid://10709782154",
    ["lucide-bookmark-minus"] = "rbxassetid://10709781919",
    ["lucide-bookmark-plus"] = "rbxassetid://10709782044",
    ["lucide-bot"] = "rbxassetid://10709782230",
    ["lucide-box"] = "rbxassetid://10709782497",
    ["lucide-box-select"] = "rbxassetid://10709782342",
    ["lucide-boxes"] = "rbxassetid://10709782582",
    ["lucide-briefcase"] = "rbxassetid://10709782662",
    ["lucide-brush"] = "rbxassetid://10709782758",
    ["lucide-bug"] = "rbxassetid://10709782845",
    ["lucide-building"] = "rbxassetid://10709783051",
    ["lucide-building-2"] = "rbxassetid://10709782939",
    ["lucide-bus"] = "rbxassetid://10709783137",
    ["lucide-cake"] = "rbxassetid://10709783217",
    ["lucide-calculator"] = "rbxassetid://10709783311",
    ["lucide-calendar"] = "rbxassetid://10709789505",
    ["lucide-calendar-check"] = "rbxassetid://10709783474",
    ["lucide-calendar-check-2"] = "rbxassetid://10709783392",
    ["lucide-calendar-clock"] = "rbxassetid://10709783577",
    ["lucide-calendar-days"] = "rbxassetid://10709783673",
    ["lucide-calendar-heart"] = "rbxassetid://10709783835",
    ["lucide-calendar-minus"] = "rbxassetid://10709783959",
    ["lucide-calendar-off"] = "rbxassetid://10709788784",
    ["lucide-calendar-plus"] = "rbxassetid://10709788937",
    ["lucide-calendar-range"] = "rbxassetid://10709789053",
    ["lucide-calendar-search"] = "rbxassetid://10709789200",
    ["lucide-calendar-x"] = "rbxassetid://10709789407",
    ["lucide-calendar-x-2"] = "rbxassetid://10709789329",
    ["lucide-camera"] = "rbxassetid://10709789686",
    ["lucide-camera-off"] = "rbxassetid://10747822677",
    ["lucide-car"] = "rbxassetid://10709789810",
    ["lucide-carrot"] = "rbxassetid://10709789960",
    ["lucide-cast"] = "rbxassetid://10709790097",
    ["lucide-charge"] = "rbxassetid://10709790202",
    ["lucide-check"] = "rbxassetid://10709790644",
    ["lucide-check-circle"] = "rbxassetid://10709790387",
    ["lucide-check-circle-2"] = "rbxassetid://10709790298",
    ["lucide-check-square"] = "rbxassetid://10709790537",
    ["lucide-chef-hat"] = "rbxassetid://10709790757",
    ["lucide-cherry"] = "rbxassetid://10709790875",
    ["lucide-chevron-down"] = "rbxassetid://10709790948",
    ["lucide-chevron-first"] = "rbxassetid://10709791015",
    ["lucide-chevron-last"] = "rbxassetid://10709791130",
    ["lucide-chevron-left"] = "rbxassetid://10709791281",
    ["lucide-chevron-right"] = "rbxassetid://10709791437",
    ["lucide-chevron-up"] = "rbxassetid://10709791523",
    ["lucide-chevrons-down"] = "rbxassetid://10709796864",
    ["lucide-chevrons-down-up"] = "rbxassetid://10709791632",
    ["lucide-chevrons-left"] = "rbxassetid://10709797151",
    ["lucide-chevrons-left-right"] = "rbxassetid://10709797006",
    ["lucide-chevrons-right"] = "rbxassetid://10709797382",
    ["lucide-chevrons-right-left"] = "rbxassetid://10709797274",
    ["lucide-chevrons-up"] = "rbxassetid://10709797622",
    ["lucide-chevrons-up-down"] = "rbxassetid://10709797508",
    ["lucide-chrome"] = "rbxassetid://10709797725",
    ["lucide-circle"] = "rbxassetid://10709798174",
    ["lucide-circle-dot"] = "rbxassetid://10709797837",
    ["lucide-circle-ellipsis"] = "rbxassetid://10709797985",
    ["lucide-circle-slashed"] = "rbxassetid://10709798100",
    ["lucide-citrus"] = "rbxassetid://10709798276",
    ["lucide-clapperboard"] = "rbxassetid://10709798350",
    ["lucide-clipboard"] = "rbxassetid://10709799288",
    ["lucide-clipboard-check"] = "rbxassetid://10709798443",
    ["lucide-clipboard-copy"] = "rbxassetid://10709798574",
    ["lucide-clipboard-edit"] = "rbxassetid://10709798682",
    ["lucide-clipboard-list"] = "rbxassetid://10709798792",
    ["lucide-clipboard-signature"] = "rbxassetid://10709798890",
    ["lucide-clipboard-type"] = "rbxassetid://10709798999",
    ["lucide-clipboard-x"] = "rbxassetid://10709799124",
    ["lucide-clock"] = "rbxassetid://10709805144",
    ["lucide-clock-1"] = "rbxassetid://10709799535",
    ["lucide-clock-10"] = "rbxassetid://10709799718",
    ["lucide-clock-11"] = "rbxassetid://10709799818",
    ["lucide-clock-12"] = "rbxassetid://10709799962",
    ["lucide-clock-2"] = "rbxassetid://10709803876",
    ["lucide-clock-3"] = "rbxassetid://10709803989",
    ["lucide-clock-4"] = "rbxassetid://10709804164",
    ["lucide-clock-5"] = "rbxassetid://10709804291",
    ["lucide-clock-6"] = "rbxassetid://10709804435",
    ["lucide-clock-7"] = "rbxassetid://10709804599",
    ["lucide-clock-8"] = "rbxassetid://10709804784",
    ["lucide-clock-9"] = "rbxassetid://10709804996",
    ["lucide-cloud"] = "rbxassetid://10709806740",
    ["lucide-cloud-cog"] = "rbxassetid://10709805262",
    ["lucide-cloud-drizzle"] = "rbxassetid://10709805371",
    ["lucide-cloud-fog"] = "rbxassetid://10709805477",
    ["lucide-cloud-hail"] = "rbxassetid://10709805596",
    ["lucide-cloud-lightning"] = "rbxassetid://10709805727",
    ["lucide-cloud-moon"] = "rbxassetid://10709805942",
    ["lucide-cloud-moon-rain"] = "rbxassetid://10709805838",
    ["lucide-cloud-off"] = "rbxassetid://10709806060",
    ["lucide-cloud-rain"] = "rbxassetid://10709806277",
    ["lucide-cloud-rain-wind"] = "rbxassetid://10709806166",
    ["lucide-cloud-snow"] = "rbxassetid://10709806374",
    ["lucide-cloud-sun"] = "rbxassetid://10709806631",
    ["lucide-cloud-sun-rain"] = "rbxassetid://10709806475",
    ["lucide-cloudy"] = "rbxassetid://10709806859",
    ["lucide-clover"] = "rbxassetid://10709806995",
    ["lucide-code"] = "rbxassetid://10709810463",
    ["lucide-code-2"] = "rbxassetid://10709807111",
    ["lucide-codepen"] = "rbxassetid://10709810534",
    ["lucide-codesandbox"] = "rbxassetid://10709810676",
    ["lucide-coffee"] = "rbxassetid://10709810814",
    ["lucide-cog"] = "rbxassetid://10709810948",
    ["lucide-coins"] = "rbxassetid://10709811110",
    ["lucide-columns"] = "rbxassetid://10709811261",
    ["lucide-command"] = "rbxassetid://10709811365",
    ["lucide-compass"] = "rbxassetid://10709811445",
    ["lucide-component"] = "rbxassetid://10709811595",
    ["lucide-concierge-bell"] = "rbxassetid://10709811706",
    ["lucide-connection"] = "rbxassetid://10747361219",
    ["lucide-contact"] = "rbxassetid://10709811834",
    ["lucide-contrast"] = "rbxassetid://10709811939",
    ["lucide-cookie"] = "rbxassetid://10709812067",
    ["lucide-copy"] = "rbxassetid://10709812159",
    ["lucide-copyleft"] = "rbxassetid://10709812251",
    ["lucide-copyright"] = "rbxassetid://10709812311",
    ["lucide-corner-down-left"] = "rbxassetid://10709812396",
    ["lucide-corner-down-right"] = "rbxassetid://10709812485",
    ["lucide-corner-left-down"] = "rbxassetid://10709812632",
    ["lucide-corner-left-up"] = "rbxassetid://10709812784",
    ["lucide-corner-right-down"] = "rbxassetid://10709812939",
    ["lucide-corner-right-up"] = "rbxassetid://10709813094",
    ["lucide-corner-up-left"] = "rbxassetid://10709813185",
    ["lucide-corner-up-right"] = "rbxassetid://10709813281",
    ["lucide-cpu"] = "rbxassetid://10709813383",
    ["lucide-croissant"] = "rbxassetid://10709818125",
    ["lucide-crop"] = "rbxassetid://10709818245",
    ["lucide-cross"] = "rbxassetid://10709818399",
    ["lucide-crosshair"] = "rbxassetid://10709818534",
    ["lucide-crown"] = "rbxassetid://10709818626",
    ["lucide-cup-soda"] = "rbxassetid://10709818763",
    ["lucide-curly-braces"] = "rbxassetid://10709818847",
    ["lucide-currency"] = "rbxassetid://10709818931",
    ["lucide-database"] = "rbxassetid://10709818996",
    ["lucide-delete"] = "rbxassetid://10709819059",
    ["lucide-diamond"] = "rbxassetid://10709819149",
    ["lucide-dice-1"] = "rbxassetid://10709819266",
    ["lucide-dice-2"] = "rbxassetid://10709819361",
    ["lucide-dice-3"] = "rbxassetid://10709819508",
    ["lucide-dice-4"] = "rbxassetid://10709819670",
    ["lucide-dice-5"] = "rbxassetid://10709819801",
    ["lucide-dice-6"] = "rbxassetid://10709819896",
    ["lucide-dices"] = "rbxassetid://10723343321",
    ["lucide-diff"] = "rbxassetid://10723343416",
    ["lucide-disc"] = "rbxassetid://10723343537",
    ["lucide-divide"] = "rbxassetid://10723343805",
    ["lucide-divide-circle"] = "rbxassetid://10723343636",
    ["lucide-divide-square"] = "rbxassetid://10723343737",
    ["lucide-dollar-sign"] = "rbxassetid://10723343958",
    ["lucide-download"] = "rbxassetid://10723344270",
    ["lucide-download-cloud"] = "rbxassetid://10723344088",
    ["lucide-droplet"] = "rbxassetid://10723344432",
    ["lucide-droplets"] = "rbxassetid://10734883356",
    ["lucide-drumstick"] = "rbxassetid://10723344737",
    ["lucide-edit"] = "rbxassetid://10734883598",
    ["lucide-edit-2"] = "rbxassetid://10723344885",
    ["lucide-edit-3"] = "rbxassetid://10723345088",
    ["lucide-egg"] = "rbxassetid://10723345518",
    ["lucide-egg-fried"] = "rbxassetid://10723345347",
    ["lucide-electricity"] = "rbxassetid://10723345749",
    ["lucide-electricity-off"] = "rbxassetid://10723345643",
    ["lucide-equal"] = "rbxassetid://10723345990",
    ["lucide-equal-not"] = "rbxassetid://10723345866",
    ["lucide-eraser"] = "rbxassetid://10723346158",
    ["lucide-euro"] = "rbxassetid://10723346372",
    ["lucide-expand"] = "rbxassetid://10723346553",
    ["lucide-external-link"] = "rbxassetid://10723346684",
    ["lucide-eye"] = "rbxassetid://10723346959",
    ["lucide-eye-off"] = "rbxassetid://10723346871",
    ["lucide-factory"] = "rbxassetid://10723347051",
    ["lucide-fan"] = "rbxassetid://10723354359",
    ["lucide-fast-forward"] = "rbxassetid://10723354521",
    ["lucide-feather"] = "rbxassetid://10723354671",
    ["lucide-figma"] = "rbxassetid://10723354801",
    ["lucide-file"] = "rbxassetid://10723374641",
    ["lucide-file-archive"] = "rbxassetid://10723354921",
    ["lucide-file-audio"] = "rbxassetid://10723355148",
    ["lucide-file-audio-2"] = "rbxassetid://10723355026",
    ["lucide-file-axis-3d"] = "rbxassetid://10723355272",
    ["lucide-file-badge"] = "rbxassetid://10723355622",
    ["lucide-file-badge-2"] = "rbxassetid://10723355451",
    ["lucide-file-bar-chart"] = "rbxassetid://10723355887",
    ["lucide-file-bar-chart-2"] = "rbxassetid://10723355746",
    ["lucide-file-box"] = "rbxassetid://10723355989",
    ["lucide-file-check"] = "rbxassetid://10723356210",
    ["lucide-file-check-2"] = "rbxassetid://10723356100",
    ["lucide-file-clock"] = "rbxassetid://10723356329",
    ["lucide-file-code"] = "rbxassetid://10723356507",
    ["lucide-file-cog"] = "rbxassetid://10723356830",
    ["lucide-file-cog-2"] = "rbxassetid://10723356676",
    ["lucide-file-diff"] = "rbxassetid://10723357039",
    ["lucide-file-digit"] = "rbxassetid://10723357151",
    ["lucide-file-down"] = "rbxassetid://10723357322",
    ["lucide-file-edit"] = "rbxassetid://10723357495",
    ["lucide-file-heart"] = "rbxassetid://10723357637",
    ["lucide-file-image"] = "rbxassetid://10723357790",
    ["lucide-file-input"] = "rbxassetid://10723357933",
    ["lucide-file-json"] = "rbxassetid://10723364435",
    ["lucide-file-json-2"] = "rbxassetid://10723364361",
    ["lucide-file-key"] = "rbxassetid://10723364605",
    ["lucide-file-key-2"] = "rbxassetid://10723364515",
    ["lucide-file-line-chart"] = "rbxassetid://10723364725",
    ["lucide-file-lock"] = "rbxassetid://10723364957",
    ["lucide-file-lock-2"] = "rbxassetid://10723364861",
    ["lucide-file-minus"] = "rbxassetid://10723365254",
    ["lucide-file-minus-2"] = "rbxassetid://10723365086",
    ["lucide-file-output"] = "rbxassetid://10723365457",
    ["lucide-file-pie-chart"] = "rbxassetid://10723365598",
    ["lucide-file-plus"] = "rbxassetid://10723365877",
    ["lucide-file-plus-2"] = "rbxassetid://10723365766",
    ["lucide-file-question"] = "rbxassetid://10723365987",
    ["lucide-file-scan"] = "rbxassetid://10723366167",
    ["lucide-file-search"] = "rbxassetid://10723366550",
    ["lucide-file-search-2"] = "rbxassetid://10723366340",
    ["lucide-file-signature"] = "rbxassetid://10723366741",
    ["lucide-file-spreadsheet"] = "rbxassetid://10723366962",
    ["lucide-file-symlink"] = "rbxassetid://10723367098",
    ["lucide-file-terminal"] = "rbxassetid://10723367244",
    ["lucide-file-text"] = "rbxassetid://10723367380",
    ["lucide-file-type"] = "rbxassetid://10723367606",
    ["lucide-file-type-2"] = "rbxassetid://10723367509",
    ["lucide-file-up"] = "rbxassetid://10723367734",
    ["lucide-file-video"] = "rbxassetid://10723373884",
    ["lucide-file-video-2"] = "rbxassetid://10723367834",
    ["lucide-file-volume"] = "rbxassetid://10723374172",
    ["lucide-file-volume-2"] = "rbxassetid://10723374030",
    ["lucide-file-warning"] = "rbxassetid://10723374276",
    ["lucide-file-x"] = "rbxassetid://10723374544",
    ["lucide-file-x-2"] = "rbxassetid://10723374378",
    ["lucide-files"] = "rbxassetid://10723374759",
    ["lucide-film"] = "rbxassetid://10723374981",
    ["lucide-filter"] = "rbxassetid://10723375128",
    ["lucide-fingerprint"] = "rbxassetid://10723375250",
    ["lucide-flag"] = "rbxassetid://10723375890",
    ["lucide-flag-off"] = "rbxassetid://10723375443",
    ["lucide-flag-triangle-left"] = "rbxassetid://10723375608",
    ["lucide-flag-triangle-right"] = "rbxassetid://10723375727",
    ["lucide-flame"] = "rbxassetid://10723376114",
    ["lucide-flashlight"] = "rbxassetid://10723376471",
    ["lucide-flashlight-off"] = "rbxassetid://10723376365",
    ["lucide-flask-conical"] = "rbxassetid://10734883986",
    ["lucide-flask-round"] = "rbxassetid://10723376614",
    ["lucide-flip-horizontal"] = "rbxassetid://10723376884",
    ["lucide-flip-horizontal-2"] = "rbxassetid://10723376745",
    ["lucide-flip-vertical"] = "rbxassetid://10723377138",
    ["lucide-flip-vertical-2"] = "rbxassetid://10723377026",
    ["lucide-flower"] = "rbxassetid://10747830374",
    ["lucide-flower-2"] = "rbxassetid://10723377305",
    ["lucide-focus"] = "rbxassetid://10723377537",
    ["lucide-folder"] = "rbxassetid://10723387563",
    ["lucide-folder-archive"] = "rbxassetid://10723384478",
    ["lucide-folder-check"] = "rbxassetid://10723384605",
    ["lucide-folder-clock"] = "rbxassetid://10723384731",
    ["lucide-folder-closed"] = "rbxassetid://10723384893",
    ["lucide-folder-cog"] = "rbxassetid://10723385213",
    ["lucide-folder-cog-2"] = "rbxassetid://10723385036",
    ["lucide-folder-down"] = "rbxassetid://10723385338",
    ["lucide-folder-edit"] = "rbxassetid://10723385445",
    ["lucide-folder-heart"] = "rbxassetid://10723385545",
    ["lucide-folder-input"] = "rbxassetid://10723385721",
    ["lucide-folder-key"] = "rbxassetid://10723385848",
    ["lucide-folder-lock"] = "rbxassetid://10723386005",
    ["lucide-folder-minus"] = "rbxassetid://10723386127",
    ["lucide-folder-open"] = "rbxassetid://10723386277",
    ["lucide-folder-output"] = "rbxassetid://10723386386",
    ["lucide-folder-plus"] = "rbxassetid://10723386531",
    ["lucide-folder-search"] = "rbxassetid://10723386787",
    ["lucide-folder-search-2"] = "rbxassetid://10723386674",
    ["lucide-folder-symlink"] = "rbxassetid://10723386930",
    ["lucide-folder-tree"] = "rbxassetid://10723387085",
    ["lucide-folder-up"] = "rbxassetid://10723387265",
    ["lucide-folder-x"] = "rbxassetid://10723387448",
    ["lucide-folders"] = "rbxassetid://10723387721",
    ["lucide-form-input"] = "rbxassetid://10723387841",
    ["lucide-forward"] = "rbxassetid://10723388016",
    ["lucide-frame"] = "rbxassetid://10723394389",
    ["lucide-framer"] = "rbxassetid://10723394565",
    ["lucide-frown"] = "rbxassetid://10723394681",
    ["lucide-fuel"] = "rbxassetid://10723394846",
    ["lucide-function-square"] = "rbxassetid://10723395041",
    ["lucide-gamepad"] = "rbxassetid://10723395457",
    ["lucide-gamepad-2"] = "rbxassetid://10723395215",
    ["lucide-gauge"] = "rbxassetid://10723395708",
    ["lucide-gavel"] = "rbxassetid://10723395896",
    ["lucide-gem"] = "rbxassetid://10723396000",
    ["lucide-ghost"] = "rbxassetid://10723396107",
    ["lucide-gift"] = "rbxassetid://10723396402",
    ["lucide-gift-card"] = "rbxassetid://10723396225",
    ["lucide-git-branch"] = "rbxassetid://10723396676",
    ["lucide-git-branch-plus"] = "rbxassetid://10723396542",
    ["lucide-git-commit"] = "rbxassetid://10723396812",
    ["lucide-git-compare"] = "rbxassetid://10723396954",
    ["lucide-git-fork"] = "rbxassetid://10723397049",
    ["lucide-git-merge"] = "rbxassetid://10723397165",
    ["lucide-git-pull-request"] = "rbxassetid://10723397431",
    ["lucide-git-pull-request-closed"] = "rbxassetid://10723397268",
    ["lucide-git-pull-request-draft"] = "rbxassetid://10734884302",
    ["lucide-glass"] = "rbxassetid://10723397788",
    ["lucide-glass-2"] = "rbxassetid://10723397529",
    ["lucide-glass-water"] = "rbxassetid://10723397678",
    ["lucide-glasses"] = "rbxassetid://10723397895",
    ["lucide-globe"] = "rbxassetid://10723404337",
    ["lucide-globe-2"] = "rbxassetid://10723398002",
    ["lucide-grab"] = "rbxassetid://10723404472",
    ["lucide-graduation-cap"] = "rbxassetid://10723404691",
    ["lucide-grape"] = "rbxassetid://10723404822",
    ["lucide-grid"] = "rbxassetid://10723404936",
    ["lucide-grip-horizontal"] = "rbxassetid://10723405089",
    ["lucide-grip-vertical"] = "rbxassetid://10723405236",
    ["lucide-hammer"] = "rbxassetid://10723405360",
    ["lucide-hand"] = "rbxassetid://10723405649",
    ["lucide-hand-metal"] = "rbxassetid://10723405508",
    ["lucide-hard-drive"] = "rbxassetid://10723405749",
    ["lucide-hard-hat"] = "rbxassetid://10723405859",
    ["lucide-hash"] = "rbxassetid://10723405975",
    ["lucide-haze"] = "rbxassetid://10723406078",
    ["lucide-headphones"] = "rbxassetid://10723406165",
    ["lucide-heart"] = "rbxassetid://10723406885",
    ["lucide-heart-crack"] = "rbxassetid://10723406299",
    ["lucide-heart-handshake"] = "rbxassetid://10723406480",
    ["lucide-heart-off"] = "rbxassetid://10723406662",
    ["lucide-heart-pulse"] = "rbxassetid://10723406795",
    ["lucide-help-circle"] = "rbxassetid://10723406988",
    ["lucide-hexagon"] = "rbxassetid://10723407092",
    ["lucide-highlighter"] = "rbxassetid://10723407192",
    ["lucide-history"] = "rbxassetid://10723407335",
    ["lucide-home"] = "rbxassetid://10723407389",
    ["lucide-hourglass"] = "rbxassetid://10723407498",
    ["lucide-ice-cream"] = "rbxassetid://10723414308",
    ["lucide-image"] = "rbxassetid://10723415040",
    ["lucide-image-minus"] = "rbxassetid://10723414487",
    ["lucide-image-off"] = "rbxassetid://10723414677",
    ["lucide-image-plus"] = "rbxassetid://10723414827",
    ["lucide-import"] = "rbxassetid://10723415205",
    ["lucide-inbox"] = "rbxassetid://10723415335",
    ["lucide-indent"] = "rbxassetid://10723415494",
    ["lucide-indian-rupee"] = "rbxassetid://10723415642",
    ["lucide-infinity"] = "rbxassetid://10723415766",
    ["lucide-info"] = "rbxassetid://10723415903",
    ["lucide-inspect"] = "rbxassetid://10723416057",
    ["lucide-italic"] = "rbxassetid://10723416195",
    ["lucide-japanese-yen"] = "rbxassetid://10723416363",
    ["lucide-joystick"] = "rbxassetid://10723416527",
    ["lucide-key"] = "rbxassetid://10723416652",
    ["lucide-keyboard"] = "rbxassetid://10723416765",
    ["lucide-lamp"] = "rbxassetid://10723417513",
    ["lucide-lamp-ceiling"] = "rbxassetid://10723416922",
    ["lucide-lamp-desk"] = "rbxassetid://10723417016",
    ["lucide-lamp-floor"] = "rbxassetid://10723417131",
    ["lucide-lamp-wall-down"] = "rbxassetid://10723417240",
    ["lucide-lamp-wall-up"] = "rbxassetid://10723417356",
    ["lucide-landmark"] = "rbxassetid://10723417608",
    ["lucide-languages"] = "rbxassetid://10723417703",
    ["lucide-laptop"] = "rbxassetid://10723423881",
    ["lucide-laptop-2"] = "rbxassetid://10723417797",
    ["lucide-lasso"] = "rbxassetid://10723424235",
    ["lucide-lasso-select"] = "rbxassetid://10723424058",
    ["lucide-laugh"] = "rbxassetid://10723424372",
    ["lucide-layers"] = "rbxassetid://10723424505",
    ["lucide-layout"] = "rbxassetid://10723425376",
    ["lucide-layout-dashboard"] = "rbxassetid://10723424646",
    ["lucide-layout-grid"] = "rbxassetid://10723424838",
    ["lucide-layout-list"] = "rbxassetid://10723424963",
    ["lucide-layout-template"] = "rbxassetid://10723425187",
    ["lucide-leaf"] = "rbxassetid://10723425539",
    ["lucide-library"] = "rbxassetid://10723425615",
    ["lucide-life-buoy"] = "rbxassetid://10723425685",
    ["lucide-lightbulb"] = "rbxassetid://10723425852",
    ["lucide-lightbulb-off"] = "rbxassetid://10723425762",
    ["lucide-line-chart"] = "rbxassetid://10723426393",
    ["lucide-link"] = "rbxassetid://10723426722",
    ["lucide-link-2"] = "rbxassetid://10723426595",
    ["lucide-link-2-off"] = "rbxassetid://10723426513",
    ["lucide-list"] = "rbxassetid://10723433811",
    ["lucide-list-checks"] = "rbxassetid://10734884548",
    ["lucide-list-end"] = "rbxassetid://10723426886",
    ["lucide-list-minus"] = "rbxassetid://10723426986",
    ["lucide-list-music"] = "rbxassetid://10723427081",
    ["lucide-list-ordered"] = "rbxassetid://10723427199",
    ["lucide-list-plus"] = "rbxassetid://10723427334",
    ["lucide-list-start"] = "rbxassetid://10723427494",
    ["lucide-list-video"] = "rbxassetid://10723427619",
    ["lucide-list-x"] = "rbxassetid://10723433655",
    ["lucide-loader"] = "rbxassetid://10723434070",
    ["lucide-loader-2"] = "rbxassetid://10723433935",
    ["lucide-locate"] = "rbxassetid://10723434557",
    ["lucide-locate-fixed"] = "rbxassetid://10723434236",
    ["lucide-locate-off"] = "rbxassetid://10723434379",
    ["lucide-lock"] = "rbxassetid://10723434711",
    ["lucide-log-in"] = "rbxassetid://10723434830",
    ["lucide-log-out"] = "rbxassetid://10723434906",
    ["lucide-luggage"] = "rbxassetid://10723434993",
    ["lucide-magnet"] = "rbxassetid://10723435069",
    ["lucide-mail"] = "rbxassetid://10734885430",
    ["lucide-mail-check"] = "rbxassetid://10723435182",
    ["lucide-mail-minus"] = "rbxassetid://10723435261",
    ["lucide-mail-open"] = "rbxassetid://10723435342",
    ["lucide-mail-plus"] = "rbxassetid://10723435443",
    ["lucide-mail-question"] = "rbxassetid://10723435515",
    ["lucide-mail-search"] = "rbxassetid://10734884739",
    ["lucide-mail-warning"] = "rbxassetid://10734885015",
    ["lucide-mail-x"] = "rbxassetid://10734885247",
    ["lucide-mails"] = "rbxassetid://10734885614",
    ["lucide-map"] = "rbxassetid://10734886202",
    ["lucide-map-pin"] = "rbxassetid://10734886004",
    ["lucide-map-pin-off"] = "rbxassetid://10734885803",
    ["lucide-maximize"] = "rbxassetid://10734886735",
    ["lucide-maximize-2"] = "rbxassetid://10734886496",
    ["lucide-medal"] = "rbxassetid://10734887072",
    ["lucide-megaphone"] = "rbxassetid://10734887454",
    ["lucide-megaphone-off"] = "rbxassetid://10734887311",
    ["lucide-meh"] = "rbxassetid://10734887603",
    ["lucide-menu"] = "rbxassetid://10734887784",
    ["lucide-message-circle"] = "rbxassetid://10734888000",
    ["lucide-message-square"] = "rbxassetid://10734888228",
    ["lucide-mic"] = "rbxassetid://10734888864",
    ["lucide-mic-2"] = "rbxassetid://10734888430",
    ["lucide-mic-off"] = "rbxassetid://10734888646",
    ["lucide-microscope"] = "rbxassetid://10734889106",
    ["lucide-microwave"] = "rbxassetid://10734895076",
    ["lucide-milestone"] = "rbxassetid://10734895310",
    ["lucide-minimize"] = "rbxassetid://10734895698",
    ["lucide-minimize-2"] = "rbxassetid://10734895530",
    ["lucide-minus"] = "rbxassetid://10734896206",
    ["lucide-minus-circle"] = "rbxassetid://10734895856",
    ["lucide-minus-square"] = "rbxassetid://10734896029",
    ["lucide-monitor"] = "rbxassetid://10734896881",
    ["lucide-monitor-off"] = "rbxassetid://10734896360",
    ["lucide-monitor-speaker"] = "rbxassetid://10734896512",
    ["lucide-moon"] = "rbxassetid://10734897102",
    ["lucide-more-horizontal"] = "rbxassetid://10734897250",
    ["lucide-more-vertical"] = "rbxassetid://10734897387",
    ["lucide-mountain"] = "rbxassetid://10734897956",
    ["lucide-mountain-snow"] = "rbxassetid://10734897665",
    ["lucide-mouse"] = "rbxassetid://10734898592",
    ["lucide-mouse-pointer"] = "rbxassetid://10734898476",
    ["lucide-mouse-pointer-2"] = "rbxassetid://10734898194",
    ["lucide-mouse-pointer-click"] = "rbxassetid://10734898355",
    ["lucide-move"] = "rbxassetid://10734900011",
    ["lucide-move-3d"] = "rbxassetid://10734898756",
    ["lucide-move-diagonal"] = "rbxassetid://10734899164",
    ["lucide-move-diagonal-2"] = "rbxassetid://10734898934",
    ["lucide-move-horizontal"] = "rbxassetid://10734899414",
    ["lucide-move-vertical"] = "rbxassetid://10734899821",
    ["lucide-music"] = "rbxassetid://10734905958",
    ["lucide-music-2"] = "rbxassetid://10734900215",
    ["lucide-music-3"] = "rbxassetid://10734905665",
    ["lucide-music-4"] = "rbxassetid://10734905823",
    ["lucide-navigation"] = "rbxassetid://10734906744",
    ["lucide-navigation-2"] = "rbxassetid://10734906332",
    ["lucide-navigation-2-off"] = "rbxassetid://10734906144",
    ["lucide-navigation-off"] = "rbxassetid://10734906580",
    ["lucide-network"] = "rbxassetid://10734906975",
    ["lucide-newspaper"] = "rbxassetid://10734907168",
    ["lucide-octagon"] = "rbxassetid://10734907361",
    ["lucide-option"] = "rbxassetid://10734907649",
    ["lucide-outdent"] = "rbxassetid://10734907933",
    ["lucide-package"] = "rbxassetid://10734909540",
    ["lucide-package-2"] = "rbxassetid://10734908151",
    ["lucide-package-check"] = "rbxassetid://10734908384",
    ["lucide-package-minus"] = "rbxassetid://10734908626",
    ["lucide-package-open"] = "rbxassetid://10734908793",
    ["lucide-package-plus"] = "rbxassetid://10734909016",
    ["lucide-package-search"] = "rbxassetid://10734909196",
    ["lucide-package-x"] = "rbxassetid://10734909375",
    ["lucide-paint-bucket"] = "rbxassetid://10734909847",
    ["lucide-paintbrush"] = "rbxassetid://10734910187",
    ["lucide-paintbrush-2"] = "rbxassetid://10734910030",
    ["lucide-palette"] = "rbxassetid://10734910430",
    ["lucide-palmtree"] = "rbxassetid://10734910680",
    ["lucide-paperclip"] = "rbxassetid://10734910927",
    ["lucide-party-popper"] = "rbxassetid://10734918735",
    ["lucide-pause"] = "rbxassetid://10734919336",
    ["lucide-pause-circle"] = "rbxassetid://10735024209",
    ["lucide-pause-octagon"] = "rbxassetid://10734919143",
    ["lucide-pen-tool"] = "rbxassetid://10734919503",
    ["lucide-pencil"] = "rbxassetid://10734919691",
    ["lucide-percent"] = "rbxassetid://10734919919",
    ["lucide-person-standing"] = "rbxassetid://10734920149",
    ["lucide-phone"] = "rbxassetid://10734921524",
    ["lucide-phone-call"] = "rbxassetid://10734920305",
    ["lucide-phone-forwarded"] = "rbxassetid://10734920508",
    ["lucide-phone-incoming"] = "rbxassetid://10734920694",
    ["lucide-phone-missed"] = "rbxassetid://10734920845",
    ["lucide-phone-off"] = "rbxassetid://10734921077",
    ["lucide-phone-outgoing"] = "rbxassetid://10734921288",
    ["lucide-pie-chart"] = "rbxassetid://10734921727",
    ["lucide-piggy-bank"] = "rbxassetid://10734921935",
    ["lucide-pin"] = "rbxassetid://10734922324",
    ["lucide-pin-off"] = "rbxassetid://10734922180",
    ["lucide-pipette"] = "rbxassetid://10734922497",
    ["lucide-pizza"] = "rbxassetid://10734922774",
    ["lucide-plane"] = "rbxassetid://10734922971",
    ["lucide-play"] = "rbxassetid://10734923549",
    ["lucide-play-circle"] = "rbxassetid://10734923214",
    ["lucide-plus"] = "rbxassetid://10734924532",
    ["lucide-plus-circle"] = "rbxassetid://10734923868",
    ["lucide-plus-square"] = "rbxassetid://10734924219",
    ["lucide-podcast"] = "rbxassetid://10734929553",
    ["lucide-pointer"] = "rbxassetid://10734929723",
    ["lucide-pound-sterling"] = "rbxassetid://10734929981",
    ["lucide-power"] = "rbxassetid://10734930466",
    ["lucide-power-off"] = "rbxassetid://10734930257",
    ["lucide-printer"] = "rbxassetid://10734930632",
    ["lucide-puzzle"] = "rbxassetid://10734930886",
    ["lucide-quote"] = "rbxassetid://10734931234",
    ["lucide-radio"] = "rbxassetid://10734931596",
    ["lucide-radio-receiver"] = "rbxassetid://10734931402",
    ["lucide-rectangle-horizontal"] = "rbxassetid://10734931777",
    ["lucide-rectangle-vertical"] = "rbxassetid://10734932081",
    ["lucide-recycle"] = "rbxassetid://10734932295",
    ["lucide-redo"] = "rbxassetid://10734932822",
    ["lucide-redo-2"] = "rbxassetid://10734932586",
    ["lucide-refresh-ccw"] = "rbxassetid://10734933056",
    ["lucide-refresh-cw"] = "rbxassetid://10734933222",
    ["lucide-refrigerator"] = "rbxassetid://10734933465",
    ["lucide-regex"] = "rbxassetid://10734933655",
    ["lucide-repeat"] = "rbxassetid://10734933966",
    ["lucide-repeat-1"] = "rbxassetid://10734933826",
    ["lucide-reply"] = "rbxassetid://10734934252",
    ["lucide-reply-all"] = "rbxassetid://10734934132",
    ["lucide-rewind"] = "rbxassetid://10734934347",
    ["lucide-rocket"] = "rbxassetid://10734934585",
    ["lucide-rocking-chair"] = "rbxassetid://10734939942",
    ["lucide-rotate-3d"] = "rbxassetid://10734940107",
    ["lucide-rotate-ccw"] = "rbxassetid://10734940376",
    ["lucide-rotate-cw"] = "rbxassetid://10734940654",
    ["lucide-rss"] = "rbxassetid://10734940825",
    ["lucide-ruler"] = "rbxassetid://10734941018",
    ["lucide-russian-ruble"] = "rbxassetid://10734941199",
    ["lucide-sailboat"] = "rbxassetid://10734941354",
    ["lucide-save"] = "rbxassetid://10734941499",
    ["lucide-scale"] = "rbxassetid://10734941912",
    ["lucide-scale-3d"] = "rbxassetid://10734941739",
    ["lucide-scaling"] = "rbxassetid://10734942072",
    ["lucide-scan"] = "rbxassetid://10734942565",
    ["lucide-scan-face"] = "rbxassetid://10734942198",
    ["lucide-scan-line"] = "rbxassetid://10734942351",
    ["lucide-scissors"] = "rbxassetid://10734942778",
    ["lucide-screen-share"] = "rbxassetid://10734943193",
    ["lucide-screen-share-off"] = "rbxassetid://10734942967",
    ["lucide-scroll"] = "rbxassetid://10734943448",
    ["lucide-search"] = "rbxassetid://10734943674",
    ["lucide-send"] = "rbxassetid://10734943902",
    ["lucide-separator-horizontal"] = "rbxassetid://10734944115",
    ["lucide-separator-vertical"] = "rbxassetid://10734944326",
    ["lucide-server"] = "rbxassetid://10734949856",
    ["lucide-server-cog"] = "rbxassetid://10734944444",
    ["lucide-server-crash"] = "rbxassetid://10734944554",
    ["lucide-server-off"] = "rbxassetid://10734944668",
    ["lucide-settings"] = "rbxassetid://10734950309",
    ["lucide-settings-2"] = "rbxassetid://10734950020",
    ["lucide-share"] = "rbxassetid://10734950813",
    ["lucide-share-2"] = "rbxassetid://10734950553",
    ["lucide-sheet"] = "rbxassetid://10734951038",
    ["lucide-shield"] = "rbxassetid://10734951847",
    ["lucide-shield-alert"] = "rbxassetid://10734951173",
    ["lucide-shield-check"] = "rbxassetid://10734951367",
    ["lucide-shield-close"] = "rbxassetid://10734951535",
    ["lucide-shield-off"] = "rbxassetid://10734951684",
    ["lucide-shirt"] = "rbxassetid://10734952036",
    ["lucide-shopping-bag"] = "rbxassetid://10734952273",
    ["lucide-shopping-cart"] = "rbxassetid://10734952479",
    ["lucide-shovel"] = "rbxassetid://10734952773",
    ["lucide-shower-head"] = "rbxassetid://10734952942",
    ["lucide-shrink"] = "rbxassetid://10734953073",
    ["lucide-shrub"] = "rbxassetid://10734953241",
    ["lucide-shuffle"] = "rbxassetid://10734953451",
    ["lucide-sidebar"] = "rbxassetid://10734954301",
    ["lucide-sidebar-close"] = "rbxassetid://10734953715",
    ["lucide-sidebar-open"] = "rbxassetid://10734954000",
    ["lucide-sigma"] = "rbxassetid://10734954538",
    ["lucide-signal"] = "rbxassetid://10734961133",
    ["lucide-signal-high"] = "rbxassetid://10734954807",
    ["lucide-signal-low"] = "rbxassetid://10734955080",
    ["lucide-signal-medium"] = "rbxassetid://10734955336",
    ["lucide-signal-zero"] = "rbxassetid://10734960878",
    ["lucide-siren"] = "rbxassetid://10734961284",
    ["lucide-skip-back"] = "rbxassetid://10734961526",
    ["lucide-skip-forward"] = "rbxassetid://10734961809",
    ["lucide-skull"] = "rbxassetid://10734962068",
    ["lucide-slack"] = "rbxassetid://10734962339",
    ["lucide-slash"] = "rbxassetid://10734962600",
    ["lucide-slice"] = "rbxassetid://10734963024",
    ["lucide-sliders"] = "rbxassetid://10734963400",
    ["lucide-sliders-horizontal"] = "rbxassetid://10734963191",
    ["lucide-smartphone"] = "rbxassetid://10734963940",
    ["lucide-smartphone-charging"] = "rbxassetid://10734963671",
    ["lucide-smile"] = "rbxassetid://10734964441",
    ["lucide-smile-plus"] = "rbxassetid://10734964188",
    ["lucide-snowflake"] = "rbxassetid://10734964600",
    ["lucide-sofa"] = "rbxassetid://10734964852",
    ["lucide-sort-asc"] = "rbxassetid://10734965115",
    ["lucide-sort-desc"] = "rbxassetid://10734965287",
    ["lucide-speaker"] = "rbxassetid://10734965419",
    ["lucide-sprout"] = "rbxassetid://10734965572",
    ["lucide-square"] = "rbxassetid://10734965702",
    ["lucide-star"] = "rbxassetid://10734966248",
    ["lucide-star-half"] = "rbxassetid://10734965897",
    ["lucide-star-off"] = "rbxassetid://10734966097",
    ["lucide-stethoscope"] = "rbxassetid://10734966384",
    ["lucide-sticker"] = "rbxassetid://10734972234",
    ["lucide-sticky-note"] = "rbxassetid://10734972463",
    ["lucide-stop-circle"] = "rbxassetid://10734972621",
    ["lucide-stretch-horizontal"] = "rbxassetid://10734972862",
    ["lucide-stretch-vertical"] = "rbxassetid://10734973130",
    ["lucide-strikethrough"] = "rbxassetid://10734973290",
    ["lucide-subscript"] = "rbxassetid://10734973457",
    ["lucide-sun"] = "rbxassetid://10734974297",
    ["lucide-sun-dim"] = "rbxassetid://10734973645",
    ["lucide-sun-medium"] = "rbxassetid://10734973778",
    ["lucide-sun-moon"] = "rbxassetid://10734973999",
    ["lucide-sun-snow"] = "rbxassetid://10734974130",
    ["lucide-sunrise"] = "rbxassetid://10734974522",
    ["lucide-sunset"] = "rbxassetid://10734974689",
    ["lucide-superscript"] = "rbxassetid://10734974850",
    ["lucide-swiss-franc"] = "rbxassetid://10734975024",
    ["lucide-switch-camera"] = "rbxassetid://10734975214",
    ["lucide-sword"] = "rbxassetid://10734975486",
    ["lucide-swords"] = "rbxassetid://10734975692",
    ["lucide-syringe"] = "rbxassetid://10734975932",
    ["lucide-table"] = "rbxassetid://10734976230",
    ["lucide-table-2"] = "rbxassetid://10734976097",
    ["lucide-tablet"] = "rbxassetid://10734976394",
    ["lucide-tag"] = "rbxassetid://10734976528",
    ["lucide-tags"] = "rbxassetid://10734976739",
    ["lucide-target"] = "rbxassetid://10734977012",
    ["lucide-tent"] = "rbxassetid://10734981750",
    ["lucide-terminal"] = "rbxassetid://10734982144",
    ["lucide-terminal-square"] = "rbxassetid://10734981995",
    ["lucide-text-cursor"] = "rbxassetid://10734982395",
    ["lucide-text-cursor-input"] = "rbxassetid://10734982297",
    ["lucide-thermometer"] = "rbxassetid://10734983134",
    ["lucide-thermometer-snowflake"] = "rbxassetid://10734982571",
    ["lucide-thermometer-sun"] = "rbxassetid://10734982771",
    ["lucide-thumbs-down"] = "rbxassetid://10734983359",
    ["lucide-thumbs-up"] = "rbxassetid://10734983629",
    ["lucide-ticket"] = "rbxassetid://10734983868",
    ["lucide-timer"] = "rbxassetid://10734984606",
    ["lucide-timer-off"] = "rbxassetid://10734984138",
    ["lucide-timer-reset"] = "rbxassetid://10734984355",
    ["lucide-toggle-left"] = "rbxassetid://10734984834",
    ["lucide-toggle-right"] = "rbxassetid://10734985040",
    ["lucide-tornado"] = "rbxassetid://10734985247",
    ["lucide-toy-brick"] = "rbxassetid://10747361919",
    ["lucide-train"] = "rbxassetid://10747362105",
    ["lucide-trash"] = "rbxassetid://10747362393",
    ["lucide-trash-2"] = "rbxassetid://10747362241",
    ["lucide-tree-deciduous"] = "rbxassetid://10747362534",
    ["lucide-tree-pine"] = "rbxassetid://10747362748",
    ["lucide-trees"] = "rbxassetid://10747363016",
    ["lucide-trending-down"] = "rbxassetid://10747363205",
    ["lucide-trending-up"] = "rbxassetid://10747363465",
    ["lucide-triangle"] = "rbxassetid://10747363621",
    ["lucide-trophy"] = "rbxassetid://10747363809",
    ["lucide-truck"] = "rbxassetid://10747364031",
    ["lucide-tv"] = "rbxassetid://10747364593",
    ["lucide-tv-2"] = "rbxassetid://10747364302",
    ["lucide-type"] = "rbxassetid://10747364761",
    ["lucide-umbrella"] = "rbxassetid://10747364971",
    ["lucide-underline"] = "rbxassetid://10747365191",
    ["lucide-undo"] = "rbxassetid://10747365484",
    ["lucide-undo-2"] = "rbxassetid://10747365359",
    ["lucide-unlink"] = "rbxassetid://10747365771",
    ["lucide-unlink-2"] = "rbxassetid://10747397871",
    ["lucide-unlock"] = "rbxassetid://10747366027",
    ["lucide-upload"] = "rbxassetid://10747366434",
    ["lucide-upload-cloud"] = "rbxassetid://10747366266",
    ["lucide-usb"] = "rbxassetid://10747366606",
    ["lucide-user"] = "rbxassetid://10747373176",
    ["lucide-user-check"] = "rbxassetid://10747371901",
    ["lucide-user-cog"] = "rbxassetid://10747372167",
    ["lucide-user-minus"] = "rbxassetid://10747372346",
    ["lucide-user-plus"] = "rbxassetid://10747372702",
    ["lucide-user-x"] = "rbxassetid://10747372992",
    ["lucide-users"] = "rbxassetid://10747373426",
    ["lucide-utensils"] = "rbxassetid://10747373821",
    ["lucide-utensils-crossed"] = "rbxassetid://10747373629",
    ["lucide-venetian-mask"] = "rbxassetid://10747374003",
    ["lucide-verified"] = "rbxassetid://10747374131",
    ["lucide-vibrate"] = "rbxassetid://10747374489",
    ["lucide-vibrate-off"] = "rbxassetid://10747374269",
    ["lucide-video"] = "rbxassetid://10747374938",
    ["lucide-video-off"] = "rbxassetid://10747374721",
    ["lucide-view"] = "rbxassetid://10747375132",
    ["lucide-voicemail"] = "rbxassetid://10747375281",
    ["lucide-volume"] = "rbxassetid://10747376008",
    ["lucide-volume-1"] = "rbxassetid://10747375450",
    ["lucide-volume-2"] = "rbxassetid://10747375679",
    ["lucide-volume-x"] = "rbxassetid://10747375880",
    ["lucide-wallet"] = "rbxassetid://10747376205",
    ["lucide-wand"] = "rbxassetid://10747376565",
    ["lucide-wand-2"] = "rbxassetid://10747376349",
    ["lucide-watch"] = "rbxassetid://10747376722",
    ["lucide-waves"] = "rbxassetid://10747376931",
    ["lucide-webcam"] = "rbxassetid://10747381992",
    ["lucide-wifi"] = "rbxassetid://10747382504",
    ["lucide-wifi-off"] = "rbxassetid://10747382268",
    ["lucide-wind"] = "rbxassetid://10747382750",
    ["lucide-wrap-text"] = "rbxassetid://10747383065",
    ["lucide-wrench"] = "rbxassetid://10747383470",
    ["lucide-x"] = "rbxassetid://10747384394",
    ["lucide-x-circle"] = "rbxassetid://10747383819",
    ["lucide-x-octagon"] = "rbxassetid://10747384037",
    ["lucide-x-square"] = "rbxassetid://10747384217",
    ["lucide-zoom-in"] = "rbxassetid://10747384552",
    ["lucide-zoom-out"] = "rbxassetid://10747384679",
  },
}

-- ============ Acrylic ============
local function mapVal(v, inMin, inMax, outMin, outMax)
  return (v - inMin) * (outMax - outMin) / (inMax - inMin) + outMin
end
local function viewportPointToWorld(loc, dist)
  local ray = Camera:ScreenPointToRay(loc.X, loc.Y)
  return ray.Origin + ray.Direction * dist
end
local function getOffset()
  return mapVal(Camera.ViewportSize.Y, 0, 2560, 8, 56)
end
local function createAcrylicPart()
  return Creator.New("Part", {
    Name = "Body", Color = Color3.new(0,0,0), Material = Enum.Material.Glass, Size = Vector3.new(1,1,0),
    Anchored = true, CanCollide = false, Locked = true, CastShadow = false, Transparency = 0.98,
  }, { Creator.New("SpecialMesh", { MeshType = Enum.MeshType.Brick, Offset = Vector3.new(0,0,-0.000001) }) })
end
local function createAcrylicBlur(distance)
  distance = distance or 0.001
  local positions = { topLeft = Vector2.new(), topRight = Vector2.new(), bottomRight = Vector2.new() }
  local model = createAcrylicPart()
  model.Parent = Camera or workspace
  local cleanups = {}
  local function updatePos(sz, pos) positions.topLeft = pos positions.topRight = pos + Vector2.new(sz.X,0) positions.bottomRight = pos + sz end
  local function render()
    local cam = Camera and Camera.CFrame or CFrame.new()
    local tl = viewportPointToWorld(positions.topLeft, distance)
    local tr = viewportPointToWorld(positions.topRight, distance)
    local br = viewportPointToWorld(positions.bottomRight, distance)
    model.CFrame = CFrame.fromMatrix((tl + br) / 2, cam.XVector, cam.YVector, cam.ZVector)
    model.Mesh.Scale = Vector3.new((tr - tl).Magnitude, (tr - br).Magnitude, 0)
  end
  local function onChange(rbx)
    local off = getOffset()
    updatePos(rbx.AbsoluteSize - Vector2.new(off, off), rbx.AbsolutePosition + Vector2.new(off/2, off/2))
    task.spawn(render)
  end
  if Camera then
    table.insert(cleanups, Camera:GetPropertyChangedSignal("CFrame"):Connect(render))
    table.insert(cleanups, Camera:GetPropertyChangedSignal("ViewportSize"):Connect(render))
    table.insert(cleanups, Camera:GetPropertyChangedSignal("FieldOfView"):Connect(render))
    task.spawn(render)
  end
  model.Destroying:Connect(function() for _, c in pairs(cleanups) do pcall(function() c:Disconnect() end) end end)
  return onChange, model
end
local Acrylic = {}
function Acrylic.init()
  local baseEffect = Instance.new("DepthOfFieldEffect")
  baseEffect.FarIntensity = 0 baseEffect.InFocusRadius = 0.1 baseEffect.NearIntensity = 1
  local depthOfFieldDefaults = {}
  function Acrylic.Enable()
    for _, e in pairs(depthOfFieldDefaults) do e.Enabled = false end
    baseEffect.Parent = Lighting
  end
  function Acrylic.Disable()
    for _, e in pairs(depthOfFieldDefaults) do e.Enabled = e.enabled end
    baseEffect.Parent = nil
  end
  local function register(obj) if obj:IsA("DepthOfFieldEffect") then depthOfFieldDefaults[obj] = { enabled = obj.Enabled } end end
  for _, c in pairs(Lighting:GetChildren()) do register(c) end
  if Camera then for _, c in pairs(Camera:GetChildren()) do register(c) end end
  Acrylic.Enable()
end
function Acrylic.AcrylicPaint()
  local New = Creator.New
  local frame = New("Frame", {
    Size = UDim2.fromScale(1,1), BackgroundTransparency = 0.9, BackgroundColor3 = Color3.fromRGB(255,255,255), BorderSizePixel = 0,
  }, {
    New("ImageLabel", { Image = "rbxassetid://8992230677", ScaleType = "Slice", SliceCenter = Rect.new(Vector2.new(99,99), Vector2.new(99,99)), AnchorPoint = Vector2.new(0.5,0.5), Size = UDim2.new(1,120,1,116), Position = UDim2.new(0.5,0,0.5,0), BackgroundTransparency = 1, ImageColor3 = Color3.fromRGB(0,0,0), ImageTransparency = 0.7 }),
    New("UICorner", { CornerRadius = UDim.new(0,8) }),
    New("Frame", { BackgroundTransparency = 0.45, Size = UDim2.fromScale(1,1), Name = "Background", ThemeTag = { BackgroundColor3 = "AcrylicMain" } }, { New("UICorner", { CornerRadius = UDim.new(0,8) }) }),
    New("Frame", { BackgroundColor3 = Color3.fromRGB(255,255,255), BackgroundTransparency = 0.4, Size = UDim2.fromScale(1,1) }, { New("UICorner", { CornerRadius = UDim.new(0,8) }), New("UIGradient", { Rotation = 90, ThemeTag = { Color = "AcrylicGradient" } }) }),
    New("ImageLabel", { Image = "rbxassetid://9968344105", ImageTransparency = 0.98, ScaleType = Enum.ScaleType.Tile, TileSize = UDim2.new(0,128,0,128), Size = UDim2.fromScale(1,1), BackgroundTransparency = 1 }, { New("UICorner", { CornerRadius = UDim.new(0,8) }) }),
    New("ImageLabel", { Image = "rbxassetid://9968344227", ImageTransparency = 0.9, ScaleType = Enum.ScaleType.Tile, TileSize = UDim2.new(0,128,0,128), Size = UDim2.fromScale(1,1), BackgroundTransparency = 1, ThemeTag = { ImageTransparency = "AcrylicNoise" } }, { New("UICorner", { CornerRadius = UDim.new(0,8) }) }),
    New("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1,1), ZIndex = 2 }, { New("UICorner", { CornerRadius = UDim.new(0,8) }), New("UIStroke", { Transparency = 0.5, Thickness = 1, ThemeTag = { Color = "AcrylicBorder" } }) }),
  })
  local paint = { Frame = frame, Model = frame }
  if getLibrary() and getLibrary().UseAcrylic then
    local onChange, model = createAcrylicBlur()
    local comp = New("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1,1) })
    comp.Parent = frame
    Creator.AddSignal(comp:GetPropertyChangedSignal("AbsolutePosition"), function() onChange(comp) end)
    Creator.AddSignal(comp:GetPropertyChangedSignal("AbsoluteSize"), function() onChange(comp) end)
    paint.Model = model
    paint.AddParent = function(parent) Creator.AddSignal(parent:GetPropertyChangedSignal("Visible"), function(vis) paint.SetVisibility(vis) end) end
    paint.SetVisibility = function(vis) model.Transparency = vis and 0.98 or 1 end
  end
  return paint
end

-- ============ Assets ============
local Assets = {
  Close = "rbxassetid://9886659671",
  Min = "rbxassetid://9886659276",
  Max = "rbxassetid://9886659406",
  Restore = "rbxassetid://9886659001",
}

-- ============ Component: Element ============
local function NewElement(Title, Desc, Parent, Hover)
  local New = Creator.New
  local el = {}
  el.TitleLabel = New("TextLabel", {
    FontFace = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Medium, Enum.FontStyle.Normal),
    Text = Title, TextColor3 = Color3.fromRGB(240,240,240), TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left,
    Size = UDim2.new(1,0,0,14), BackgroundTransparency = 1, ThemeTag = { TextColor3 = "Text" },
  })
  el.DescLabel = New("TextLabel", {
    FontFace = Font.new("rbxasset://fonts/families/GothamSSm.json"), Text = Desc, TextColor3 = Color3.fromRGB(200,200,200),
    TextSize = 12, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, BackgroundTransparency = 1,
    AutomaticSize = Enum.AutomaticSize.Y, Size = UDim2.new(1,0,0,14), ThemeTag = { TextColor3 = "SubText" },
  })
  el.LabelHolder = New("Frame", {
    AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, Position = UDim2.fromOffset(10,0), Size = UDim2.new(1,-28,0,0),
  }, {
    New("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, VerticalAlignment = Enum.VerticalAlignment.Center }),
    New("UIPadding", { PaddingBottom = UDim.new(0,13), PaddingTop = UDim.new(0,13) }),
    el.TitleLabel, el.DescLabel,
  })
  el.Border = New("UIStroke", { Transparency = 0.5, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Color = Color3.fromRGB(0,0,0), ThemeTag = { Color = "ElementBorder" } })
  el.Frame = New("TextButton", {
    Size = UDim2.new(1,0,0,0), BackgroundTransparency = 0.89, BackgroundColor3 = Color3.fromRGB(130,130,130), Parent = Parent,
    AutomaticSize = Enum.AutomaticSize.Y, Text = "", LayoutOrder = 7, ThemeTag = { BackgroundColor3 = "Element", BackgroundTransparency = "ElementTransparency" },
  }, { New("UICorner", { CornerRadius = UDim.new(0,4) }), el.Border, el.LabelHolder })
  function el:SetTitle(s) el.TitleLabel.Text = s end
  function el:SetDesc(s)
    if s == nil then s = "" end
    el.DescLabel.Visible = s ~= ""
    el.DescLabel.Text = s
  end
  function el:Destroy() el.Frame:Destroy() end
  el:SetTitle(Title)
  el:SetDesc(Desc)
  if Hover then
    local motor, setT = Creator.SpringMotor(Creator.GetThemeProperty("ElementTransparency"), el.Frame, "BackgroundTransparency", false, true)
    Creator.AddSignal(el.Frame.MouseEnter, function() setT(Creator.GetThemeProperty("ElementTransparency") - Creator.GetThemeProperty("HoverChange")) end)
    Creator.AddSignal(el.Frame.MouseLeave, function() setT(Creator.GetThemeProperty("ElementTransparency")) end)
    Creator.AddSignal(el.Frame.MouseButton1Down, function() setT(Creator.GetThemeProperty("ElementTransparency") + Creator.GetThemeProperty("HoverChange")) end)
    Creator.AddSignal(el.Frame.MouseButton1Up, function() setT(Creator.GetThemeProperty("ElementTransparency") - Creator.GetThemeProperty("HoverChange")) end)
  end
  return el
end

-- ============ Component: Button (dialog) ============
local function NewDialogButton(Theme, Parent, DialogCheck)
  local New = Creator.New
  DialogCheck = DialogCheck or false
  local btn = {}
  btn.Title = New("TextLabel", {
    FontFace = Font.new("rbxasset://fonts/families/GothamSSm.json"), TextColor3 = Color3.fromRGB(200,200,200), TextSize = 14,
    TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Center, TextYAlignment = Enum.TextYAlignment.Center,
    BackgroundTransparency = 1, AutomaticSize = Enum.AutomaticSize.Y, Size = UDim2.fromScale(1,1), ThemeTag = { TextColor3 = "Text" },
  })
  btn.HoverFrame = New("Frame", { Size = UDim2.fromScale(1,1), BackgroundTransparency = 1, ThemeTag = { BackgroundColor3 = "Hover" } }, { New("UICorner", { CornerRadius = UDim.new(0,4) }) })
  btn.Frame = New("TextButton", {
    Size = UDim2.new(0,0,0,32), Parent = Parent, ThemeTag = { BackgroundColor3 = "DialogButton" },
  }, {
    New("UICorner", { CornerRadius = UDim.new(0,4) }),
    New("UIStroke", { ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Transparency = 0.65, ThemeTag = { Color = "DialogButtonBorder" } }),
    btn.HoverFrame, btn.Title,
  })
  local _, setT = Creator.SpringMotor(1, btn.HoverFrame, "BackgroundTransparency", DialogCheck)
  Creator.AddSignal(btn.Frame.MouseEnter, function() setT(0.97) end)
  Creator.AddSignal(btn.Frame.MouseLeave, function() setT(1) end)
  Creator.AddSignal(btn.Frame.MouseButton1Down, function() setT(1) end)
  Creator.AddSignal(btn.Frame.MouseButton1Up, function() setT(0.97) end)
  return btn
end

-- ============ Component: Textbox ============
local TextService = game:GetService("TextService")
local function NewTextbox(Parent, Acrylic)
  Acrylic = Acrylic or false
  local New = Creator.New
  local tb = {}
  tb.Input = New("TextBox", {
    FontFace = Font.new("rbxasset://fonts/families/GothamSSm.json"), TextColor3 = Color3.fromRGB(200,200,200), TextSize = 14,
    TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Center, BackgroundTransparency = 1,
    AutomaticSize = Enum.AutomaticSize.Y, Size = UDim2.fromScale(1,1), Position = UDim2.fromOffset(10,0),
    ThemeTag = { TextColor3 = "Text", PlaceholderColor3 = "SubText" },
  })
  tb.Container = New("Frame", { BackgroundTransparency = 1, ClipsDescendants = true, Position = UDim2.new(0,6,0,0), Size = UDim2.new(1,-12,1,0) }, { tb.Input })
  tb.Indicator = New("Frame", {
    Size = UDim2.new(1,-4,0,1), Position = UDim2.new(0,2,1,0), AnchorPoint = Vector2.new(0,1), BackgroundTransparency = Acrylic and 0.5 or 0,
    ThemeTag = { BackgroundColor3 = Acrylic and "InputIndicator" or "DialogInputLine" },
  })
  tb.Frame = New("Frame", {
    Size = UDim2.new(0,0,0,30), BackgroundTransparency = Acrylic and 0.9 or 0, Parent = Parent,
    ThemeTag = { BackgroundColor3 = Acrylic and "Input" or "DialogInput" },
  }, {
    New("UICorner", { CornerRadius = UDim.new(0,4) }),
    New("UIStroke", { ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Transparency = Acrylic and 0.5 or 0.65, ThemeTag = { Color = Acrylic and "InElementBorder" or "DialogButtonBorder" } }),
    tb.Indicator, tb.Container,
  })
  local function Update()
    local pad, reveal = 2, tb.Container.AbsoluteSize.X
    if not tb.Input:IsFocused() or tb.Input.TextBounds.X <= reveal - 2*pad then
      tb.Input.Position = UDim2.new(0, pad, 0, 0)
    else
      local cur = tb.Input.CursorPosition
      if cur ~= -1 then
        local sub = string.sub(tb.Input.Text, 1, cur - 1)
        local w = TextService:GetTextSize(sub, tb.Input.TextSize, tb.Input.Font, Vector2.new(math.huge, math.huge)).X
        local x = tb.Input.Position.X.Offset + w
        if x < pad then tb.Input.Position = UDim2.fromOffset(pad - w, 0)
        elseif x > reveal - pad - 1 then tb.Input.Position = UDim2.fromOffset(reveal - w - pad - 1, 0) end
      end
    end
  end
  task.spawn(Update)
  Creator.AddSignal(tb.Input:GetPropertyChangedSignal("Text"), Update)
  Creator.AddSignal(tb.Input:GetPropertyChangedSignal("CursorPosition"), Update)
  Creator.AddSignal(tb.Input.Focused, function()
    Update()
    tb.Indicator.Size = UDim2.new(1,-2,0,2); tb.Indicator.Position = UDim2.new(0,1,1,0); tb.Indicator.BackgroundTransparency = 0
    Creator.OverrideTag(tb.Frame, { BackgroundColor3 = Acrylic and "InputFocused" or "DialogHolder" })
    Creator.OverrideTag(tb.Indicator, { BackgroundColor3 = "Accent" })
  end)
  Creator.AddSignal(tb.Input.FocusLost, function()
    Update()
    tb.Indicator.Size = UDim2.new(1,-4,0,1); tb.Indicator.Position = UDim2.new(0,2,1,0); tb.Indicator.BackgroundTransparency = 0.5
    Creator.OverrideTag(tb.Frame, { BackgroundColor3 = Acrylic and "Input" or "DialogInput" })
    Creator.OverrideTag(tb.Indicator, { BackgroundColor3 = Acrylic and "InputIndicator" or "DialogInputLine" })
  end)
  return tb
end

-- ============ Component: Section ============
local function NewSection(Title, Parent)
  local New = Creator.New
  local sec = {}
  sec.Layout = New("UIListLayout", { Padding = UDim.new(0,5) })
  sec.Container = New("Frame", { Size = UDim2.new(1,0,0,26), Position = UDim2.fromOffset(0,24), BackgroundTransparency = 1 }, { sec.Layout })
  sec.Root = New("Frame", {
    BackgroundTransparency = 1, Size = UDim2.new(1,0,0,26), LayoutOrder = 7, Parent = Parent,
  }, {
    New("TextLabel", {
      RichText = true, Text = Title, TextTransparency = 0,
      FontFace = Font.new("rbxassetid://12187365364", Enum.FontWeight.SemiBold, Enum.FontStyle.Normal),
      TextSize = 18, TextXAlignment = "Left", TextYAlignment = "Center", Size = UDim2.new(1,-16,0,18), Position = UDim2.fromOffset(0,2),
      ThemeTag = { TextColor3 = "Text" },
    }),
    sec.Container,
  })
  Creator.AddSignal(sec.Layout:GetPropertyChangedSignal("AbsoluteContentSize"), function()
    sec.Container.Size = UDim2.new(1,0,0,sec.Layout.AbsoluteContentSize.Y)
    sec.Root.Size = UDim2.new(1,0,0,sec.Layout.AbsoluteContentSize.Y + 25)
  end)
  return sec
end

-- ============ Notification ============
local Notification = {}
function Notification:Init(GUI)
  local New = Creator.New
  self.Holder = New("Frame", {
    Position = UDim2.new(1,-30,1,-30), Size = UDim2.new(0,310,1,-30), AnchorPoint = Vector2.new(1,1), BackgroundTransparency = 1, Parent = GUI,
  }, {
    New("UIListLayout", { HorizontalAlignment = Enum.HorizontalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder, VerticalAlignment = Enum.VerticalAlignment.Bottom, Padding = UDim.new(0,20) }),
  })
end

function Notification:New(cfg)
  cfg.Title = cfg.Title or "Title"
  cfg.Content = cfg.Content or "Content"
  cfg.SubContent = cfg.SubContent or ""
  cfg.Duration = cfg.Duration or nil
  cfg.Buttons = cfg.Buttons or {}
  local New = Creator.New
  local notif = { Closed = false }
  notif.AcrylicPaint = Acrylic.AcrylicPaint()
  notif.Title = New("TextLabel", {
    Position = UDim2.new(0,14,0,17), Text = cfg.Title, RichText = true, TextColor3 = Color3.fromRGB(255,255,255), TextTransparency = 0,
    FontFace = Font.new("rbxasset://fonts/families/GothamSSm.json"), TextSize = 13, TextXAlignment = "Left", TextYAlignment = "Center",
    Size = UDim2.new(1,-12,0,12), TextWrapped = true, BackgroundTransparency = 1, ThemeTag = { TextColor3 = "Text" },
  })
  notif.ContentLabel = New("TextLabel", {
    FontFace = Font.new("rbxasset://fonts/families/GothamSSm.json"), Text = cfg.Content, TextColor3 = Color3.fromRGB(240,240,240), TextSize = 14,
    TextXAlignment = Enum.TextXAlignment.Left, AutomaticSize = Enum.AutomaticSize.Y, Size = UDim2.new(1,0,0,14), BackgroundTransparency = 1, TextWrapped = true, ThemeTag = { TextColor3 = "Text" },
  })
  notif.SubContentLabel = New("TextLabel", {
    FontFace = Font.new("rbxasset://fonts/families/GothamSSm.json"), Text = cfg.SubContent, TextColor3 = Color3.fromRGB(240,240,240), TextSize = 14,
    TextXAlignment = Enum.TextXAlignment.Left, AutomaticSize = Enum.AutomaticSize.Y, Size = UDim2.new(1,0,0,14), BackgroundTransparency = 1, TextWrapped = true, ThemeTag = { TextColor3 = "SubText" },
  })
  notif.LabelHolder = New("Frame", {
    AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, Position = UDim2.fromOffset(14,40), Size = UDim2.new(1,-28,0,0),
  }, {
    New("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0,3) }),
    notif.ContentLabel, notif.SubContentLabel,
  })
  notif.CloseButton = New("TextButton", {
    Text = "", Position = UDim2.new(1,-14,0,13), Size = UDim2.fromOffset(20,20), AnchorPoint = Vector2.new(1,0), BackgroundTransparency = 1,
  }, {
    New("ImageLabel", { Image = Assets.Close, Size = UDim2.fromOffset(16,16), Position = UDim2.fromScale(0.5,0.5), AnchorPoint = Vector2.new(0.5,0.5), BackgroundTransparency = 1, ThemeTag = { ImageColor3 = "Text" } }),
  })
  notif.Root = New("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1,0,1,0), Position = UDim2.fromScale(1,0) }, {
    notif.AcrylicPaint.Frame, notif.Title, notif.CloseButton, notif.LabelHolder,
  })
  if cfg.Content == "" then notif.ContentLabel.Visible = false end
  if cfg.SubContent == "" then notif.SubContentLabel.Visible = false end
  notif.Holder = New("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1,0,0,200), Parent = self.Holder }, { notif.Root })
  local rootMotor = Flipper.GroupMotor.new({ Scale = 1, Offset = 60 })
  rootMotor:onStep(function(v) notif.Root.Position = UDim2.new(v.Scale, v.Offset, 0, 0) end)
  Creator.AddSignal(notif.CloseButton.MouseButton1Click, function() notif:Close() end)
  function notif:Open()
    local h = notif.LabelHolder.AbsoluteSize.Y
    notif.Holder.Size = UDim2.new(1,0,0,58 + h)
    rootMotor:setGoal({ Scale = Flipper.Spring.new(0, { frequency = 5 }), Offset = Flipper.Spring.new(0, { frequency = 5 }) })
  end
  function notif:Close()
    if notif.Closed then return end
    notif.Closed = true
    task.spawn(function()
      rootMotor:setGoal({ Scale = Flipper.Spring.new(1, { frequency = 5 }), Offset = Flipper.Spring.new(60, { frequency = 5 }) })
      task.wait(0.4)
      if getLibrary() and getLibrary().UseAcrylic then notif.AcrylicPaint.Model:Destroy() end
      notif.Holder:Destroy()
    end)
  end
  notif:Open()
  if cfg.Duration then task.delay(cfg.Duration, function() notif:Close() end) end
  return notif
end

-- ============ Dialog ============
local DialogModule = { Window = nil }
function DialogModule:Init(Window)
  self.Window = Window
  return self
end
function DialogModule:Create()
  local New = Creator.New
  local d = { Buttons = 0 }
  d.TintFrame = New("TextButton", {
    Text = "", Size = UDim2.fromScale(1,1), BackgroundColor3 = Color3.fromRGB(0,0,0), BackgroundTransparency = 1, Parent = self.Window.Root,
  }, { New("UICorner", { CornerRadius = UDim.new(0,8) }) })
  local _, TintTransparency = Creator.SpringMotor(1, d.TintFrame, "BackgroundTransparency", true)
  d.ButtonHolder = New("Frame", {
    Size = UDim2.new(1,-40,1,-40), AnchorPoint = Vector2.new(0.5,0.5), Position = UDim2.fromScale(0.5,0.5), BackgroundTransparency = 1,
  }, { New("UIListLayout", { Padding = UDim.new(0,10), FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder }) })
  d.ButtonHolderFrame = New("Frame", {
    Size = UDim2.new(1,0,0,70), Position = UDim2.new(0,0,1,-70), ThemeTag = { BackgroundColor3 = "DialogHolder" },
  }, { New("Frame", { Size = UDim2.new(1,0,0,1), ThemeTag = { BackgroundColor3 = "DialogHolderLine" } }), d.ButtonHolder })
  d.Title = New("TextLabel", {
    FontFace = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.SemiBold, Enum.FontStyle.Normal),
    Text = "Dialog", TextColor3 = Color3.fromRGB(240,240,240), TextSize = 22, TextXAlignment = Enum.TextXAlignment.Left,
    Size = UDim2.new(1,0,0,22), Position = UDim2.fromOffset(20,25), BackgroundTransparency = 1, ThemeTag = { TextColor3 = "Text" },
  })
  d.Scale = New("UIScale", { Scale = 1 })
  local _, ScaleSet = Creator.SpringMotor(1.1, d.Scale, "Scale")
  d.Root = New("CanvasGroup", {
    Size = UDim2.fromOffset(300,165), AnchorPoint = Vector2.new(0.5,0.5), Position = UDim2.fromScale(0.5,0.5), GroupTransparency = 1, Parent = d.TintFrame,
    ThemeTag = { BackgroundColor3 = "Dialog" },
  }, {
    New("UICorner", { CornerRadius = UDim.new(0,8) }),
    New("UIStroke", { Transparency = 0.5, ThemeTag = { Color = "DialogBorder" } }),
    d.Scale, d.Title, d.ButtonHolderFrame,
  })
  local _, RootTransparency = Creator.SpringMotor(1, d.Root, "GroupTransparency")
  function d:Open()
    getLibrary().DialogOpen = true
    d.Scale.Scale = 1.1
    TintTransparency(0.75)
    RootTransparency(0)
    ScaleSet(1)
  end
  function d:Close()
    getLibrary().DialogOpen = false
    TintTransparency(1)
    RootTransparency(1)
    ScaleSet(1.1)
    d.Root.UIStroke:Destroy()
    task.wait(0.15)
    d.TintFrame:Destroy()
  end
  function d:Button(Title, Callback)
    d.Buttons = d.Buttons + 1
    Title = Title or "Button"
    Callback = Callback or function() end
    local Btn = NewDialogButton("", d.ButtonHolder, true)
    Btn.Title.Text = Title
    for _, c in next, d.ButtonHolder:GetChildren() do
      if c:IsA("TextButton") then c.Size = UDim2.new(1/d.Buttons, -((d.Buttons-1)*10)/d.Buttons, 0, 32) end
    end
    Creator.AddSignal(Btn.Frame.MouseButton1Click, function()
      getLibrary():SafeCallback(Callback)
      pcall(function() d:Close() end)
    end)
    return Btn
  end
  return d
end

-- ============ TitleBar ============
local function NewTitleBar(cfg)
  local New = Creator.New
  local Lib = getLibrary()
  local function BarButton(Icon, Pos, Parent, Callback)
    local btn = { Callback = Callback or function() end }
    btn.Frame = New("TextButton", {
      Size = UDim2.new(0,34,1,-8), AnchorPoint = Vector2.new(1,0), BackgroundTransparency = 1, Parent = Parent, Position = Pos, Text = "",
      ThemeTag = { BackgroundColor3 = "Text" },
    }, {
      New("UICorner", { CornerRadius = UDim.new(0,7) }),
      New("ImageLabel", { Image = Icon, Size = UDim2.fromOffset(16,16), Position = UDim2.fromScale(0.5,0.5), AnchorPoint = Vector2.new(0.5,0.5), BackgroundTransparency = 1, Name = "Icon", ThemeTag = { ImageColor3 = "Text" } }),
    })
    local _, setT = Creator.SpringMotor(1, btn.Frame, "BackgroundTransparency")
    Creator.AddSignal(btn.Frame.MouseEnter, function() setT(0.94) end)
    Creator.AddSignal(btn.Frame.MouseLeave, function() setT(1, true) end)
    Creator.AddSignal(btn.Frame.MouseButton1Down, function() setT(0.96) end)
    Creator.AddSignal(btn.Frame.MouseButton1Up, function() setT(0.94) end)
    Creator.AddSignal(btn.Frame.MouseButton1Click, btn.Callback)
    return btn
  end
  local bar = {}
  bar.Frame = New("Frame", { Size = UDim2.new(1,0,0,42), BackgroundTransparency = 1, Parent = cfg.Parent }, {
    New("Frame", { Size = UDim2.new(1,-16,1,0), Position = UDim2.new(0,16,0,0), BackgroundTransparency = 1 }, {
      New("UIListLayout", { Padding = UDim.new(0,5), FillDirection = Enum.FillDirection.Horizontal, SortOrder = Enum.SortOrder.LayoutOrder }),
      New("TextLabel", { RichText = true, Text = cfg.Title, FontFace = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Regular, Enum.FontStyle.Normal), TextSize = 12, TextXAlignment = "Left", TextYAlignment = "Center", Size = UDim2.fromScale(0,1), AutomaticSize = Enum.AutomaticSize.X, BackgroundTransparency = 1, ThemeTag = { TextColor3 = "Text" } }),
      New("TextLabel", { RichText = true, Text = cfg.SubTitle, TextTransparency = 0.4, FontFace = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Regular, Enum.FontStyle.Normal), TextSize = 12, TextXAlignment = "Left", TextYAlignment = "Center", Size = UDim2.fromScale(0,1), AutomaticSize = Enum.AutomaticSize.X, BackgroundTransparency = 1, ThemeTag = { TextColor3 = "Text" } }),
    }),
    New("Frame", { BackgroundTransparency = 0.5, Size = UDim2.new(1,0,0,1), Position = UDim2.new(0,0,1,0), ThemeTag = { BackgroundColor3 = "TitleBarLine" } }),
  })
  bar.CloseButton = BarButton(Assets.Close, UDim2.new(1,-4,0,4), bar.Frame, function()
    Lib.Window:Dialog({ Title = "Close", Content = "Are you sure you want to unload the interface?", Buttons = { { Title = "Yes", Callback = function() Lib:Destroy() end }, { Title = "No" } } })
  end)
  bar.MaxButton = BarButton(Assets.Max, UDim2.new(1,-40,0,4), bar.Frame, function() cfg.Window:Maximize(not cfg.Window.Maximized) end)
  bar.MinButton = BarButton(Assets.Min, UDim2.new(1,-80,0,4), bar.Frame, function() Lib.Window:Minimize() end)
  return bar
end

-- ============ Tab module ============
local TabModule = { Window = nil, Tabs = {}, Containers = {}, SelectedTab = 0, TabCount = 0 }
function TabModule:Init(Window) self.Window = Window return self end
function TabModule:GetCurrentTabPos()
  return self.Tabs[self.SelectedTab].Frame.AbsolutePosition.Y - self.Window.TabHolder.AbsolutePosition.Y
end
function TabModule:New(Title, Icon, Parent)
  local Lib = getLibrary()
  local Window = self.Window
  self.TabCount = self.TabCount + 1
  local idx = self.TabCount
  local New = Creator.New
  if Lib:GetIcon(Icon) then Icon = Lib:GetIcon(Icon) end
  if Icon == "" or not Icon then Icon = nil end
  local tab = { Selected = false, Name = Title, Type = "Tab" }
  tab.Frame = New("TextButton", {
    Size = UDim2.new(1,0,0,34), BackgroundTransparency = 1, Parent = Parent, ThemeTag = { BackgroundColor3 = "Tab" },
  }, {
    New("UICorner", { CornerRadius = UDim.new(0,6) }),
    New("TextLabel", { AnchorPoint = Vector2.new(0,0.5), Position = Icon and UDim2.new(0,30,0.5,0) or UDim2.new(0,12,0.5,0), Text = Title, RichText = true, TextColor3 = Color3.fromRGB(255,255,255), TextTransparency = 0, FontFace = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Regular, Enum.FontStyle.Normal), TextSize = 12, TextXAlignment = "Left", TextYAlignment = "Center", Size = UDim2.new(1,-12,1,0), BackgroundTransparency = 1, ThemeTag = { TextColor3 = "Text" } }),
    New("ImageLabel", { AnchorPoint = Vector2.new(0,0.5), Size = UDim2.fromOffset(16,16), Position = UDim2.new(0,8,0.5,0), BackgroundTransparency = 1, Image = Icon or nil, ThemeTag = { ImageColor3 = "Text" } }),
  })
  local layout = New("UIListLayout", { Padding = UDim.new(0,5), SortOrder = Enum.SortOrder.LayoutOrder })
  tab.ContainerFrame = New("ScrollingFrame", {
    Size = UDim2.fromScale(1,1), BackgroundTransparency = 1, Parent = Window.ContainerHolder, Visible = false,
    BottomImage = "rbxassetid://6889812791", MidImage = "rbxassetid://6889812721", TopImage = "rbxassetid://6276641225",
    ScrollBarImageColor3 = Color3.fromRGB(255,255,255), ScrollBarImageTransparency = 0.95, ScrollBarThickness = 3, BorderSizePixel = 0, CanvasSize = UDim2.fromScale(0,0), ScrollingDirection = Enum.ScrollingDirection.Y,
  }, { layout, New("UIPadding", { PaddingRight = UDim.new(0,10), PaddingLeft = UDim.new(0,1), PaddingTop = UDim.new(0,1), PaddingBottom = UDim.new(0,1) }) })
  Creator.AddSignal(layout:GetPropertyChangedSignal("AbsoluteContentSize"), function() tab.ContainerFrame.CanvasSize = UDim2.new(0,0,0,layout.AbsoluteContentSize.Y + 2) end)
  tab.Motor, tab.SetTransparency = Creator.SpringMotor(1, tab.Frame, "BackgroundTransparency")
  Creator.AddSignal(tab.Frame.MouseEnter, function() tab.SetTransparency(tab.Selected and 0.85 or 0.89) end)
  Creator.AddSignal(tab.Frame.MouseLeave, function() tab.SetTransparency(tab.Selected and 0.89 or 1) end)
  Creator.AddSignal(tab.Frame.MouseButton1Down, function() tab.SetTransparency(0.92) end)
  Creator.AddSignal(tab.Frame.MouseButton1Up, function() tab.SetTransparency(tab.Selected and 0.85 or 0.89) end)
  Creator.AddSignal(tab.Frame.MouseButton1Click, function() TabModule:SelectTab(idx) end)
  self.Containers[idx] = tab.ContainerFrame
  self.Tabs[idx] = tab
  tab.Container = tab.ContainerFrame
  tab.ScrollFrame = tab.Container
  tab.Library = getLibrary()
  function tab:AddSection(title)
    local sec = { Type = "Section" }
    local sf = NewSection(title, tab.Container)
    sec.Container = sf.Container
    sec.ScrollFrame = tab.Container
    sec.Library = getLibrary()
    setmetatable(sec, Elements)
    return sec
  end
  setmetatable(tab, Elements)
  return tab
end
function TabModule:SelectTab(tabIdx)
  local Window = self.Window
  self.SelectedTab = tabIdx
  for _, t in next, self.Tabs do t.SetTransparency(1) t.Selected = false end
  self.Tabs[tabIdx].SetTransparency(0.89)
  self.Tabs[tabIdx].Selected = true
  Window.TabDisplay.Text = self.Tabs[tabIdx].Name
  Window.SelectorPosMotor:setGoal(Flipper.Spring.new(self:GetCurrentTabPos(), { frequency = 6 }))
  task.spawn(function()
    Window.ContainerHolder.Parent = Window.ContainerAnim
    Window.ContainerPosMotor:setGoal(Flipper.Spring.new(15, { frequency = 10 }))
    Window.ContainerBackMotor:setGoal(Flipper.Spring.new(1, { frequency = 10 }))
    task.wait(0.12)
    for _, c in next, self.Containers do c.Visible = false end
    self.Containers[tabIdx].Visible = true
    Window.ContainerPosMotor:setGoal(Flipper.Spring.new(0, { frequency = 5 }))
    Window.ContainerBackMotor:setGoal(Flipper.Spring.new(0, { frequency = 8 }))
    task.wait(0.12)
    Window.ContainerHolder.Parent = Window.ContainerCanvas
  end)
end

-- ============ Window builder ============
local function BuildWindow(Config)
  local Lib = getLibrary()
  local New = Creator.New
  local Spring, Instant = Flipper.Spring.new, Flipper.Instant.new
  local Window = {
    Minimized = false, Maximized = false, Size = Config.Size, CurrentPos = 0,
    Position = UDim2.fromOffset(Camera.ViewportSize.X/2 - Config.Size.X.Offset/2, Camera.ViewportSize.Y/2 - Config.Size.Y.Offset/2),
  }
  Window.TabWidth = Config.TabWidth or 160
  Window.AcrylicPaint = Acrylic.AcrylicPaint()
  local Dragging, DragInput, MousePos, StartPos = false
  local Resizing, ResizePos = false
  local MinimizeNotif = false
  local OldSizeX, OldSizeY
  local Selector = New("Frame", { Size = UDim2.fromOffset(4,0), BackgroundColor3 = Color3.fromRGB(76,194,255), Position = UDim2.fromOffset(0,17), AnchorPoint = Vector2.new(0,0.5), ThemeTag = { BackgroundColor3 = "Accent" } }, { New("UICorner", { CornerRadius = UDim.new(0,2) }) })
  local ResizeStartFrame = New("Frame", { Size = UDim2.fromOffset(20,20), BackgroundTransparency = 1, Position = UDim2.new(1,-20,1,-20) })
  Window.TabHolder = New("ScrollingFrame", {
    Size = UDim2.fromScale(1,1), BackgroundTransparency = 1, ScrollBarImageTransparency = 1, ScrollBarThickness = 0, BorderSizePixel = 0, CanvasSize = UDim2.fromScale(0,0), ScrollingDirection = Enum.ScrollingDirection.Y,
  }, { New("UIListLayout", { Padding = UDim.new(0,4) }) })
  local TabFrame = New("Frame", { Size = UDim2.new(0, Window.TabWidth, 1, -66), Position = UDim2.new(0,12,0,54), BackgroundTransparency = 1, ClipsDescendants = true }, { Window.TabHolder, Selector })
  Window.TabDisplay = New("TextLabel", {
    RichText = true, Text = "Tab", TextTransparency = 0, FontFace = Font.new("rbxassetid://12187365364", Enum.FontWeight.SemiBold, Enum.FontStyle.Normal), TextSize = 28, TextXAlignment = "Left", TextYAlignment = "Center",
    Size = UDim2.new(1,-16,0,28), Position = UDim2.fromOffset(Window.TabWidth + 26, 56), BackgroundTransparency = 1, ThemeTag = { TextColor3 = "Text" },
  })
  Window.ContainerHolder = New("Frame", { Size = UDim2.fromScale(1,1), BackgroundTransparency = 1 })
  Window.ContainerAnim = New("CanvasGroup", { Size = UDim2.fromScale(1,1), BackgroundTransparency = 1 })
  Window.ContainerCanvas = New("Frame", { Size = UDim2.new(1, -Window.TabWidth - 32, 1, -102), Position = UDim2.fromOffset(Window.TabWidth + 26, 90), BackgroundTransparency = 1 }, { Window.ContainerAnim, Window.ContainerHolder })
  local OpenScale = New("UIScale", { Scale = 0.92 })
  Window.Root = New("Frame", { BackgroundTransparency = 1, Size = Window.Size, Position = Window.Position, Parent = Config.Parent }, {
    Window.AcrylicPaint.Frame, Window.TabDisplay, Window.ContainerCanvas, TabFrame, ResizeStartFrame, OpenScale,
  })
  Window.TitleBar = NewTitleBar({ Title = Config.Title, SubTitle = Config.SubTitle, Parent = Window.Root, Window = Window })
  if Lib.UseAcrylic and Window.AcrylicPaint.AddParent then Window.AcrylicPaint.AddParent(Window.Root) end
  task.spawn(function()
    local openInfo = TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
    TweenService:Create(OpenScale, openInfo, { Scale = 1 }):Play()
    task.wait(0.4)
    OpenScale:Destroy()
  end)
  local SizeMotor = Flipper.GroupMotor.new({ X = Window.Size.X.Offset, Y = Window.Size.Y.Offset })
  local PosMotor = Flipper.GroupMotor.new({ X = Window.Position.X.Offset, Y = Window.Position.Y.Offset })
  Window.SelectorPosMotor = Flipper.SingleMotor.new(17)
  Window.SelectorSizeMotor = Flipper.SingleMotor.new(0)
  Window.ContainerBackMotor = Flipper.SingleMotor.new(0)
  Window.ContainerPosMotor = Flipper.SingleMotor.new(94)
  Window.ContainerAnim.Position = UDim2.fromOffset(0, 94)
  SizeMotor:onStep(function(v) Window.Root.Size = UDim2.new(0, v.X, 0, v.Y) end)
  PosMotor:onStep(function(v) Window.Root.Position = UDim2.new(0, v.X, 0, v.Y) end)
  local LastVal, LastTime = 0, 0
  Window.SelectorPosMotor:onStep(function(v)
    Selector.Position = UDim2.new(0, 0, 0, v + 17)
    local now = tick()
    if LastVal ~= nil then Window.SelectorSizeMotor:setGoal(Spring((math.abs(v - LastVal) / (math.max(0.001, (now - LastTime) * 60))) + 16)) LastVal = v end
    LastTime = now
  end)
  Window.SelectorSizeMotor:onStep(function(v) Selector.Size = UDim2.new(0, 4, 0, v) end)
  Window.ContainerBackMotor:onStep(function(v) Window.ContainerAnim.GroupTransparency = v end)
  Window.ContainerPosMotor:onStep(function(v) Window.ContainerAnim.Position = UDim2.fromOffset(0, v) end)
  function Window:Maximize(val, noPos, instant)
    self.Maximized = val
    self.TitleBar.MaxButton.Frame:FindFirstChild("Icon").Image = val and Assets.Restore or Assets.Max
    if val then OldSizeX = self.Size.X.Offset OldSizeY = self.Size.Y.Offset end
    local sx = val and Camera.ViewportSize.X or OldSizeX
    local sy = val and Camera.ViewportSize.Y or OldSizeY
    SizeMotor:setGoal({ X = (instant and Flipper.Instant or Flipper.Spring).new(sx, { frequency = 6 }), Y = (instant and Flipper.Instant or Flipper.Spring).new(sy, { frequency = 6 }) })
    self.Size = UDim2.fromOffset(sx, sy)
    if not noPos then PosMotor:setGoal({ X = Spring(val and 0 or self.Position.X.Offset, { frequency = 6 }), Y = Spring(val and 0 or self.Position.Y.Offset, { frequency = 6 }) }) end
  end
  Creator.AddSignal(Window.TitleBar.Frame.InputBegan, function(inp)
    if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
      Dragging = true MousePos = inp.Position StartPos = Window.Root.Position
      if Window.Maximized then StartPos = UDim2.fromOffset(Mouse.X - (Mouse.X * ((OldSizeX - 100) / Window.Root.AbsoluteSize.X)), Mouse.Y - (Mouse.Y * (OldSizeY / Window.Root.AbsoluteSize.Y))) end
      inp.Changed:Connect(function() if inp.UserInputState == Enum.UserInputState.End then Dragging = false end end)
    end
  end)
  Creator.AddSignal(Window.TitleBar.Frame.InputChanged, function(inp) if inp.UserInputType == Enum.UserInputType.MouseMovement or inp.UserInputType == Enum.UserInputType.Touch then DragInput = inp end end)
  Creator.AddSignal(ResizeStartFrame.InputBegan, function(inp) if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then Resizing = true ResizePos = inp.Position end end)
  Creator.AddSignal(UserInputService.InputChanged, function(inp)
    if inp == DragInput and Dragging then
      local delta = inp.Position - MousePos
      Window.Position = UDim2.fromOffset(StartPos.X.Offset + delta.X, StartPos.Y.Offset + delta.Y)
      PosMotor:setGoal({ X = Instant(Window.Position.X.Offset), Y = Instant(Window.Position.Y.Offset) })
      if Window.Maximized then Window:Maximize(false, true, true) end
    end
    if (inp.UserInputType == Enum.UserInputType.MouseMovement or inp.UserInputType == Enum.UserInputType.Touch) and Resizing then
      local delta = inp.Position - ResizePos
      local sz = Window.Size
      local target = Vector2.new(math.clamp(sz.X.Offset + delta.X, 470, 2048), math.clamp(sz.Y.Offset + delta.Y, 380, 2048))
      SizeMotor:setGoal({ X = Flipper.Instant.new(target.X), Y = Flipper.Instant.new(target.Y) })
    end
  end)
  Creator.AddSignal(UserInputService.InputEnded, function(inp) if Resizing or inp.UserInputType == Enum.UserInputType.Touch then Resizing = false Window.Size = UDim2.fromOffset(SizeMotor:getValue().X, SizeMotor:getValue().Y) end end)
  Creator.AddSignal(Window.TabHolder.UIListLayout:GetPropertyChangedSignal("AbsoluteContentSize"), function() Window.TabHolder.CanvasSize = UDim2.new(0,0,0,Window.TabHolder.UIListLayout.AbsoluteContentSize.Y) end)
  Creator.AddSignal(UserInputService.InputBegan, function(inp)
    if type(Lib.MinimizeKeybind) == "table" and Lib.MinimizeKeybind.Type == "Keybind" and not UserInputService:GetFocusedTextBox() then if inp.KeyCode.Name == Lib.MinimizeKeybind.Value then Window:Minimize() end
    elseif inp.KeyCode == Lib.MinimizeKey and not UserInputService:GetFocusedTextBox() then Window:Minimize() end
  end)
  Window.MinimizeScale = New("UIScale", { Scale = 1, Parent = Window.Root })
  function Window:Minimize()
    self.Minimized = not self.Minimized
    if self.Minimized then
      local ti = TweenInfo.new(0.2, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
      TweenService:Create(self.MinimizeScale, ti, { Scale = 0.95 }):Play()
      task.delay(0.2, function() self.Root.Visible = false self.MinimizeScale.Scale = 1 end)
    else
      self.MinimizeScale.Scale = 0.95
      self.Root.Visible = true
      TweenService:Create(self.MinimizeScale, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
    end
    if not MinimizeNotif then MinimizeNotif = true local key = Lib.MinimizeKeybind and Lib.MinimizeKeybind.Value or Lib.MinimizeKey.Name Lib:Notify({ Title = "Interface", Content = "Press " .. key .. " to toggle the interface.", Duration = 6 }) end
  end
  function Window:Destroy() if getLibrary().UseAcrylic and self.AcrylicPaint.Model then self.AcrylicPaint.Model:Destroy() end self.Root:Destroy() end
  DialogModule:Init(Window)
  function Window:Dialog(cfg)
    local d = DialogModule:Create()
    d.Title.Text = cfg.Title
    local content = New("TextLabel", { FontFace = Font.new("rbxasset://fonts/families/GothamSSm.json"), Text = cfg.Content, TextColor3 = Color3.fromRGB(240,240,240), TextSize = 14, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, Size = UDim2.new(1,-40,1,0), Position = UDim2.fromOffset(20,60), BackgroundTransparency = 1, Parent = d.Root, ClipsDescendants = false, ThemeTag = { TextColor3 = "Text" } })
    New("UISizeConstraint", { MinSize = Vector2.new(300,165), MaxSize = Vector2.new(620, math.huge), Parent = d.Root })
    d.Root.Size = UDim2.fromOffset(content.TextBounds.X + 40, 165)
    if content.TextBounds.X + 40 > self.Size.X.Offset - 120 then d.Root.Size = UDim2.fromOffset(self.Size.X.Offset - 120, 165) content.TextWrapped = true d.Root.Size = UDim2.fromOffset(self.Size.X.Offset - 120, content.TextBounds.Y + 150) end
    for _, b in next, cfg.Buttons do d:Button(b.Title, b.Callback) end
    d:Open()
  end
  TabModule:Init(Window)
  function Window:AddTab(tabCfg) return TabModule:New(tabCfg.Title, tabCfg.Icon, Window.TabHolder) end
  function Window:SelectTab(tabIdx) TabModule:SelectTab(tabIdx or 1) end
  Creator.AddSignal(Window.TabHolder:GetPropertyChangedSignal("CanvasPosition"), function() LastVal = TabModule:GetCurrentTabPos() + 16 LastTime = 0 Window.SelectorPosMotor:setGoal(Instant(TabModule:GetCurrentTabPos())) end)
  return Window
end

-- ============ Build Library (init) ============
local ProtectGui = protectgui or (syn and syn.protect_gui) or function() end
local GUI = Creator.New("ScreenGui", {
  Parent = RunService:IsStudio() and LocalPlayer.PlayerGui or game:GetService("CoreGui"),
})
ProtectGui(GUI)
Notification:Init(GUI)

local Library = {
  Version = "1.1.0",
  OpenFrames = {},
  Options = {},
  Themes = Themes.Names,
  Window = nil,
  WindowFrame = nil,
  Unloaded = false,
  Theme = "Dark",
  DialogOpen = false,
  UseAcrylic = false,
  Acrylic = false,
  Transparency = true,
  MinimizeKeybind = nil,
  MinimizeKey = Enum.KeyCode.LeftControl,
  GUI = GUI,
}

LibraryRef[1] = Library

function Library:SafeCallback(fn, ...)
  if not fn then return end
  local ok, err = pcall(fn, ...)
  if not ok then
    local _, i = tostring(err):find(":%d+: ")
    self:Notify({
      Title = "Interface", Content = "Callback error",
      SubContent = i and tostring(err):sub(i + 1) or tostring(err),
      Duration = 5,
    })
  end
end

function Library:Round(num, factor)
  if factor == 0 then return math.floor(num) end
  num = tostring(num)
  return num:find("%.") and tonumber(num:sub(1, num:find("%.") + factor)) or num
end

function Library:GetIcon(name)
  if name and Icons.assets["lucide-" .. name] then return Icons.assets["lucide-" .. name] end
  return nil
end

-- Elements table (AddButton, AddToggle, etc.) - populated below
local Elements = {}
Elements.__index = Elements
Library.Elements = Elements

function Library:CreateWindow(cfg)
  assert(cfg.Title, "Window - Missing Title")
  if self.Window then print("You cannot create more than one window.") return end
  self.MinimizeKey = cfg.MinimizeKey or Enum.KeyCode.LeftControl
  self.UseAcrylic = cfg.Acrylic or false
  self.Theme = cfg.Theme or "Dark"
  if cfg.Acrylic then Acrylic.init() end
  local Window = BuildWindow({
    Parent = GUI,
    Size = cfg.Size or UDim2.fromOffset(500, 350),
    Title = cfg.Title,
    SubTitle = cfg.SubTitle or "",
    TabWidth = cfg.TabWidth or 160,
  })
  self.Window = Window
  self:SetTheme(cfg.Theme or "Dark")
  return Window
end

function Library:SetTheme(value)
  if self.Window and table.find(self.Themes, value) then
    self.Theme = value
    Creator.UpdateTheme()
  end
end

function Library:Destroy()
  if self.Window then
    self.Unloaded = true
    if self.UseAcrylic and self.Window.AcrylicPaint then self.Window.AcrylicPaint.Model:Destroy() end
    Creator.Disconnect()
    self.GUI:Destroy()
  end
end

function Library:ToggleAcrylic(value)
  if self.Window and self.UseAcrylic then
    self.Acrylic = value
    if self.Window.AcrylicPaint and self.Window.AcrylicPaint.Model then
      self.Window.AcrylicPaint.Model.Transparency = value and 0.98 or 1
    end
    if value then Acrylic.Enable() else Acrylic.Disable() end
  end
end

function Library:ToggleTransparency(value)
  if self.Window and self.Window.AcrylicPaint and self.Window.AcrylicPaint.Frame and self.Window.AcrylicPaint.Frame.Background then
    self.Window.AcrylicPaint.Frame.Background.BackgroundTransparency = value and 0.35 or 0
  end
end

function Library:Notify(cfg)
  return Notification:New(cfg)
end

-- Element types: add minimal Button + Toggle + Paragraph so Elements work
local function AddButton(self, idx, cfg)
  assert(cfg.Title, "Button - Missing Title")
  cfg.Callback = cfg.Callback or function() end
  local el = NewElement(cfg.Title, cfg.Description or "", self.Container, true)
  local arrow = Creator.New("ImageLabel", {
    Image = "rbxassetid://10709791437", Size = UDim2.fromOffset(16,16), AnchorPoint = Vector2.new(1,0.5), Position = UDim2.new(1,-10,0.5,0), BackgroundTransparency = 1, Parent = el.Frame, ThemeTag = { ImageColor3 = "Text" },
  })
  el.Frame.ClipsDescendants = true
  Creator.AddSignal(el.Frame.MouseButton1Click, function()
    Creator.CreateRipple(el.Frame)
    self.Library:SafeCallback(cfg.Callback)
  end)
  return el
end

local function AddParagraph(self, idx, cfg)
  assert(cfg.Title, "Paragraph - Missing Title")
  cfg.Content = cfg.Content or ""
  local el = NewElement(cfg.Title, cfg.Content, self.Container, false)
  el.Frame.BackgroundTransparency = 0.92
  el.Border.Transparency = 0.6
  return el
end

Elements.AddButton = AddButton
Elements.AddParagraph = AddParagraph

-- Element: Toggle
local function AddToggle(self, idx, cfg)
  local Lib = self.Library
  assert(cfg.Title, "Toggle - Missing Title")
  local t = { Value = cfg.Default or false, Callback = cfg.Callback or function() end, Type = "Toggle" }
  local frame = NewElement(cfg.Title, cfg.Description or "", self.Container, true)
  frame.DescLabel.Size = UDim2.new(1, -54, 0, 14)
  t.SetTitle, t.SetDesc = frame.SetTitle, frame.SetDesc
  local New = Creator.New
  local circle = New("ImageLabel", { AnchorPoint = Vector2.new(0,0.5), Size = UDim2.fromOffset(14,14), Position = UDim2.new(0,2,0.5,0), Image = "http://www.roblox.com/asset/?id=12266946128", ImageTransparency = 0.5, ThemeTag = { ImageColor3 = "ToggleSlider" } })
  local border = New("UIStroke", { Transparency = 0.5, ThemeTag = { Color = "ToggleSlider" } })
  local slider = New("Frame", { Size = UDim2.fromOffset(36,18), AnchorPoint = Vector2.new(1,0.5), Position = UDim2.new(1,-10,0.5,0), Parent = frame.Frame, BackgroundTransparency = 1, ThemeTag = { BackgroundColor3 = "Accent" } }, { New("UICorner", { CornerRadius = UDim.new(0,9) }), border, circle })
  function t:OnChanged(fn) t.Changed = fn fn(t.Value) end
  function t:SetValue(v)
    v = not not v
    t.Value = v
    Creator.OverrideTag(border, { Color = v and "Accent" or "ToggleSlider" })
    Creator.OverrideTag(circle, { ImageColor3 = v and "ToggleToggled" or "ToggleSlider" })
    TweenService:Create(circle, TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { Position = UDim2.new(0, v and 19 or 2, 0.5, 0) }):Play()
    TweenService:Create(slider, TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { BackgroundTransparency = v and 0 or 1 }):Play()
    circle.ImageTransparency = v and 0 or 0.5
    Lib:SafeCallback(t.Callback, t.Value)
    Lib:SafeCallback(t.Changed, t.Value)
  end
  function t:Destroy() frame:Destroy() Lib.Options[idx] = nil end
  Creator.AddSignal(frame.Frame.MouseButton1Click, function() t:SetValue(not t.Value) end)
  t:SetValue(t.Value)
  Lib.Options[idx] = t
  return t
end
Elements.AddToggle = AddToggle

-- Element: Slider
local function AddSlider(self, idx, cfg)
  local Lib = self.Library
  assert(cfg.Title, "Slider - Missing Title") assert(cfg.Default, "Slider - Missing default") assert(cfg.Min and cfg.Max and cfg.Rounding, "Slider - Missing min/max/rounding")
  local s = { Value = nil, Min = cfg.Min, Max = cfg.Max, Rounding = cfg.Rounding, Callback = cfg.Callback or function() end, Type = "Slider" }
  local dragging = false
  local frame = NewElement(cfg.Title, cfg.Description or "", self.Container, false)
  frame.DescLabel.Size = UDim2.new(1, -170, 0, 14)
  s.SetTitle, s.SetDesc = frame.SetTitle, frame.SetDesc
  local New = Creator.New
  local dot = New("ImageLabel", { AnchorPoint = Vector2.new(0,0.5), Position = UDim2.new(0,-7,0.5,0), Size = UDim2.fromOffset(14,14), Image = "http://www.roblox.com/asset/?id=12266946128", ThemeTag = { ImageColor3 = "Accent" } })
  local rail = New("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(7,0), Size = UDim2.new(1,-14,1,0) }, { dot })
  local fill = New("Frame", { Size = UDim2.new(0,0,1,0), ThemeTag = { BackgroundColor3 = "Accent" } }, { New("UICorner", { CornerRadius = UDim.new(1,0) }) })
  local display = New("TextLabel", { FontFace = Font.new("rbxasset://fonts/families/GothamSSm.json"), Text = "Value", TextSize = 12, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Right, BackgroundTransparency = 1, Size = UDim2.new(0,100,0,14), Position = UDim2.new(0,-4,0.5,0), AnchorPoint = Vector2.new(1,0.5), ThemeTag = { TextColor3 = "SubText" } })
  New("Frame", { Size = UDim2.new(1,0,0,4), AnchorPoint = Vector2.new(1,0.5), Position = UDim2.new(1,-10,0.5,0), BackgroundTransparency = 0.4, Parent = frame.Frame, ThemeTag = { BackgroundColor3 = "SliderRail" } }, {
    New("UICorner", { CornerRadius = UDim.new(1,0) }), New("UISizeConstraint", { MaxSize = Vector2.new(150, math.huge) }), display, fill, rail,
  })
  Creator.AddSignal(dot.InputBegan, function(inp) if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then dragging = true end end)
  Creator.AddSignal(dot.InputEnded, function(inp) if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then dragging = false end end)
  Creator.AddSignal(UserInputService.InputChanged, function(inp)
    if dragging and (inp.UserInputType == Enum.UserInputType.MouseMovement or inp.UserInputType == Enum.UserInputType.Touch) then
      local scale = math.clamp((inp.Position.X - rail.AbsolutePosition.X) / rail.AbsoluteSize.X, 0, 1)
      s:SetValue(s.Min + (s.Max - s.Min) * scale)
    end
  end)
  function s:OnChanged(fn) s.Changed = fn fn(s.Value) end
  function s:SetValue(v)
    s.Value = Lib:Round(math.clamp(v, s.Min, s.Max), s.Rounding)
    dot.Position = UDim2.new((s.Value - s.Min) / (s.Max - s.Min), -7, 0.5, 0)
    fill.Size = UDim2.fromScale((s.Value - s.Min) / (s.Max - s.Min), 1)
    display.Text = tostring(s.Value)
    Lib:SafeCallback(s.Callback, s.Value)
    Lib:SafeCallback(s.Changed, s.Value)
  end
  function s:Destroy() frame:Destroy() Lib.Options[idx] = nil end
  s:SetValue(cfg.Default)
  Lib.Options[idx] = s
  return s
end
Elements.AddSlider = AddSlider

-- Element: Input
local function AddInput(self, idx, cfg)
  local Lib = self.Library
  assert(cfg.Title, "Input - Missing Title")
  cfg.Callback = cfg.Callback or function() end
  local inp = { Value = cfg.Default or "", Numeric = cfg.Numeric or false, Finished = cfg.Finished or false, Callback = cfg.Callback, Type = "Input" }
  local frame = NewElement(cfg.Title, cfg.Description or "", self.Container, false)
  inp.SetTitle, inp.SetDesc = frame.SetTitle, frame.SetDesc
  local tb = NewTextbox(frame.Frame, true)
  tb.Frame.Position = UDim2.new(1,-10,0.5,0) tb.Frame.AnchorPoint = Vector2.new(1,0.5) tb.Frame.Size = UDim2.fromOffset(160,30)
  tb.Input.Text = cfg.Default or "" tb.Input.PlaceholderText = cfg.Placeholder or ""
  local box = tb.Input
  function inp:SetValue(text)
    if cfg.MaxLength and #text > cfg.MaxLength then text = text:sub(1, cfg.MaxLength) end
    if inp.Numeric and (not tonumber(text)) and #text > 0 then text = inp.Value end
    inp.Value = text box.Text = text
    Lib:SafeCallback(inp.Callback, inp.Value) Lib:SafeCallback(inp.Changed, inp.Value)
  end
  if inp.Finished then Creator.AddSignal(box.FocusLost, function(enter) if enter then inp:SetValue(box.Text) end end)
  else Creator.AddSignal(box:GetPropertyChangedSignal("Text"), function() inp:SetValue(box.Text) end) end
  function inp:OnChanged(fn) inp.Changed = fn fn(inp.Value) end
  function inp:Destroy() frame:Destroy() Lib.Options[idx] = nil end
  Lib.Options[idx] = inp
  return inp
end
Elements.AddInput = AddInput

-- Element: Keybind
local function AddKeybind(self, idx, cfg)
  local Lib = self.Library
  assert(cfg.Title, "KeyBind - Missing Title") assert(cfg.Default, "KeyBind - Missing default")
  local kb = { Value = cfg.Default, Toggled = false, Mode = cfg.Mode or "Toggle", Type = "Keybind", Callback = cfg.Callback or function() end, ChangedCallback = cfg.ChangedCallback or function() end }
  local picking = false
  local frame = NewElement(cfg.Title, cfg.Description or "", self.Container, true)
  kb.SetTitle, kb.SetDesc = frame.SetTitle, frame.SetDesc
  local New = Creator.New
  local label = New("TextLabel", { FontFace = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Regular, Enum.FontStyle.Normal), Text = cfg.Default, TextColor3 = Color3.fromRGB(240,240,240), TextSize = 13, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.new(0,0,0,14), Position = UDim2.new(0,0,0.5,0), AnchorPoint = Vector2.new(0,0.5), AutomaticSize = Enum.AutomaticSize.X, BackgroundTransparency = 1, ThemeTag = { TextColor3 = "Text" } })
  local btn = New("TextButton", { Size = UDim2.fromOffset(0,30), Position = UDim2.new(1,-10,0.5,0), AnchorPoint = Vector2.new(1,0.5), BackgroundTransparency = 0.9, Parent = frame.Frame, AutomaticSize = Enum.AutomaticSize.X, ThemeTag = { BackgroundColor3 = "Keybind" } }, {
    New("UICorner", { CornerRadius = UDim.new(0,5) }), New("UIPadding", { PaddingLeft = UDim.new(0,8), PaddingRight = UDim.new(0,8) }),
    New("UIStroke", { Transparency = 0.5, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, ThemeTag = { Color = "InElementBorder" } }), label,
  })
  function kb:GetState()
    if UserInputService:GetFocusedTextBox() and kb.Mode ~= "Always" then return false end
    if kb.Mode == "Always" then return true end
    if kb.Mode == "Hold" then
      if kb.Value == "None" then return false end
      if kb.Value == "MouseLeft" or kb.Value == "MouseRight" then return kb.Value == "MouseLeft" and UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) or kb.Value == "MouseRight" and UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2) end
      return UserInputService:IsKeyDown(Enum.KeyCode[kb.Value])
    end
    return kb.Toggled
  end
  function kb:SetValue(key, mode) kb.Value = key or kb.Value kb.Mode = mode or kb.Mode label.Text = kb.Value end
  function kb:OnClick(fn) kb.Clicked = fn end
  function kb:OnChanged(fn) kb.Changed = fn fn(kb.Value) end
  function kb:DoClick() Lib:SafeCallback(kb.Callback, kb.Toggled) Lib:SafeCallback(kb.Clicked, kb.Toggled) end
  function kb:Destroy() frame:Destroy() Lib.Options[idx] = nil end
  Creator.AddSignal(btn.InputBegan, function(inp)
    if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
      picking = true label.Text = "..."
      task.wait(0.2)
      local conn; conn = UserInputService.InputBegan:Connect(function(i)
        local key = i.UserInputType == Enum.UserInputType.Keyboard and i.KeyCode.Name or i.UserInputType == Enum.UserInputType.MouseButton1 and "MouseLeft" or "MouseRight"
        UserInputService.InputEnded:Connect(function(e)
          if e.KeyCode and e.KeyCode.Name == key or key == "MouseLeft" and e.UserInputType == Enum.UserInputType.MouseButton1 or key == "MouseRight" and e.UserInputType == Enum.UserInputType.MouseButton2 then
            picking = false label.Text = key kb.Value = key Lib:SafeCallback(kb.ChangedCallback, e.KeyCode or e.UserInputType) Lib:SafeCallback(kb.Changed, e.KeyCode or e.UserInputType) conn:Disconnect()
          end
        end)
      end)
    end
  end)
  Creator.AddSignal(UserInputService.InputBegan, function(inp)
    if not picking and not UserInputService:GetFocusedTextBox() and kb.Mode == "Toggle" then
      local key = kb.Value
      if key == "MouseLeft" or key == "MouseRight" then if (key == "MouseLeft" and inp.UserInputType == Enum.UserInputType.MouseButton1) or (key == "MouseRight" and inp.UserInputType == Enum.UserInputType.MouseButton2) then kb.Toggled = not kb.Toggled kb:DoClick() end
      elseif inp.UserInputType == Enum.UserInputType.Keyboard and inp.KeyCode.Name == key then kb.Toggled = not kb.Toggled kb:DoClick() end
    end
  end)
  Lib.Options[idx] = kb
  return kb
end
Elements.AddKeybind = AddKeybind

-- Element: Dropdown (full from src/Elements/Dropdown.lua)
local function AddDropdown(self, idx, cfg)
  local Library = self.Library
  local New = Creator.New
  local Dropdown = {
    Values = cfg.Values or {},
    Value = cfg.Multi and {} or cfg.Default,
    Multi = cfg.Multi,
    Buttons = {},
    Opened = false,
    Type = "Dropdown",
    Callback = cfg.Callback or function() end,
  }
  local DropdownFrame = NewElement(cfg.Title, cfg.Description, self.Container, false)
  DropdownFrame.DescLabel.Size = UDim2.new(1, -170, 0, 14)
  Dropdown.SetTitle = DropdownFrame.SetTitle
  Dropdown.SetDesc = DropdownFrame.SetDesc
  local DropdownDisplay = New("TextLabel", {
    FontFace = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Regular, Enum.FontStyle.Normal),
    Text = "--", TextColor3 = Color3.fromRGB(240,240,240), TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left,
    Size = UDim2.new(1,-30,0,14), Position = UDim2.new(0,8,0.5,0), AnchorPoint = Vector2.new(0,0.5),
    BackgroundTransparency = 1, TextTruncate = Enum.TextTruncate.AtEnd, ThemeTag = { TextColor3 = "Text" },
  })
  local DropdownIco = New("ImageLabel", {
    Image = "rbxassetid://10709790948", Size = UDim2.fromOffset(16,16), AnchorPoint = Vector2.new(1,0.5),
    Position = UDim2.new(1,-8,0.5,0), BackgroundTransparency = 1, ThemeTag = { ImageColor3 = "SubText" },
  })
  local DropdownInner = New("TextButton", {
    Size = UDim2.fromOffset(160,30), Position = UDim2.new(1,-10,0.5,0), AnchorPoint = Vector2.new(1,0.5),
    BackgroundTransparency = 0.9, Parent = DropdownFrame.Frame, ThemeTag = { BackgroundColor3 = "DropdownFrame" },
  }, {
    New("UICorner", { CornerRadius = UDim.new(0,5) }),
    New("UIStroke", { Transparency = 0.5, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, ThemeTag = { Color = "InElementBorder" } }),
    DropdownIco, DropdownDisplay,
  })
  local DropdownListLayout = New("UIListLayout", { Padding = UDim.new(0,3) })
  local DropdownScrollFrame = New("ScrollingFrame", {
    Size = UDim2.new(1,-5,1,-10), Position = UDim2.fromOffset(5,5), BackgroundTransparency = 1,
    BottomImage = "rbxassetid://6889812791", MidImage = "rbxassetid://6889812721", TopImage = "rbxassetid://6276641225",
    ScrollBarImageColor3 = Color3.fromRGB(255,255,255), ScrollBarImageTransparency = 0.95, ScrollBarThickness = 4,
    BorderSizePixel = 0, CanvasSize = UDim2.fromScale(0,0),
  }, { DropdownListLayout })
  local DropdownHolderFrame = New("Frame", {
    Size = UDim2.fromScale(1,0.6), ThemeTag = { BackgroundColor3 = "DropdownHolder" },
  }, {
    DropdownScrollFrame,
    New("UICorner", { CornerRadius = UDim.new(0,7) }),
    New("UIStroke", { ApplyStrokeMode = Enum.ApplyStrokeMode.Border, ThemeTag = { Color = "DropdownBorder" } }),
    New("ImageLabel", { BackgroundTransparency = 1, Image = "http://www.roblox.com/asset/?id=5554236805", ScaleType = Enum.ScaleType.Slice, SliceCenter = Rect.new(23,23,277,277), Size = UDim2.fromScale(1,1) + UDim2.fromOffset(30,30), Position = UDim2.fromOffset(-15,-15), ImageColor3 = Color3.fromRGB(0,0,0), ImageTransparency = 0.1 }),
  })
  local DropdownHolderCanvas = New("Frame", {
    BackgroundTransparency = 1, Size = UDim2.fromOffset(170,300), Parent = Library.GUI, Visible = false,
  }, {
    DropdownHolderFrame,
    New("UISizeConstraint", { MinSize = Vector2.new(170,0) }),
  })
  table.insert(Library.OpenFrames, DropdownHolderCanvas)
  local ListSizeX = 0
  local function RecalculateListPosition()
    local Add = 0
    if Camera.ViewportSize.Y - DropdownInner.AbsolutePosition.Y < DropdownHolderCanvas.AbsoluteSize.Y - 5 then
      Add = DropdownHolderCanvas.AbsoluteSize.Y - 5 - (Camera.ViewportSize.Y - DropdownInner.AbsolutePosition.Y) + 40
    end
    DropdownHolderCanvas.Position = UDim2.fromOffset(DropdownInner.AbsolutePosition.X - 1, DropdownInner.AbsolutePosition.Y - 5 - Add)
  end
  local function RecalculateListSize()
    if #Dropdown.Values > 10 then
      DropdownHolderCanvas.Size = UDim2.fromOffset(ListSizeX, 392)
    else
      DropdownHolderCanvas.Size = UDim2.fromOffset(ListSizeX, DropdownListLayout.AbsoluteContentSize.Y + 10)
    end
  end
  local function RecalculateCanvasSize()
    DropdownScrollFrame.CanvasSize = UDim2.fromOffset(0, DropdownListLayout.AbsoluteContentSize.Y)
  end
  RecalculateListPosition()
  RecalculateListSize()
  Creator.AddSignal(DropdownInner:GetPropertyChangedSignal("AbsolutePosition"), RecalculateListPosition)
  Creator.AddSignal(DropdownInner.MouseButton1Click, function() Dropdown:Open() end)
  Creator.AddSignal(UserInputService.InputBegan, function(Input)
    if Input.UserInputType == Enum.UserInputType.MouseButton1 or Input.UserInputType == Enum.UserInputType.Touch then
      local AbsPos, AbsSize = DropdownHolderFrame.AbsolutePosition, DropdownHolderFrame.AbsoluteSize
      if Mouse.X < AbsPos.X or Mouse.X > AbsPos.X + AbsSize.X or Mouse.Y < (AbsPos.Y - 20 - 1) or Mouse.Y > AbsPos.Y + AbsSize.Y then
        Dropdown:Close()
      end
    end
  end)
  local ScrollFrame = self.ScrollFrame
  function Dropdown:Open()
    Dropdown.Opened = true
    if ScrollFrame then ScrollFrame.ScrollingEnabled = false end
    DropdownHolderCanvas.Visible = true
    TweenService:Create(DropdownHolderFrame, TweenInfo.new(0.2, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), { Size = UDim2.fromScale(1,1) }):Play()
  end
  function Dropdown:Close()
    Dropdown.Opened = false
    if ScrollFrame then ScrollFrame.ScrollingEnabled = true end
    DropdownHolderFrame.Size = UDim2.fromScale(1,0.6)
    DropdownHolderCanvas.Visible = false
  end
  function Dropdown:Display()
    local Values = Dropdown.Values
    local Str = ""
    if cfg.Multi then
      for _, Value in next, Values do
        if Dropdown.Value[Value] then Str = Str .. Value .. ", " end
      end
      Str = Str:sub(1, #Str - 2)
    else
      Str = Dropdown.Value or ""
    end
    DropdownDisplay.Text = (Str == "" and "--" or Str)
  end
  function Dropdown:GetActiveValues()
    if cfg.Multi then
      local T = {}
      for Value, _ in next, Dropdown.Value do table.insert(T, Value) end
      return T
    else
      return Dropdown.Value and 1 or 0
    end
  end
  function Dropdown:BuildDropdownList()
    local Values = Dropdown.Values
    local Buttons = {}
    for _, el in next, DropdownScrollFrame:GetChildren() do
      if not el:IsA("UIListLayout") then el:Destroy() end
    end
    for _, Value in next, Values do
      local Table = {}
      local ButtonSelector = New("Frame", {
        Size = UDim2.fromOffset(4,14), BackgroundColor3 = Color3.fromRGB(76,194,255), Position = UDim2.fromOffset(-1,16), AnchorPoint = Vector2.new(0,0.5), ThemeTag = { BackgroundColor3 = "Accent" },
      }, { New("UICorner", { CornerRadius = UDim.new(0,2) }) })
      local ButtonLabel = New("TextLabel", {
        FontFace = Font.new("rbxasset://fonts/families/GothamSSm.json"), Text = Value, TextColor3 = Color3.fromRGB(200,200,200), TextSize = 13,
        TextXAlignment = Enum.TextXAlignment.Left, BackgroundTransparency = 1, AutomaticSize = Enum.AutomaticSize.Y, Size = UDim2.fromScale(1,1),
        Position = UDim2.fromOffset(10,0), Name = "ButtonLabel", ThemeTag = { TextColor3 = "Text" },
      })
      local Button = New("TextButton", {
        Size = UDim2.new(1,-5,0,32), BackgroundTransparency = 1, ZIndex = 23, Text = "", Parent = DropdownScrollFrame, ThemeTag = { BackgroundColor3 = "DropdownOption" },
      }, { ButtonSelector, ButtonLabel, New("UICorner", { CornerRadius = UDim.new(0,6) }) })
      local Selected
      if cfg.Multi then Selected = Dropdown.Value[Value] else Selected = Dropdown.Value == Value end
      local _, SetBackTransparency = Creator.SpringMotor(1, Button, "BackgroundTransparency")
      local _, SetSelTransparency = Creator.SpringMotor(1, ButtonSelector, "BackgroundTransparency")
      local SelectorSizeMotor = Flipper.SingleMotor.new(6)
      SelectorSizeMotor:onStep(function(v) ButtonSelector.Size = UDim2.new(0,4,0,v) end)
      Creator.AddSignal(Button.MouseEnter, function() SetBackTransparency(Selected and 0.85 or 0.89) end)
      Creator.AddSignal(Button.MouseLeave, function() SetBackTransparency(Selected and 0.89 or 1) end)
      Creator.AddSignal(Button.MouseButton1Down, function() SetBackTransparency(0.92) end)
      Creator.AddSignal(Button.MouseButton1Up, function() SetBackTransparency(Selected and 0.85 or 0.89) end)
      function Table:UpdateButton()
        if cfg.Multi then
          Selected = Dropdown.Value[Value]
          if Selected then SetBackTransparency(0.89) end
        else
          Selected = Dropdown.Value == Value
          SetBackTransparency(Selected and 0.89 or 1)
        end
        SelectorSizeMotor:setGoal(Flipper.Spring.new(Selected and 14 or 6, { frequency = 6 }))
        SetSelTransparency(Selected and 0 or 1)
      end
      Creator.AddSignal(ButtonLabel.InputBegan, function(Input)
        if Input.UserInputType == Enum.UserInputType.MouseButton1 or Input.UserInputType == Enum.UserInputType.Touch then
          local Try = not Selected
          if Dropdown:GetActiveValues() == 1 and not Try and not cfg.AllowNull then
          else
            if cfg.Multi then
              Selected = Try
              Dropdown.Value[Value] = Selected and true or nil
            else
              Selected = Try
              Dropdown.Value = Selected and Value or nil
              for _, OtherButton in next, Buttons do OtherButton:UpdateButton() end
            end
            Table:UpdateButton()
            Dropdown:Display()
            Library:SafeCallback(Dropdown.Callback, Dropdown.Value)
            Library:SafeCallback(Dropdown.Changed, Dropdown.Value)
          end
        end
      end)
      Table:UpdateButton()
      Dropdown:Display()
      Buttons[Button] = Table
    end
    ListSizeX = 0
    for Btn, _ in next, Buttons do
      if Btn:FindFirstChild("ButtonLabel") then
        if Btn.ButtonLabel.TextBounds.X > ListSizeX then ListSizeX = Btn.ButtonLabel.TextBounds.X end
      end
    end
    ListSizeX = ListSizeX + 30
    RecalculateCanvasSize()
    RecalculateListSize()
  end
  function Dropdown:SetValues(NewValues)
    if NewValues then Dropdown.Values = NewValues end
    Dropdown:BuildDropdownList()
  end
  function Dropdown:OnChanged(Func) Dropdown.Changed = Func Func(Dropdown.Value) end
  function Dropdown:SetValue(Val)
    if Dropdown.Multi then
      local nTable = {}
      for Value, _ in next, Val do
        if table.find(Dropdown.Values, Value) then nTable[Value] = true end
      end
      Dropdown.Value = nTable
    else
      if not Val then Dropdown.Value = nil
      elseif table.find(Dropdown.Values, Val) then Dropdown.Value = Val end
    end
    Dropdown:BuildDropdownList()
    Library:SafeCallback(Dropdown.Callback, Dropdown.Value)
    Library:SafeCallback(Dropdown.Changed, Dropdown.Value)
  end
  function Dropdown:Destroy() DropdownFrame:Destroy() DropdownHolderCanvas:Destroy() Library.Options[idx] = nil end
  Dropdown:BuildDropdownList()
  Dropdown:Display()
  local Defaults = {}
  if type(cfg.Default) == "string" then
    local i = table.find(Dropdown.Values, cfg.Default)
    if i then table.insert(Defaults, i) end
  elseif type(cfg.Default) == "table" then
    for _, Value in next, cfg.Default do
      local i = table.find(Dropdown.Values, Value)
      if i then table.insert(Defaults, i) end
    end
  elseif type(cfg.Default) == "number" and Dropdown.Values[cfg.Default] ~= nil then
    table.insert(Defaults, cfg.Default)
  end
  if next(Defaults) then
    for i = 1, #Defaults do
      local Index = Defaults[i]
      if cfg.Multi then Dropdown.Value[Dropdown.Values[Index]] = true
      else Dropdown.Value = Dropdown.Values[Index] end
      if not cfg.Multi then break end
    end
    Dropdown:BuildDropdownList()
    Dropdown:Display()
  end
  Library.Options[idx] = Dropdown
  return Dropdown
end
Elements.AddDropdown = AddDropdown

-- Element: Colorpicker (full from src/Elements/Colorpicker.lua)
local function AddColorpicker(self, idx, cfg)
  local Library = self.Library
  local New = Creator.New
  local RenderStepped = RunService.RenderStepped
  assert(cfg.Title, "Colorpicker - Missing Title")
  assert(cfg.Default, "Colorpicker - Missing default value.")
  local Colorpicker = {
    Value = cfg.Default,
    Transparency = cfg.Transparency or 0,
    Type = "Colorpicker",
    Title = type(cfg.Title) == "string" and cfg.Title or "Colorpicker",
    Callback = cfg.Callback or function() end,
  }
  function Colorpicker:SetHSVFromRGB(Color)
    local H, S, V = Color3.toHSV(Color)
    Colorpicker.Hue = H Colorpicker.Sat = S Colorpicker.Vib = V
  end
  Colorpicker:SetHSVFromRGB(Colorpicker.Value)
  local ColorpickerFrame = NewElement(cfg.Title, cfg.Description, self.Container, true)
  Colorpicker.SetTitle = ColorpickerFrame.SetTitle
  Colorpicker.SetDesc = ColorpickerFrame.SetDesc
  local DisplayFrameColor = New("Frame", {
    Size = UDim2.fromScale(1,1), BackgroundColor3 = Colorpicker.Value, Parent = ColorpickerFrame.Frame,
  }, { New("UICorner", { CornerRadius = UDim.new(0,4) }) })
  local DisplayFrame = New("ImageLabel", {
    Size = UDim2.fromOffset(26,26), Position = UDim2.new(1,-10,0.5,0), AnchorPoint = Vector2.new(1,0.5),
    Parent = ColorpickerFrame.Frame, Image = "http://www.roblox.com/asset/?id=14204231522",
    ImageTransparency = 0.45, ScaleType = Enum.ScaleType.Tile, TileSize = UDim2.fromOffset(40,40),
  }, { New("UICorner", { CornerRadius = UDim.new(0,4) }), DisplayFrameColor })
  local function CreateColorDialog()
    local Dialog = DialogModule:Create()
    Dialog.Title.Text = Colorpicker.Title
    Dialog.Root.Size = UDim2.fromOffset(430, 330)
    local Hue, Sat, Vib = Colorpicker.Hue, Colorpicker.Sat, Colorpicker.Vib
    local Transp = Colorpicker.Transparency
    local function CreateCPInput()
      local Box = NewTextbox()
      Box.Frame.Parent = Dialog.Root
      Box.Frame.Size = UDim2.new(0,90,0,32)
      return Box
    end
    local function CreateInputLabel(Text, Pos)
      return New("TextLabel", {
        FontFace = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Medium, Enum.FontStyle.Normal),
        Text = Text, TextColor3 = Color3.fromRGB(240,240,240), TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left,
        Size = UDim2.new(1,0,0,32), Position = Pos, BackgroundTransparency = 1, Parent = Dialog.Root,
        ThemeTag = { TextColor3 = "Text" },
      })
    end
    local function GetRGB()
      local Value = Color3.fromHSV(Hue, Sat, Vib)
      return { R = math.floor(Value.r * 255), G = math.floor(Value.g * 255), B = math.floor(Value.b * 255) }
    end
    local SatCursor = New("ImageLabel", {
      Size = UDim2.new(0,18,0,18), ScaleType = Enum.ScaleType.Fit, AnchorPoint = Vector2.new(0.5,0.5),
      BackgroundTransparency = 1, Image = "http://www.roblox.com/asset/?id=4805639000",
    })
    local SatVibMap = New("ImageLabel", {
      Size = UDim2.fromOffset(180,160), Position = UDim2.fromOffset(20,55), Image = "rbxassetid://4155801252",
      BackgroundColor3 = Colorpicker.Value, BackgroundTransparency = 0, Parent = Dialog.Root,
    }, { New("UICorner", { CornerRadius = UDim.new(0,4) }), SatCursor })
    local OldColorFrame = New("Frame", {
      BackgroundColor3 = Colorpicker.Value, Size = UDim2.fromScale(1,1), BackgroundTransparency = Colorpicker.Transparency,
    }, { New("UICorner", { CornerRadius = UDim.new(0,4) }) })
    New("ImageLabel", {
      Image = "http://www.roblox.com/asset/?id=14204231522", ImageTransparency = 0.45, ScaleType = Enum.ScaleType.Tile,
      TileSize = UDim2.fromOffset(40,40), BackgroundTransparency = 1, Position = UDim2.fromOffset(112,220),
      Size = UDim2.fromOffset(88,24), Parent = Dialog.Root,
    }, { New("UICorner", { CornerRadius = UDim.new(0,4) }), New("UIStroke", { Thickness = 2, Transparency = 0.75 }), OldColorFrame })
    local DialogDisplayFrame = New("Frame", {
      BackgroundColor3 = Colorpicker.Value, Size = UDim2.fromScale(1,1), BackgroundTransparency = 0,
    }, { New("UICorner", { CornerRadius = UDim.new(0,4) }) })
    New("ImageLabel", {
      Image = "http://www.roblox.com/asset/?id=14204231522", ImageTransparency = 0.45, ScaleType = Enum.ScaleType.Tile,
      TileSize = UDim2.fromOffset(40,40), BackgroundTransparency = 1, Position = UDim2.fromOffset(20,220),
      Size = UDim2.fromOffset(88,24), Parent = Dialog.Root,
    }, { New("UICorner", { CornerRadius = UDim.new(0,4) }), New("UIStroke", { Thickness = 2, Transparency = 0.75 }), DialogDisplayFrame })
    local SequenceTable = {}
    for Color = 0, 1, 0.1 do table.insert(SequenceTable, ColorSequenceKeypoint.new(Color, Color3.fromHSV(Color, 1, 1))) end
    local HueDragHolder = New("Frame", { Size = UDim2.new(1,0,1,-10), Position = UDim2.fromOffset(0,5), BackgroundTransparency = 1 })
    local HueDrag = New("ImageLabel", {
      Size = UDim2.fromOffset(14,14), Image = "http://www.roblox.com/asset/?id=12266946128", Parent = HueDragHolder,
      ThemeTag = { ImageColor3 = "DialogInput" },
    })
    local HueSlider = New("Frame", {
      Size = UDim2.fromOffset(12,190), Position = UDim2.fromOffset(210,55), Parent = Dialog.Root,
    }, { New("UICorner", { CornerRadius = UDim.new(1,0) }), New("UIGradient", { Color = ColorSequence.new(SequenceTable), Rotation = 90 }), HueDragHolder })
    local xOff = cfg.Transparency and 260 or 240
    local lOff = cfg.Transparency and 360 or 340
    local HexInput = CreateCPInput()
    HexInput.Frame.Position = UDim2.fromOffset(xOff, 55)
    CreateInputLabel("Hex", UDim2.fromOffset(lOff, 55))
    local RedInput = CreateCPInput()
    RedInput.Frame.Position = UDim2.fromOffset(xOff, 95)
    CreateInputLabel("Red", UDim2.fromOffset(lOff, 95))
    local GreenInput = CreateCPInput()
    GreenInput.Frame.Position = UDim2.fromOffset(xOff, 135)
    CreateInputLabel("Green", UDim2.fromOffset(lOff, 135))
    local BlueInput = CreateCPInput()
    BlueInput.Frame.Position = UDim2.fromOffset(xOff, 175)
    CreateInputLabel("Blue", UDim2.fromOffset(lOff, 175))
    local AlphaInput
    if cfg.Transparency then
      AlphaInput = CreateCPInput()
      AlphaInput.Frame.Position = UDim2.fromOffset(260, 215)
      CreateInputLabel("Alpha", UDim2.fromOffset(360, 215))
    end
    local TransparencySlider, TransparencyDrag, TransparencyColor
    if cfg.Transparency then
      local TDragHolder = New("Frame", { Size = UDim2.new(1,0,1,-10), Position = UDim2.fromOffset(0,5), BackgroundTransparency = 1 })
      TransparencyDrag = New("ImageLabel", {
        Size = UDim2.fromOffset(14,14), Image = "http://www.roblox.com/asset/?id=12266946128", Parent = TDragHolder,
        ThemeTag = { ImageColor3 = "DialogInput" },
      })
      TransparencyColor = New("Frame", { Size = UDim2.fromScale(1,1) }, {
        New("UIGradient", { Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0,0), NumberSequenceKeypoint.new(1,1) }), Rotation = 270 }),
        New("UICorner", { CornerRadius = UDim.new(1,0) }),
      })
      TransparencySlider = New("Frame", {
        Size = UDim2.fromOffset(12,190), Position = UDim2.fromOffset(230,55), Parent = Dialog.Root, BackgroundTransparency = 1,
      }, {
        New("UICorner", { CornerRadius = UDim.new(1,0) }),
        New("ImageLabel", { Image = "http://www.roblox.com/asset/?id=14204231522", ImageTransparency = 0.45, ScaleType = Enum.ScaleType.Tile, TileSize = UDim2.fromOffset(40,40), BackgroundTransparency = 1, Size = UDim2.fromScale(1,1) }, { New("UICorner", { CornerRadius = UDim.new(1,0) }) }),
        TransparencyColor, TDragHolder,
      })
    end
    local function CPDisplay()
      SatVibMap.BackgroundColor3 = Color3.fromHSV(Hue, 1, 1)
      HueDrag.Position = UDim2.new(0, -1, Hue, -6)
      SatCursor.Position = UDim2.new(Sat, 0, 1 - Vib, 0)
      DialogDisplayFrame.BackgroundColor3 = Color3.fromHSV(Hue, Sat, Vib)
      HexInput.Input.Text = "#" .. Color3.fromHSV(Hue, Sat, Vib):ToHex()
      RedInput.Input.Text = GetRGB()["R"]
      GreenInput.Input.Text = GetRGB()["G"]
      BlueInput.Input.Text = GetRGB()["B"]
      if cfg.Transparency then
        TransparencyColor.BackgroundColor3 = Color3.fromHSV(Hue, Sat, Vib)
        DialogDisplayFrame.BackgroundTransparency = Transp
        TransparencyDrag.Position = UDim2.new(0, -1, 1 - Transp, -6)
        AlphaInput.Input.Text = getLibrary():Round((1 - Transp) * 100, 0) .. "%"
      end
    end
    Creator.AddSignal(HexInput.Input.FocusLost, function(Enter)
      if Enter then
        local ok, res = pcall(Color3.fromHex, HexInput.Input.Text)
        if ok and typeof(res) == "Color3" then Hue, Sat, Vib = Color3.toHSV(res) end
      end
      CPDisplay()
    end)
    Creator.AddSignal(RedInput.Input.FocusLost, function(Enter)
      if Enter then
        local c = GetRGB()
        local ok, res = pcall(Color3.fromRGB, RedInput.Input.Text, c["G"], c["B"])
        if ok and typeof(res) == "Color3" and tonumber(RedInput.Input.Text) and tonumber(RedInput.Input.Text) <= 255 then
          Hue, Sat, Vib = Color3.toHSV(res)
        end
      end
      CPDisplay()
    end)
    Creator.AddSignal(GreenInput.Input.FocusLost, function(Enter)
      if Enter then
        local c = GetRGB()
        local ok, res = pcall(Color3.fromRGB, c["R"], GreenInput.Input.Text, c["B"])
        if ok and typeof(res) == "Color3" and tonumber(GreenInput.Input.Text) and tonumber(GreenInput.Input.Text) <= 255 then
          Hue, Sat, Vib = Color3.toHSV(res)
        end
      end
      CPDisplay()
    end)
    Creator.AddSignal(BlueInput.Input.FocusLost, function(Enter)
      if Enter then
        local c = GetRGB()
        local ok, res = pcall(Color3.fromRGB, c["R"], c["G"], BlueInput.Input.Text)
        if ok and typeof(res) == "Color3" and tonumber(BlueInput.Input.Text) and tonumber(BlueInput.Input.Text) <= 255 then
          Hue, Sat, Vib = Color3.toHSV(res)
        end
      end
      CPDisplay()
    end)
    if cfg.Transparency then
      Creator.AddSignal(AlphaInput.Input.FocusLost, function(Enter)
        if Enter then
          pcall(function()
            local val = tonumber(AlphaInput.Input.Text)
            if val and val >= 0 and val <= 100 then Transp = 1 - val * 0.01 end
          end)
        end
        CPDisplay()
      end)
    end
    Creator.AddSignal(SatVibMap.InputBegan, function(Input)
      if Input.UserInputType == Enum.UserInputType.MouseButton1 or Input.UserInputType == Enum.UserInputType.Touch then
        while UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) do
          local MinX, MaxX = SatVibMap.AbsolutePosition.X, SatVibMap.AbsolutePosition.X + SatVibMap.AbsoluteSize.X
          local MinY, MaxY = SatVibMap.AbsolutePosition.Y, SatVibMap.AbsolutePosition.Y + SatVibMap.AbsoluteSize.Y
          Sat = (math.clamp(Mouse.X, MinX, MaxX) - MinX) / (MaxX - MinX)
          Vib = 1 - ((math.clamp(Mouse.Y, MinY, MaxY) - MinY) / (MaxY - MinY))
          CPDisplay()
          RenderStepped:Wait()
        end
      end
    end)
    Creator.AddSignal(HueSlider.InputBegan, function(Input)
      if Input.UserInputType == Enum.UserInputType.MouseButton1 or Input.UserInputType == Enum.UserInputType.Touch then
        while UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) do
          local MinY, MaxY = HueSlider.AbsolutePosition.Y, HueSlider.AbsolutePosition.Y + HueSlider.AbsoluteSize.Y
          Hue = (math.clamp(Mouse.Y, MinY, MaxY) - MinY) / (MaxY - MinY)
          CPDisplay()
          RenderStepped:Wait()
        end
      end
    end)
    if cfg.Transparency then
      Creator.AddSignal(TransparencySlider.InputBegan, function(Input)
        if Input.UserInputType == Enum.UserInputType.MouseButton1 then
          while UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) do
            local MinY, MaxY = TransparencySlider.AbsolutePosition.Y, TransparencySlider.AbsolutePosition.Y + TransparencySlider.AbsoluteSize.Y
            Transp = 1 - ((math.clamp(Mouse.Y, MinY, MaxY) - MinY) / (MaxY - MinY))
            CPDisplay()
            RenderStepped:Wait()
          end
        end
      end)
    end
    CPDisplay()
    Dialog:Button("Done", function() Colorpicker:SetValue({ Hue, Sat, Vib }, Transp) end)
    Dialog:Button("Cancel")
    Dialog:Open()
  end
  function Colorpicker:Display()
    Colorpicker.Value = Color3.fromHSV(Colorpicker.Hue, Colorpicker.Sat, Colorpicker.Vib)
    DisplayFrameColor.BackgroundColor3 = Colorpicker.Value
    DisplayFrameColor.BackgroundTransparency = Colorpicker.Transparency
    Library:SafeCallback(Colorpicker.Callback, Colorpicker.Value)
    Library:SafeCallback(Colorpicker.Changed, Colorpicker.Value)
  end
  function Colorpicker:SetValue(HSV, TranspVal)
    local Color = Color3.fromHSV(HSV[1], HSV[2], HSV[3])
    Colorpicker.Transparency = TranspVal or 0
    Colorpicker:SetHSVFromRGB(Color)
    Colorpicker:Display()
  end
  function Colorpicker:SetValueRGB(Color, TranspVal)
    Colorpicker.Transparency = TranspVal or 0
    Colorpicker:SetHSVFromRGB(Color)
    Colorpicker:Display()
  end
  function Colorpicker:OnChanged(Func) Colorpicker.Changed = Func Func(Colorpicker.Value) end
  function Colorpicker:Destroy() ColorpickerFrame:Destroy() Library.Options[idx] = nil end
  Creator.AddSignal(ColorpickerFrame.Frame.MouseButton1Click, function() CreateColorDialog() end)
  Colorpicker:Display()
  Library.Options[idx] = Colorpicker
  return Colorpicker
end
Elements.AddColorpicker = AddColorpicker

-- ============ SaveManager ============
local SaveManager = { Folder = "FluentSettings", IgnoreThemeSettings = {} }
SaveManager.Parser = { encode = function(t) return game:GetService("HttpService"):JSONEncode(t) end, decode = function(s) return game:GetService("HttpService"):JSONDecode(s) end }

do
  local hasFS = pcall(function() return readfile and writefile and isfolder and makefolder and listfiles end)
  if not hasFS then
    function SaveManager:SetFolder() end
    function SaveManager:SetIgnoreIndexes() end
    function SaveManager:Save() end
    function SaveManager:Load() end
    function SaveManager:Delete() end
    function SaveManager:GetSaves() return {} end
    function SaveManager:BuildSaveSection() end
    function SaveManager:LoadAutoloadConfig() end
    function SaveManager:SetLibrary() end
  else
    function SaveManager:SetFolder(folder)
      self.Folder = folder
      if not isfolder(folder) then makefolder(folder) end
    end

    function SaveManager:SetIgnoreIndexes(list)
      for _, key in next, list do self.IgnoreThemeSettings[key] = true end
    end

    function SaveManager:Save(name)
      local data = {}
      for idx, option in next, Library.Options do
        if not self.IgnoreThemeSettings[idx] and option.Type then
          if option.Type == "Toggle" then data[idx] = { type = "Toggle", value = option.Value }
          elseif option.Type == "Slider" then data[idx] = { type = "Slider", value = option.Value }
          elseif option.Type == "Input" then data[idx] = { type = "Input", value = option.Value }
          elseif option.Type == "Keybind" then data[idx] = { type = "Keybind", value = option.Value, mode = option.Mode }
          elseif option.Type == "Dropdown" then data[idx] = { type = "Dropdown", value = option.Value, multi = option.Multi }
          elseif option.Type == "Colorpicker" then
            data[idx] = { type = "Colorpicker", value = { option.Hue, option.Sat, option.Vib }, transparency = option.Transparency }
          end
        end
      end
      local path = self.Folder .. "/" .. name .. ".json"
      writefile(path, self.Parser.encode(data))
    end

    function SaveManager:Load(name)
      local path = self.Folder .. "/" .. name .. ".json"
      if not isfile(path) then Library:Notify({ Title = "Config", Content = "Config not found: " .. name, Duration = 3 }) return end
      local ok, data = pcall(function() return self.Parser.decode(readfile(path)) end)
      if not ok then Library:Notify({ Title = "Config", Content = "Failed to load config.", Duration = 3 }) return end
      for idx, entry in next, data do
        local option = Library.Options[idx]
        if option then
          pcall(function()
            if entry.type == "Toggle" then option:SetValue(entry.value)
            elseif entry.type == "Slider" then option:SetValue(entry.value)
            elseif entry.type == "Input" then option:SetValue(entry.value)
            elseif entry.type == "Keybind" then option:SetValue(entry.value, entry.mode)
            elseif entry.type == "Dropdown" then option:SetValue(entry.value)
            elseif entry.type == "Colorpicker" then option:SetValue(entry.value, entry.transparency)
            end
          end)
        end
      end
      Library:Notify({ Title = "Config", Content = "Loaded: " .. name, Duration = 3 })
    end

    function SaveManager:Delete(name)
      local path = self.Folder .. "/" .. name .. ".json"
      if isfile(path) then delfile(path) Library:Notify({ Title = "Config", Content = "Deleted: " .. name, Duration = 3 }) end
    end

    function SaveManager:GetSaves()
      if not isfolder(self.Folder) then return {} end
      local list = {}
      for _, f in next, listfiles(self.Folder) do
        if f:sub(-5) == ".json" then
          local name = f:match("([^/\\]+)%.json$")
          if name then table.insert(list, name) end
        end
      end
      return list
    end

    function SaveManager:LoadAutoloadConfig()
      local path = self.Folder .. "/_autoload.txt"
      if isfile(path) then
        local name = readfile(path):match("^%s*(.-)%s*$")
        if name and name ~= "" then self:Load(name) end
      end
    end

    function SaveManager:SetLibrary(lib)
      Library = lib or Library
    end

    function SaveManager:BuildSaveSection(tab)
      assert(tab, "SaveManager:BuildSaveSection - Missing tab")
      local sec = tab:AddSection("Configuration")

      sec:AddInput("sm_name", { Title = "Config Name", Placeholder = "my_config", Default = "" })
      sec:AddDropdown("sm_list", { Title = "Config List", Values = self:GetSaves(), Default = nil, AllowNull = true })

      sec:AddButton("sm_save", { Title = "Save Config", Description = "Save current settings", Callback = function()
        local name = Library.Options["sm_name"] and Library.Options["sm_name"].Value or ""
        if name == "" then Library:Notify({ Title = "Config", Content = "Enter a name first.", Duration = 3 }) return end
        self:Save(name)
        Library:Notify({ Title = "Config", Content = "Saved: " .. name, Duration = 3 })
        Library.Options["sm_list"]:SetValues(self:GetSaves())
      end })

      sec:AddButton("sm_load", { Title = "Load Config", Description = "Load selected config", Callback = function()
        local sel = Library.Options["sm_list"] and Library.Options["sm_list"].Value
        if not sel or sel == "" then Library:Notify({ Title = "Config", Content = "Select a config first.", Duration = 3 }) return end
        self:Load(sel)
      end })

      sec:AddButton("sm_delete", { Title = "Delete Config", Description = "Delete selected config", Callback = function()
        local sel = Library.Options["sm_list"] and Library.Options["sm_list"].Value
        if not sel or sel == "" then return end
        self:Delete(sel)
        Library.Options["sm_list"]:SetValues(self:GetSaves())
      end })

      sec:AddButton("sm_refresh", { Title = "Refresh List", Callback = function()
        Library.Options["sm_list"]:SetValues(self:GetSaves())
      end })

      sec:AddToggle("sm_autoload", { Title = "Auto-load on start", Default = false, Callback = function(v)
        if v then
          local name = Library.Options["sm_list"] and Library.Options["sm_list"].Value
          if name and name ~= "" then
            writefile(self.Folder .. "/_autoload.txt", name)
            Library:Notify({ Title = "Config", Content = "Auto-load set to: " .. name, Duration = 3 })
          end
        else
          pcall(function() if isfile(self.Folder .. "/_autoload.txt") then delfile(self.Folder .. "/_autoload.txt") end end)
        end
      end })
    end
  end
end
Library.SaveManager = SaveManager

-- ============ InterfaceManager ============
local InterfaceManager = {}

function InterfaceManager:SetFolder(folder)
  self.Folder = folder
  pcall(function() if not isfolder(folder) then makefolder(folder) end end)
end

function InterfaceManager:SetLibrary(lib) Library = lib or Library end

function InterfaceManager:BuildInterfaceSection(tab)
  assert(tab, "InterfaceManager:BuildInterfaceSection - Missing tab")
  local sec = tab:AddSection("Interface")

  sec:AddDropdown("if_theme", {
    Title = "Theme",
    Description = "Select a visual theme",
    Values = Library.Themes,
    Default = Library.Theme,
    Callback = function(v) Library:SetTheme(v) end,
  })

  sec:AddToggle("if_acrylic", {
    Title = "Acrylic Blur",
    Description = "Enable background blur effect",
    Default = Library.Acrylic or false,
    Callback = function(v) Library:ToggleAcrylic(v) end,
  })

  sec:AddToggle("if_transparency", {
    Title = "Transparency",
    Description = "Enable background transparency",
    Default = Library.Transparency or true,
    Callback = function(v) Library:ToggleTransparency(v) end,
  })

  sec:AddKeybind("if_minkey", {
    Title = "Minimize Key",
    Description = "Keybind to toggle window",
    Default = Library.MinimizeKey and Library.MinimizeKey.Name or "LeftControl",
    Callback = function() end,
    ChangedCallback = function(key)
      Library.MinimizeKeybind = Library.Options["if_minkey"]
    end,
  })
end

Library.InterfaceManager = InterfaceManager

if getgenv then
  getgenv().Fluent = Library
end

return Library
