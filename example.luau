local Fluent = loadstring(game:HttpGet("https://raw.githubusercontent.com/tmuseAI/fl-/refs/heads/main/fl.luau"))()
local SaveManager = Fluent.SaveManager
local InterfaceManager = Fluent.InterfaceManager

SaveManager:SetFolder("FluentRenew_Configs")

local Window = Fluent:CreateWindow({
  Title = "Fluent Renew",
  SubTitle = "tmuse",
  Size = UDim2.fromOffset(580, 420),
  TabWidth = 160,
  Theme = "Dark",
  Acrylic = false,
  SelectorColor = Color3.fromRGB(60, 60, 70),
  ShadowTransparency = 0.4,
  GradientTransparency = 0.92,
  BorderTransparency = 0.75,
})

local Tab1 = Window:AddTab({ Title = "Main", Icon = "home" })
local Sec1 = Tab1:AddSection("Controls")

Sec1:AddButton("btn1", {
  Title = "Test Button",
  Description = "Click to notify",
  Callback = function()
    Fluent:Notify({ Title = "Button", Content = "Clicked!", Duration = 3 })
  end,
})

Sec1:AddToggle("t1", {
  Title = "Enable Feature",
  Description = "Toggle",
  Default = false,
  Callback = function(v) end,
})

Sec1:AddSlider("s1", {
  Title = "Speed",
  Default = 50,
  Min = 0,
  Max = 100,
  Rounding = 0,
  Callback = function(v) end,
})

Sec1:AddInput("i1", {
  Title = "Player Name",
  Placeholder = "Type here...",
  Callback = function(v) end,
})

Sec1:AddInput("i2", {
  Title = "Numeric",
  Placeholder = "0",
  Numeric = true,
  Callback = function(v) end,
})

Sec1:AddKeybind("k1", {
  Title = "Activation Key",
  Default = "Q",
  Mode = "Toggle",
  Callback = function(v) end,
})

Sec1:AddParagraph("p1", {
  Title = "Info",
  Content = "Fluent Renew API example, search filters current tab",
})

local Tab2 = Window:AddTab({ Title = "Selectors", Icon = "list" })
local Sec2 = Tab2:AddSection("Dropdown & Color")

Sec2:AddDropdown("d1", {
  Title = "Mode",
  Values = { "Mode A", "Mode B", "Mode C" },
  Default = "Mode A",
  Callback = function(v) end,
})

Sec2:AddDropdown("d2", {
  Title = "Multi Select",
  Values = { "ESP", "Aimbot", "Speed", "Fly" },
  Multi = true,
  Default = { "ESP" },
  Callback = function(v) end,
})

Sec2:AddColorpicker("c1", {
  Title = "Highlight Color",
  Default = Color3.fromRGB(96, 205, 255),
  Callback = function(v) end,
})

Sec2:AddColorpicker("c2", {
  Title = "Color + Alpha",
  Default = Color3.fromRGB(96, 205, 255),
  Transparency = 0.2,
  Callback = function(v) end,
})

local Tab3 = Window:AddTab({ Title = "Themes", Icon = "palette" })
local Sec3 = Tab3:AddSection("Theme & Frame")

Sec3:AddDropdown("theme_sel", {
  Title = "Theme",
  Values = Fluent.Themes,
  Default = "Dark",
  Callback = function(v)
    Fluent:SetTheme(v)
    Fluent:Notify({ Title = "Theme", Content = v, Duration = 2 })
  end,
})

Sec3:AddColorpicker("sel_color", {
  Title = "Selector Color",
  Default = Color3.fromRGB(60, 60, 70),
  Callback = function(v) Window:SetSelectorColor(v) end,
})

Sec3:AddButton("frame_more", {
  Title = "Frame more transparent",
  Callback = function()
    Window:SetFrameTransparency(0.6, 0.98, 0.9)
  end,
})

Sec3:AddButton("frame_less", {
  Title = "Frame less transparent",
  Callback = function()
    Window:SetFrameTransparency(0.4, 0.92, 0.75)
  end,
})

Sec3:AddButton("btn_dialog", {
  Title = "Open Dialog",
  Callback = function()
    Window:Dialog({
      Title = "Dialog",
      Content = "Dialog content.",
      Buttons = {
        { Title = "OK", Callback = function() end },
        { Title = "Cancel", Callback = function() end },
      },
    })
  end,
})

Sec3:AddButton("minimize", {
  Title = "Minimize Window",
  Callback = function()
    Window:Minimize()
  end,
})

Sec3:AddButton("maximize", {
  Title = "Maximize Window",
  Callback = function()
    Window:Maximize(not Window.Maximized)
  end,
})

local Tab4 = Window:AddTab({ Title = "Settings", Icon = "settings" })
InterfaceManager:BuildInterfaceSection(Tab4)
SaveManager:BuildSaveSection(Tab4)

Window:SelectTab(1)
SaveManager:LoadAutoloadConfig()

Fluent:Notify({
  Title = "Fluent Renew",
  Content = "Loaded, all API in example",
  SubContent = "CreateWindow, AddTab, AddSection, AddButton, AddToggle, AddSlider, AddInput, AddKeybind, AddParagraph, AddDropdown, AddColorpicker, Dialog, SetTheme, SetSelectorColor, SetFrameTransparency, Minimize, Maximize, Notify, SaveManager, InterfaceManager",
  Duration = 6,
})

local _ = Fluent:GetIcon("home")
