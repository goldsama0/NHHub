--[[ NHHub core - the shared half of every NHHub script.

     Nothing in here knows about any particular game. A game module gets this table handed to it by
     the loader and uses the four things it cannot sensibly duplicate:

         local core = ...                     -- passed in by loader.luau
         core.cleanup()                       -- kill GUIs left by a previous run
         local WindUI = core.windui()         -- one library instance, shared
         local window = WindUI:CreateWindow({ Folder = core.folder("HotEgg"), ... })
         core.polish(window)                  -- solid plate + readable title
         core.attachButton(window, { key = keyCode })

     Run standalone (no loader) and a module fetches this file itself - see games/hotegg.luau.
]]

local core = {}

core.VERSION = "1.0"
core.WINDUI_URL = "https://github.com/Footagesus/WindUI/releases/latest/download/main.lua"

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local LocalPlayer = Players.LocalPlayer

local function guiRoots()
    local list = {}
    local ok, hidden = pcall(gethui)
    if ok and hidden then table.insert(list, hidden) end
    local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
    if playerGui then table.insert(list, playerGui) end
    return list
end

--[[ Each run of a script loads its own copy of WindUI, and every copy builds a fresh ScreenGui.
     Re-executing leaves the previous copy standing, so without this every run stacks another full
     window and another button. Must run BEFORE the library is loaded, otherwise the new copy finds
     the old ScreenGui and builds on top of something it does not own. ]]
function core.cleanup()
    for _, root in ipairs(guiRoots()) do
        for _, child in ipairs(root:GetChildren()) do
            local name = child.Name
            if child:IsA("ScreenGui")
                and (name == "NHHubReopen" or name == "HotEggReopen"
                    or name == "WindUI" or string.sub(name, 1, 7) == "WindUI/") then
                child:Destroy()
            end
        end
    end
end

local windui

--[[ cleanup() deletes the library's ScreenGui, but a cached WindUI object still points at it, and
     CreateWindow then fails with "Window is not a valid member of ScreenGui WindUI". So the cache
     is only trusted while that ScreenGui is still standing. ]]
local function winduiAlive()
    for _, root in ipairs(guiRoots()) do
        if root:FindFirstChild("WindUI") then return true end
    end
    return false
end

function core.windui()
    if windui and not winduiAlive() then
        windui = nil
    end
    if not windui then
        windui = loadstring(game:HttpGet(core.WINDUI_URL))()
    end
    return windui
end

-- core.notify("done") or core.notify({ Title = "X", Content = "Y", Icon = "egg" })
function core.notify(opts)
    if type(opts) == "string" then opts = { Content = opts } end
    opts = opts or {}
    opts.Title = opts.Title or "NHHub"
    opts.Duration = opts.Duration or 5
    pcall(function() core.windui():Notify(opts) end)
end

-- Keep each game's saved config apart: "NHHub-HotEgg" and "NHHub-Other" never share a file.
function core.folder(gameName)
    return "NHHub-" .. tostring(gameName)
end

function core.findFrame()
    for _, root in ipairs(guiRoots()) do
        local win = root:FindFirstChild("WindUI")
        local windowFolder = win and win:FindFirstChild("Window")
        local frame = windowFolder and windowFolder:FindFirstChild("Frame")
        if frame then return frame end
    end
    return nil
end

--[[ Two things the library will not do for us.

     First, the theme's window plate is a sliced image at 85% opacity, so a bright map shows straight
     through the menu. Paint an opaque panel just above the plate and below the contents (Main sits
     at ZIndex 97).

     Second, the title is drawn at a fixed small size with no option to change it, and its holder is
     sized to that small text - so widen the holder as well or the name is clipped.

     Retried because CreateWindow builds the topbar asynchronously. It has to survive the window
     being opened and closed repeatedly, hence the named guard nodes. ]]
function core.polish(window, opts)
    opts = opts or {}
    local titleSize = opts.titleSize or 28

    local function apply()
        local frame = core.findFrame()
        if not frame then return false end

        local plate = frame:FindFirstChild("Background")
        if plate and plate:IsA("ImageLabel") and not frame:FindFirstChild("NHHubFill") then
            local fill = Instance.new("Frame")
            fill.Name = "NHHubFill"
            fill.Size = plate.Size
            fill.Position = plate.Position
            fill.AnchorPoint = plate.AnchorPoint
            fill.BackgroundColor3 = opts.colour or Color3.fromRGB(16, 16, 21)
            fill.BackgroundTransparency = 0
            fill.BorderSizePixel = 0
            fill.ZIndex = 2
            fill.Active = false

            local corner = Instance.new("UICorner")
            corner.CornerRadius = UDim.new(0, 12)
            corner.Parent = fill

            local stroke = Instance.new("UIStroke")
            stroke.Color = Color3.fromRGB(46, 46, 60)
            stroke.Thickness = 1
            stroke.Transparency = 0.25
            stroke.Parent = fill

            fill.Parent = frame
        end

        local main = frame:FindFirstChild("Main")
        local topbar = main and main:FindFirstChild("Topbar")
        local left = topbar and topbar:FindFirstChild("Left")
        local holder = left and left:FindFirstChild("Title")
        local label = holder and holder:FindFirstChildWhichIsA("TextLabel")

        if label then
            label.TextSize = titleSize
            label.TextYAlignment = Enum.TextYAlignment.Center
            holder.Size = UDim2.fromOffset(titleSize * 5.4, titleSize)
            left.Size = UDim2.fromOffset(titleSize * 6.6, titleSize)
        end

        return true
    end

    if apply() then
        task.spawn(function()
            task.wait(0.35)
            pcall(apply)
        end)
        return
    end

    task.spawn(function()
        for _ = 1, 25 do
            if apply() then return end
            task.wait(0.1)
        end
    end)
end

--[[ The always-visible button, because closing the window can leave the hotkey unreachable.
     Also wires the hotkey, which is why every game gets the same open/close behaviour. ]]
function core.attachButton(window, opts)
    opts = opts or {}
    local key = opts.key

    local gui = Instance.new("ScreenGui")
    gui.Name = "NHHubReopen"
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true
    pcall(function() gui.Parent = gethui() end)
    if not gui.Parent then gui.Parent = LocalPlayer:WaitForChild("PlayerGui") end

    local btn = Instance.new("TextButton")
    btn.Name = "Button"
    btn.Size = UDim2.fromOffset(84, 26)
    btn.Position = UDim2.new(1, -94, 0, 8)
    btn.BackgroundColor3 = opts.background or Color3.fromRGB(24, 20, 38)
    btn.TextColor3 = opts.textColour or Color3.fromRGB(237, 233, 254)
    btn.Font = Enum.Font.GothamBold
    btn.TextSize = 13
    btn.Text = opts.text or "NHHub"
    btn.AutoButtonColor = true
    btn.Parent = gui

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 6)
    corner.Parent = btn

    local stroke = Instance.new("UIStroke")
    stroke.Color = opts.accent or Color3.fromRGB(139, 92, 246)
    stroke.Parent = btn

    local function toggle()
        local ok = pcall(function() window:Toggle() end)
        if not ok then pcall(function() window:Open() end) end
    end

    btn.MouseButton1Click:Connect(toggle)

    if key then
        UserInputService.InputBegan:Connect(function(input, processed)
            if processed then return end
            if input.KeyCode == key then toggle() end
        end)
        pcall(function() window:SetToggleKey(key) end)
    end

    return btn, gui
end

return core
