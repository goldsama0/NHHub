--[[ NHHub - UGC module

     Place 107778070777162. Shared plumbing comes from core.luau; the loader passes it in as the
     first argument. Running this file on its own still works - it fetches core itself.

     How this game is wired (verified live, see remember-game):
       - every remote lives directly under ReplicatedStorage.Packages.Networking, with the folder
         part baked into the name: "RE/PetSatchel/SellEveryPet", "RF/EggWorld/AskHatch", ...
       - hatching is AskHatch(eggUid) then AskFinishHatch(eggUid)
       - selling is SellEveryPet(formattedUids) - the NPC prompt only computes the list
       - most world actions are ProximityPrompts ("Open", "CLAIM!", "Claim Net", "Apply Mutation",
         "Steal", "Fuse Pets"), not remotes
       - Save.Await() is the client profile: .Cash, .Inventory, .EquippedAssets
]]

-- The loader puts the core table in getgenv() before running a game module. The vararg form
-- (local core = ...) is avoided because some harnesses compile the file as a plain function,
-- where "..." is a syntax error.
local env = getgenv and getgenv() or _G
local core = env.NHHubCore

if not core then
    local base = "https://raw.githubusercontent.com/goldsama0/NHHub/main/"
    -- NHHubCoreURL overrides where core is fetched from; used for testing a build before it is
    -- pushed to the repo.
    local url = (env.NHHubCoreURL or (base .. "core.lua")) .. "?v=" .. tostring(os.time())
    core = loadstring(game:HttpGet(url))()
    env.NHHubCore = core
end

core.cleanup()

local WindUI = core.windui()

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LocalPlayer = Players.LocalPlayer

local S = {
    -- prompts
    promptsOn = false,
    promptRoam = false,
    promptDistance = 60,
    promptCooldown = 0.35,
    promptTeleport = false,
    catClaim = true,
    catOpen = true,
    catSell = false,
    catMutate = false,
    catSteal = false,
    catFuse = false,
    -- eggs
    autoHatch = false,
    hatchDelay = 0.6,
    autoFinish = true,
    -- pets
    autoSell = false,
    sellDelay = 5,
    keepEquipped = true,
    autoWearBest = false,
    -- events
    autoCollect = false,
    autoRedeem = false,
    -- esp
    espOn = false,
    espPlayers = true,
    espPrompts = true,
    -- misc
    toggleKey = Enum.KeyCode.RightShift,
    legitSpeed = true,
}

local dbg = { promptsFired = 0, hatches = 0, sells = 0, collects = 0, errors = 0, longHops = 0, notReady = 0 }

-- ===== remotes =====
local Networking = ReplicatedStorage:WaitForChild("Packages", 15)
Networking = Networking and Networking:WaitForChild("Networking", 15)

local function remote(name)
    if not Networking then return nil end
    local r = Networking:FindFirstChild(name)
    if r and (r:IsA("RemoteEvent") or r:IsA("RemoteFunction")) then return r end
    return nil
end

local R = {
    sellEveryPet = remote("RE/PetSatchel/SellEveryPet"),
    sellPet = remote("RE/PetSatchel/SellPet"),
    wearBest = remote("RF/Haul/WearBest"),
    hatch = remote("RF/EggWorld/AskHatch"),
    finishHatch = remote("RF/EggWorld/AskFinishHatch"),
    skipGrowth = remote("RF/EggWorld/AskSkipGrowth"),
    redeemAll = remote("RF/Codex/AskRedeemAll"),
    lvdRing = remote("RE/LightVsDarkness/AskCollectRing"),
    lvdPower = remote("RE/LightVsDarkness/AskCollectPowerUp"),
    scrambleCollect = remote("RE/Scramble/Collect"),
    sammyCollect = remote("RE/SammyEvent/AskCollectPickup"),
    chestClaim = remote("RF/MonsterParasite/AskChestClaim"),
    chestTake = remote("RF/MonsterParasite/AskChestTake"),
    stealEgg = remote("RE/BeanstalkEvent/AskStealEgg"),
    beanReward = remote("RE/BeanstalkEvent/AskClaimReward"),
}

local function call(fn, ...)
    if not fn then return nil end
    local ok, a, b, c = pcall(fn.InvokeServer or fn.FireServer, fn, ...)
    if not ok then dbg.errors = dbg.errors + 1 end
    return a, b, c
end

-- ===== client modules =====
local function safeRequire(instance)
    if not instance then return nil end
    local ok, module = pcall(require, instance)
    if ok and type(module) == "table" then return module end
    return nil
end

local cache = {}

-- Resolved lazily, not once at load: requiring these while the game is still replicating can fail,
-- and a module captured as nil at that moment would stay nil for the whole session.
local function module(containerName, name)
    local key = containerName .. "." .. name
    local hit = cache[key]
    if hit then return hit end
    local container = ReplicatedStorage:FindFirstChild(containerName)
    local inst = container and container:FindFirstChild(name)
    if not inst then return nil end
    local ok, m = pcall(require, inst)
    if ok and type(m) == "table" then
        cache[key] = m
        return m
    end
    return nil
end

local function profile()
    local Save = module("Shared", "Save")
    if not Save then return nil end
    local ok, p = pcall(function() return Save.Await() end)
    if ok and type(p) == "table" then return p end
    return nil
end

-- This game calls its currency "Money"; Cash is only a fallback in case that is renamed.
local function money(p)
    p = p or profile()
    if not p then return 0 end
    return p.Money or p.Cash or p.Coins or 0
end

local function myChar() return LocalPlayer.Character end
local function myHum()
    local c = myChar()
    return c and c:FindFirstChildOfClass("Humanoid") or nil
end
local function myHRP()
    local c = myChar()
    return c and c:FindFirstChild("HumanoidRootPart") or nil
end
local function alive()
    local h = myHum()
    return h ~= nil and h.Health > 0
end

-- ===== prompts =====
local CATEGORY = {
    ["CLAIM!"] = "claim",
    ["Claim Net"] = "claim",
    ["Claim"] = "claim",
    ["Open"] = "open",
    ["Sell All?"] = "sell",
    ["Sell this item?"] = "sell",
    ["Apply Mutation"] = "mutate",
    ["Steal"] = "steal",
    ["Fuse Pets"] = "fuse",
}

local function actionAllowed(text)
    local clean = string.gsub(text, "<[^>]+>", "")
    local cat = CATEGORY[clean]
    if cat == "claim" then return S.catClaim end
    if cat == "open" then return S.catOpen end
    if cat == "sell" then return S.catSell end
    if cat == "mutate" then return S.catMutate end
    if cat == "steal" then return S.catSteal end
    if cat == "fuse" then return S.catFuse end
    return false
end

local promptCooldowns = {}

local function promptPosition(prompt)
    local obj = prompt.Parent
    if obj and obj:IsA("BasePart") then return obj.Position end
    if obj and obj:IsA("Attachment") and obj.Parent and obj.Parent:IsA("BasePart") then
        return obj.WorldPosition
    end
    return nil
end

local function firePrompt(prompt)
    if fireproximityprompt then
        local ok = pcall(fireproximityprompt, prompt)
        if ok then return true end
    end
    local ok = pcall(function()
        prompt:InputHoldBegin()
        task.wait(0.08)
        prompt:InputHoldEnd()
    end)
    return ok
end

local roamState = { lastAt = 0, target = nil, stuck = 0 }

-- Distance on foot is not the point: most of this map's prompts sit 50-200 studs from wherever you
-- are standing, so a "range" that only covered arm's length made every toggle look broken.
local function collectPrompts(accept)
    local hrp = myHRP()
    if not hrp then return {} end
    local found = {}
    for _, prompt in ipairs(workspace:GetDescendants()) do
        if prompt:IsA("ProximityPrompt") then
            local pos = promptPosition(prompt)
            if pos then
                local dist = (pos - hrp.Position).Magnitude
                if accept(prompt, dist) then
                    table.insert(found, {
                        prompt = prompt,
                        pos = pos,
                        dist = dist,
                        enabled = prompt.Enabled,
                        action = (string.gsub(prompt.ActionText, "<[^>]+>", "")),
                    })
                end
            end
        end
    end
    -- Enabled first, then nearest. The Steal prompts only switch on once you are within 8 studs,
    -- so a disabled one still has to be a valid destination.
    table.sort(found, function(a, b)
        if a.enabled ~= b.enabled then return a.enabled end
        return a.dist < b.dist
    end)
    return found
end

local function teleportTo(pos)
    local hrp = myHRP()
    if not hrp or not pos then return false end
    local goal = Vector3.new(pos.X, pos.Y + 4, pos.Z)
    if (goal - hrp.Position).Magnitude > 300 then
        dbg.longHops = dbg.longHops + 1
    end
    -- The first write often gets overwritten by the move the client had in flight, so this checks
    -- the result instead of trusting the assignment and retries a couple of times.
    for _ = 1, 3 do
        pcall(function()
            hrp.CFrame = CFrame.lookAt(goal, goal + Vector3.new(0, 0, -1))
            hrp.AssemblyLinearVelocity = Vector3.zero
        end)
        task.wait(0.12)
        if (hrp.Position - goal).Magnitude < 12 then return true end
    end
    return false
end

local function promptLoop()
    if not S.promptsOn or not alive() then return end

    local now = os.clock()
    local list = collectPrompts(function(p) return actionAllowed(p.ActionText) end)
    if #list == 0 then return end

    if S.promptRoam then
        if now - roamState.lastAt < S.promptCooldown then return end

        local target
        for _, entry in ipairs(list) do
            if now >= (promptCooldowns[entry.prompt] or 0) then
                target = entry
                break
            end
        end
        if not target then return end

        roamState.lastAt = now
        roamState.target = target.action

        if target.dist > 5 and not teleportTo(target.pos) then
            roamState.stuck = roamState.stuck + 1
            promptCooldowns[target.prompt] = now + 4
            return
        end

        -- Smart prompts switch on once you are close, so a hold prompt like Steal has to be
        -- revisited instead of skipped for being disabled at a distance.
        task.wait(0.25)
        if not target.prompt.Enabled then
            dbg.notReady = dbg.notReady + 1
            promptCooldowns[target.prompt] = now + 5
            return
        end

        if firePrompt(target.prompt) then
            dbg.promptsFired = dbg.promptsFired + 1
            promptCooldowns[target.prompt] = now + S.promptCooldown
        else
            promptCooldowns[target.prompt] = now + 3
        end
        return
    end

    for _, entry in ipairs(list) do
        if entry.enabled and entry.dist <= S.promptDistance and now >= (promptCooldowns[entry.prompt] or 0) then
            promptCooldowns[entry.prompt] = now + S.promptCooldown
            if firePrompt(entry.prompt) then
                dbg.promptsFired = dbg.promptsFired + 1
            end
        end
    end
end

-- Nearest prompt of any enabled category, for the "Go to nearest" button and the status readout.
local function nearestPrompt(actionFilter)
    local list = collectPrompts(actionFilter)
    return list[1]
end

-- ===== eggs =====
local function ownedEggUids()
    local uids = {}
    local EggState = module("Client", "EggState")
    if not EggState then return uids end
    local ok, rows = pcall(function() return EggState.ReadOwnedEggs() end)
    if not ok or type(rows) ~= "table" then return uids end
    for _, row in ipairs(rows) do
        if type(row) == "table" then
            local mine = row.OwnerUserId == nil or row.OwnerUserId == LocalPlayer.UserId
            local records = row.Records
            if mine and type(records) == "table" then
                for uid in pairs(records) do
                    if type(uid) == "string" then table.insert(uids, uid) end
                end
            end
        end
    end
    return uids
end

local function hatchOne(uid)
    local ok = call(R.hatch, uid)
    if ok ~= true then return false end
    if S.autoFinish then
        local finished = call(R.finishHatch, uid)
        if finished ~= true then
            pcall(function() call(R.skipGrowth, uid) end)
            call(R.finishHatch, uid)
        end
    end
    return true
end

local hatchState = { lastAt = 0 }

local function hatchLoop()
    if not S.autoHatch or not alive() then return end
    local now = os.clock()
    if now - hatchState.lastAt < S.hatchDelay then return end
    local uids = ownedEggUids()
    if #uids == 0 then return end
    hatchState.lastAt = now
    if hatchOne(uids[1]) then
        dbg.hatches = dbg.hatches + 1
    end
end

-- ===== pets =====
local function sellableUids()
    local p = profile()
    if not p or type(p.Inventory) ~= "table" then return {} end
    local equipped = {}
    if S.keepEquipped and type(p.EquippedAssets) == "table" then
        for _, uid in ipairs(p.EquippedAssets) do equipped[uid] = true end
    end
    local uids = {}
    for uid in pairs(p.Inventory) do
        if type(uid) == "string" and not equipped[uid] then
            table.insert(uids, uid)
        end
    end
    return uids
end

local function sellAll()
    local uids = sellableUids()
    if #uids == 0 then return false, "nothing to sell" end
    local ok = call(R.sellEveryPet, uids)
    if ok ~= false then
        dbg.sells = dbg.sells + 1
        return true, #uids .. " pets"
    end
    return false, "server refused"
end

local sellState = { lastAt = 0 }

local function sellLoop()
    if not S.autoSell then return end
    local now = os.clock()
    if now - sellState.lastAt < S.sellDelay then return end
    sellState.lastAt = now
    pcall(sellAll)
end

-- ===== events =====
local function collectLoop()
    if not S.autoCollect then return end
    call(R.lvdRing)
    call(R.lvdPower)
    call(R.scrambleCollect)
    call(R.sammyCollect)
    call(R.chestClaim)
    call(R.beanReward)
    dbg.collects = dbg.collects + 1
end

-- ===== ESP =====
local espFolder
local espObjects = {}

local function ensureEspFolder()
    if espFolder and espFolder.Parent then return espFolder end
    local gui = Instance.new("ScreenGui")
    gui.Name = "NHHubEsp"
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true
    pcall(function() gui.Parent = gethui() end)
    if not gui.Parent then gui.Parent = LocalPlayer:WaitForChild("PlayerGui") end
    espFolder = gui
    return gui
end

local function clearEsp()
    for _, obj in pairs(espObjects) do
        pcall(function() obj:Destroy() end)
    end
    espObjects = {}
end

local function espLoop()
    if not S.espOn then return end
    local folder = ensureEspFolder()

    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer then
            local char = player.Character
            local head = char and char:FindFirstChild("Head")
            local key = "p_" .. player.Name
            if S.espPlayers and head then
                if not espObjects[key] or not espObjects[key].Parent then
                    local billboard = Instance.new("BillboardGui")
                    billboard.Name = "NHHubName"
                    billboard.Adornee = head
                    billboard.Size = UDim2.fromOffset(160, 22)
                    billboard.StudsOffset = Vector3.new(0, 2.2, 0)
                    billboard.AlwaysOnTop = true
                    local label = Instance.new("TextLabel")
                    label.Size = UDim2.fromScale(1, 1)
                    label.BackgroundTransparency = 1
                    label.TextColor3 = Color3.fromRGB(180, 160, 255)
                    label.TextStrokeTransparency = 0.4
                    label.TextScaled = true
                    label.Font = Enum.Font.GothamBold
                    label.Text = player.Name
                    label.Parent = billboard
                    billboard.Parent = folder
                    espObjects[key] = billboard
                end
            elseif espObjects[key] and not S.espPlayers then
                espObjects[key]:Destroy()
                espObjects[key] = nil
            end
        end
    end

    if S.espPrompts then
        -- A BillboardGui has to adorn a real part in the world; parts parented to a ScreenGui never
        -- render, which is why this adorns the prompt's own part instead of a spawned anchor.
        local live = {}
        for _, prompt in ipairs(workspace:GetDescendants()) do
            if prompt:IsA("ProximityPrompt") and prompt.Enabled then
                local part = prompt.Parent
                if part and part:IsA("BasePart") then
                    local key = "r_" .. tostring(prompt)
                    live[key] = true
                    local billboard = espObjects[key]
                    if not billboard or not billboard.Parent then
                        billboard = Instance.new("BillboardGui")
                        billboard.Name = "NHHubPrompt"
                        billboard.Size = UDim2.fromOffset(150, 18)
                        billboard.StudsOffset = Vector3.new(0, 2.5, 0)
                        billboard.AlwaysOnTop = true
                        local label = Instance.new("TextLabel")
                        label.Size = UDim2.fromScale(1, 1)
                        label.BackgroundTransparency = 1
                        label.TextScaled = true
                        label.TextColor3 = Color3.fromRGB(120, 230, 170)
                        label.TextStrokeTransparency = 0.5
                        label.Font = Enum.Font.GothamMedium
                        label.Text = (string.gsub(prompt.ActionText, "<[^>]+>", ""))
                        label.Parent = billboard
                        billboard.Parent = folder
                        espObjects[key] = billboard
                    end
                    espObjects[key].Adornee = part
                end
            end
        end
        for key, obj in pairs(espObjects) do
            if string.sub(key, 1, 2) == "r_" and not live[key] then
                pcall(function() obj:Destroy() end)
                espObjects[key] = nil
            end
        end
    end
end

-- ===== UI =====
local Window = WindUI:CreateWindow({
    Title = "NHHub",
    Folder = core.folder("Ugc"),
    Size = UDim2.fromOffset(600, 560),
    Theme = "Dark",
    Transparent = true,
    ToggleKey = S.toggleKey,
})

local EggTab = Window:Tab({ Title = "Eggs" })
local PetTab = Window:Tab({ Title = "Pets" })
local EventTab = Window:Tab({ Title = "Events" })
local PromptTab = Window:Tab({ Title = "Actions" })
local EspTab = Window:Tab({ Title = "ESP" })
local StatusTab = Window:Tab({ Title = "Status" })

pcall(function() Window:SelectTab(1) end)

core.polish(Window)
core.attachButton(Window, { key = S.toggleKey })

-- ===== loops =====
-- A failing loop used to be swallowed by pcall and only showed up as a counter, which is exactly
-- how a broken filter can look like "the feature does nothing". Keep the message.
local function guard(name, fn)
    local ok, err = pcall(fn)
    if not ok then
        dbg.errors = dbg.errors + 1
        dbg.lastError = name .. ": " .. tostring(err)
    end
end

RunService.Heartbeat:Connect(function()
    guard("prompts", promptLoop)
    guard("hatch", hatchLoop)
    guard("sell", sellLoop)
    guard("esp", espLoop)
end)

task.spawn(function()
    while true do
        task.wait(2)
        pcall(collectLoop)
    end
end)

-- ===== Egg tab =====
EggTab:Toggle({
    Title = "Hatch my eggs",
    Desc = "Hatches all your eggs.",
    Value = false,
    Callback = function(state)
        S.autoHatch = state
        if state then
            local n = #ownedEggUids()
            WindUI:Notify({
                Title = "Hatch my eggs",
                Content = n > 0 and string.format("Hatching %d eggs", n) or "You have no eggs yet",
                Duration = 6,
            })
        else
            WindUI:Notify({ Title = "Hatch my eggs", Content = "Off" })
        end
    end,
})

EggTab:Slider({
    Title = "Hatch speed (s)",
    Desc = "Time between hatches. Keep it near 0.6.",
    Value = { Min = 0.2, Max = 5, Default = 0.6 }, Step = 0.1, Flag = "hatchdelay",
    Callback = function(v) S.hatchDelay = v end,
})

EggTab:Toggle({
    Title = "Finish right away",
    Desc = "Finishes the egg as soon as it starts.",
    Value = true,
    Callback = function(state) S.autoFinish = state end,
})

local eggCountPara = EggTab:Paragraph({ Title = "My eggs", Desc = "..." })

-- ===== Pets tab =====
PetTab:Toggle({
    Title = "Sell my pets",
    Desc = "Sells your pets for money.",
    Value = false,
    Callback = function(state)
        S.autoSell = state
        if state then
            local n = #sellableUids()
            WindUI:Notify({
                Title = "Sell my pets",
                Content = n > 0 and string.format("Selling %d pets", n) or "Nothing to sell yet",
                Duration = 6,
            })
        else
            WindUI:Notify({ Title = "Sell my pets", Content = "Off" })
        end
    end,
})

PetTab:Slider({
    Title = "Sell speed (s)",
    Value = { Min = 2, Max = 60, Default = 5 }, Step = 1, Flag = "selldelay",
    Callback = function(v) S.sellDelay = v end,
})

PetTab:Toggle({
    Title = "Keep the ones I wear",
    Desc = "Won't sell pets you have out.",
    Value = true,
    Callback = function(state) S.keepEquipped = state end,
})

PetTab:Button({
    Title = "Sell now",
    Desc = "Sells everything once.",
    Callback = function()
        local ok, detail = sellAll()
        WindUI:Notify({
            Title = "Sell",
            Content = ok and ("Sold " .. tostring(detail)) or ("Nothing sold: " .. tostring(detail)),
        })
    end,
})

PetTab:Button({
    Title = "Wear my best pets",
    Desc = "Same as the backpack button.",
    Callback = function()
        local ok = call(R.wearBest)
        WindUI:Notify({ Title = "Wear best", Content = ok and "Done" or "No response" })
    end,
})

-- ===== Events tab =====
EventTab:Toggle({
    Title = "Grab event rewards",
    Desc = "Picks up event stuff when it shows up.",
    Value = false,
    Callback = function(state)
        S.autoCollect = state
        WindUI:Notify({ Title = "Event rewards", Content = state and "Collecting" or "Off" })
    end,
})

EventTab:Button({
    Title = "Claim codex rewards",
    Desc = "Takes everything the codex unlocked.",
    Callback = function()
        local ok = call(R.redeemAll)
        WindUI:Notify({ Title = "Codex", Content = ok and "Claimed" or "Nothing to claim" })
    end,
})

-- ===== Actions tab =====
PromptTab:Toggle({
    Title = "Do actions for me",
    Desc = "Presses the buttons around you.",
    Value = false,
    Callback = function(state)
        S.promptsOn = state
        if state then
            local near = nearestPrompt(function(p) return actionAllowed(p.ActionText) end)
            WindUI:Notify({
                Title = "Do actions",
                Content = near
                    and string.format("Closest: %s (%d studs)", near.action, math.floor(near.dist))
                    or "Nothing turned on - pick some below",
                Duration = 6,
            })
        else
            WindUI:Notify({ Title = "Do actions", Content = "Off" })
        end
    end,
})

PromptTab:Toggle({
    Title = "Walk me to actions",
    Desc = "Goes to the closest button and presses it.",
    Value = false,
    Callback = function(state)
        S.promptRoam = state
        WindUI:Notify({ Title = "Walk me", Content = state and "Going to actions" or "Off" })
    end,
})

PromptTab:Button({
    Title = "Go to closest action",
    Desc = "One trip.",
    Callback = function()
        local near = nearestPrompt(function(p) return actionAllowed(p.ActionText) end)
        if not near then
            WindUI:Notify({ Title = "Nothing found", Content = "Turn on an action below" })
            return
        end
        teleportTo(near.pos)
        task.wait(0.3)
        local fired = near.prompt.Enabled and firePrompt(near.prompt)
        dbg.promptsFired = dbg.promptsFired + (fired and 1 or 0)
        WindUI:Notify({
            Title = fired and "Done" or "Went there",
            Content = string.format("%s (%d studs)", near.action, math.floor(near.dist)),
        })
    end,
})

PromptTab:Slider({
    Title = "How far (studs)",
    Desc = "How close it has to be when walking.",
    Value = { Min = 5, Max = 250, Default = 60 }, Step = 5, Flag = "promptrange",
    Callback = function(v) S.promptDistance = v end,
})

PromptTab:Slider({
    Title = "Wait time (s)",
    Value = { Min = 0.1, Max = 3, Default = 0.35 }, Step = 0.05, Flag = "promptcool",
    Callback = function(v) S.promptCooldown = v end,
})

PromptTab:Divider()

PromptTab:Toggle({ Title = "Steal eggs", Desc = "Takes eggs from other plots", Value = false,
    Callback = function(s) S.catSteal = s end })
PromptTab:Toggle({ Title = "Collect prizes", Desc = "CLAIM and Claim Net", Value = true,
    Callback = function(s) S.catClaim = s end })
PromptTab:Toggle({ Title = "Open things", Desc = "Eggs and chests", Value = true,
    Callback = function(s) S.catOpen = s end })
PromptTab:Toggle({ Title = "Sell things", Desc = "Sell All and Sell this", Value = false,
    Callback = function(s) S.catSell = s end })
PromptTab:Toggle({ Title = "Mutations", Desc = "Apply Mutation", Value = false,
    Callback = function(s) S.catMutate = s end })
PromptTab:Toggle({ Title = "Fuse pets", Desc = "Fuse Pets", Value = false,
    Callback = function(s) S.catFuse = s end })

-- ===== ESP tab =====
EspTab:Toggle({
    Title = "ESP",
    Desc = "Shows players and buttons through walls.",
    Value = false,
    Callback = function(state)
        S.espOn = state
        if not state then clearEsp() end
    end,
})

EspTab:Toggle({ Title = "Players", Value = true, Callback = function(s) S.espPlayers = s end })
EspTab:Toggle({ Title = "Actions", Value = true, Callback = function(s) S.espPrompts = s end })

-- ===== Status tab =====
local cashStatus = StatusTab:Paragraph({ Title = "Money", Desc = "-" })
local areaStatus = StatusTab:Paragraph({ Title = "Area", Desc = "-" })
local countStatus = StatusTab:Paragraph({ Title = "Nearby", Desc = "-" })
local nearStatus = StatusTab:Paragraph({ Title = "Closest action", Desc = "-" })
local workStatus = StatusTab:Paragraph({ Title = "Stats", Desc = "-" })

task.spawn(function()
    while true do
        task.wait(1)
        pcall(function()
            local p = profile()
            cashStatus:SetDesc(p and string.format("%.0f", money(p)) or "no profile")
            areaStatus:SetDesc(tostring(LocalPlayer:GetAttribute("AreaId")))
            local prompts, eggs = 0, 0
            local hrp = myHRP()
            if hrp then
                for _, d in ipairs(workspace:GetDescendants()) do
                    if d:IsA("ProximityPrompt") and d.Enabled then
                        local pos = promptPosition(d)
                        if pos and (pos - hrp.Position).Magnitude <= S.promptDistance then
                            prompts = prompts + 1
                        end
                    end
                end
            end
            eggs = #ownedEggUids()
            countStatus:SetDesc(string.format("%d buttons here | %d eggs", prompts, eggs))
            if eggCountPara then eggCountPara:SetDesc(string.format("%d ready to hatch", eggs)) end
            if nearStatus then
                local near = nearestPrompt(function(p) return actionAllowed(p.ActionText) end)
                nearStatus:SetDesc(near
                    and string.format("%s (%d studs)", near.action, math.floor(near.dist))
                    or "turn on an action")
            end
            workStatus:SetDesc(string.format("did %d | hatched %d | sold %d | errors %d%s",
                dbg.promptsFired, dbg.hatches, dbg.sells, dbg.errors,
                dbg.lastError and (" | " .. dbg.lastError:sub(1, 40)) or ""))
        end)
    end
end)

core.notify({ Title = "NHHub", Content = "UGC loaded. RightShift or the NHHub button opens the menu." })

-- Handy from the console and from the MCP tools: NHHubUgc.dbg.promptsFired, NHHubUgc.S.promptsOn = true, ...
env.NHHubUgc = {
    S = S,
    dbg = dbg,
    remotes = R,
    profile = profile,
    ownedEggUids = ownedEggUids,
    hatchOne = hatchOne,
    sellAll = sellAll,
    sellableUids = sellableUids,
    nearestPrompt = function()
        return nearestPrompt(function(p) return actionAllowed(p.ActionText) end)
    end,
    teleportTo = teleportTo,
}
