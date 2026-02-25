# Fluent Renew

Fluent UI for Roblox. **Created for personal use** — use at your own discretion.

---

## Load

```lua
local Fluent = loadstring(game:HttpGet("https://raw.githubusercontent.com/tmuseAI/fl-/refs/heads/main/fl.luau"))()
local SaveManager = Fluent.SaveManager
local InterfaceManager = Fluent.InterfaceManager
```

---

## Create window

```lua
SaveManager:SetFolder("MyApp")

local Window = Fluent:CreateWindow({
  Title = "My App",
  SubTitle = "v1.0",
  Size = UDim2.fromOffset(560, 380),
  TabWidth = 160,
  Theme = "Dark",   -- Dark, Darker, Light, Aqua, Amethyst, Rose, Neon, Ocean, Sunset
  Acrylic = false,
  ShadowTransparency = 0.4,
  GradientTransparency = 0.92,
  BorderTransparency = 0.75,
  SelectorColor = Color3.fromRGB(60, 60, 70),
})
```

---

## Commands

**Tabs & sections**

- `Window:AddTab({ Title = "...", Icon = "home" })`
- `Tab:AddSection("Section Title")`

**Elements (on Tab or Section)**

- `Sec:AddButton(id, { Title = "...", Callback = function() end })`
- `Sec:AddToggle(id, { Title = "...", Default = false, Callback = function(v) end })`
- `Sec:AddSlider(id, { Title = "...", Default = 50, Min = 0, Max = 100, Rounding = 0, Callback = function(v) end })`
- `Sec:AddInput(id, { Title = "...", Placeholder = "...", Callback = function(v) end })`
- `Sec:AddKeybind(id, { Title = "...", Default = "Q", Mode = "Toggle", Callback = function(v) end })`
- `Sec:AddParagraph(id, { Title = "...", Content = "..." })`
- `Sec:AddDropdown(id, { Title = "...", Values = {"A","B"}, Default = "A", Callback = function(v) end })`
- `Sec:AddDropdown(id, { Title = "...", Values = {"X","Y"}, Multi = true, Default = {"X"}, Callback = function(v) end })`
- `Sec:AddColorpicker(id, { Title = "...", Default = Color3.fromRGB(255,0,0), Callback = function(v) end })`

**Window**

- `Window:SelectTab(tabIndex)`
- `Window:Minimize()`
- `Window:Maximize(bool)`
- `Window:Dialog({ Title = "...", Content = "...", Buttons = {...} })`
- `Window:SetSelectorColor(color)`
- `Window:SetFrameTransparency(shadow, gradient, border)`
- `Window:Destroy()`

**Library**

- `Fluent:SetTheme("Dark")`
- `Fluent:Notify({ Title = "...", Content = "...", Duration = 3 })`
- `Fluent:Destroy()`
- `Fluent:ToggleAcrylic(bool)`
- `Fluent:ToggleTransparency(bool)`
- `Fluent:GetIcon(name)`

**SaveManager**

- `SaveManager:SetFolder(name)`
- `SaveManager:Save(name)` / `SaveManager:Load(name)` / `SaveManager:Delete(name)`
- `SaveManager:GetSaves()`
- `SaveManager:LoadAutoloadConfig()`
- `SaveManager:BuildSaveSection(tab)`

**InterfaceManager**

- `InterfaceManager:BuildInterfaceSection(tab)`

---

## Files

- `fluent_renew.lua` — library
- `example.lua` — full demo
