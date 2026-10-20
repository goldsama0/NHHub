--[[ Hot Egg toolkit - WindUI (v11)
     - Auto Pass Egg : teleport onto the nearest player and dwell so the server registers
       the touch. Jumps are capped in distance and rate-limited to stay unremarkable.
     - Auto Escape  : after the egg leaves you, move to the furthest safe spot on the map.
     - Auto Evade   : while you don't hold it, break away from whoever does.
     - Ground Guard : raycasts the floor so you never jump or run into the void.
     - Auto Kill    : duel auto-win (Sumo push / Egg Throw).
     - RightShift or the MENU button to open. ]]
local WindUI = loadstring(game:HttpGet("https://github.com/Footagesus/WindUI/releases/latest/download/main.lua"))()

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LocalPlayer = Players.LocalPlayer

local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
local GameState = ReplicatedStorage:WaitForChild("GameState", 10)

local BASE_WALKSPEED = 16

local S = {
    autoPass = false,
    autoEvade = false,
    autoKill = false,
    autoDodge = false,   -- duel: circle-strafe so the opponent's throws miss
    dodgeRadius = 13,    -- standoff while circling; must stay inside the 19.2 ring
    fly = false,
    flySpeed = 55,
    flyMethod = "Physics",
    smooth = 0.25,
    chaseSpeed = 110,     -- sprint speed used when Legit Mode is OFF
    passTrigger = 4,      -- teleport when further than this
    passDwell = 0.3,      -- seconds to hold position so the server registers the touch
    evadeSpeed = 110,
    method = "Teleport",  -- "Teleport" or "Sprint"
    autoEscape = false,   -- after passing, go somewhere the holder cannot reach
    escapeHeight = 258,   -- Y of the rooftop we escape to
    escapeReturn = true,  -- come back down when the fuse is nearly up
    maxJump = 22,         -- never teleport further than this in one hop (long hops get flagged)
    tpCooldown = 0.6,     -- minimum seconds between teleports
    evadeDistance = 70,   -- start evading when closer than this
    killRange = 6,         -- SUMO_REACH is 6.5 in the game config
    sumoTeleport = true,  -- hop onto the centre side of the opponent before pushing
    sumoJump = 10,        -- longest hop used for that; small hops are far less suspicious
    safeMode = false,     -- OFF: full teleport + speed behaviour. Turn ON to avoid kicks.
    eggTeleport = false,  -- OFF by default: the hop is what kept reading as speed
    eggStandoff = 5,      -- how far behind them to land (closer = flatter, more accurate throw)
    eggRange = 30,        -- longest throw we will take a shot at
    eggMaxLead = 4,       -- cap on how far ahead of a moving target we aim
    eggHopMax = 10,       -- longest single hop while repositioning; longer spots are skipped
    eggStrafe = true,     -- walk sideways continuously so a thrown egg misses (no speed flag)
    eggStrafeFlip = 0.9,  -- seconds between strafe direction changes
    eggKeepMin = 14,      -- back off if closer than this
    eggKeepMax = 24,      -- close in if further than this
    eggDodge = false,     -- OFF by default: the dodge is a teleport
    eggDodgeDist = 8,     -- how far behind them (or sideways) that hop goes
    eggDodgeMax = 12,     -- longest hop used to dodge a throw
    groundGuard = true,
    teleportTarget = nil,
    autoTeleport = false,
    tpRange = 6,
    toggleKey = Enum.KeyCode.RightShift,
}

-- Expose settings for external testing/jobs
_G.HotEggS = S
_G.HotEgg = { settings = S, toggle = function() if Window then Window:Toggle() end end, open = function() if Window then Window:Open() end end, close = function() if Window then Window:Close() end end }

local function myChar() return LocalPlayer.Character end
local function myHRP() local c = myChar() return c and c:FindFirstChild("HumanoidRootPart") end
local function myHum() local c = myChar() return c and c:FindFirstChildOfClass("Humanoid") end
local function isAlive() local h = myHum() return h ~= nil and h.Health > 0 end
local function byId(id) if not id or id == 0 then return nil end return Players:GetPlayerByUserId(id) end

-- ===== ground guard =====
local FALL_Y = 245
local function floorY(x, z)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = { myChar() }
    local hit = workspace:Raycast(Vector3.new(x, 400, z), Vector3.new(0, -300, 0), params)
    return hit and hit.Position.Y or nil
end
-- is the spot ahead safe to run into?
local function safeAhead(hrp, dir, dist)
    local px = hrp.Position + dir * dist
    if not S.groundGuard then return true end
    return floorY(px.X, px.Z) ~= nil
end

-- ===== holder =====
local function holderPlayers()
    local l = {}
    for _, k in ipairs({ "HolderUserId", "HolderUserId2" }) do
        local p = byId(GameState:GetAttribute(k))
        if p then table.insert(l, p) end
    end
    return l
end
local function iHoldEgg()
    for _, p in ipairs(holderPlayers()) do if p == LocalPlayer then return true end end
    return false
end
local function holderName()
    if iHoldEgg() then return "YOU" end
    local l = holderPlayers()
    return l[1] and l[1].Name or nil
end

-- ===== duel ring bounds =====
-- Leaving the ring loses the duel (the game shows a DuelRingWarning for it), so every
-- duel movement is clamped inside this radius. 19.2 is DUEL_RING_RADIUS from Config;
-- we stay well inside it because a Sumo push can fling you several studs outward.
local RING_RADIUS = 19.2
local RING_SAFE = 15            -- never voluntarily go past this
local DUEL_ORIGIN = Vector3.new(0, 240, 3200)
local TRAINING_DUEL_ORIGIN = Vector3.new(190, 240, 3200)
pcall(function()
    local cfg = require(ReplicatedStorage.Shared.Config)
    if cfg.DUEL_RING_RADIUS then RING_RADIUS = cfg.DUEL_RING_RADIUS end
    if cfg.DUEL_ORIGIN then DUEL_ORIGIN = cfg.DUEL_ORIGIN end
    if cfg.TRAINING_DUEL_ORIGIN then TRAINING_DUEL_ORIGIN = cfg.TRAINING_DUEL_ORIGIN end
end)

--[[ Centre of the active duel ring. Training matches are fought on a completely
     separate island (TRAINING_DUEL_ORIGIN, x ~ 190), so using the normal duel origin
     there would aim all the ring logic at the wrong place. Dohyo is a Folder, not a
     part, so there is nothing to read a position from. ]]
local function ringCentre()
    if LocalPlayer:GetAttribute("InTrainingMatch") then
        return TRAINING_DUEL_ORIGIN
    end
    return DUEL_ORIGIN
end

-- pull a movement direction back toward the middle when we are near the edge
local function steerInsideRing(hrp, dir)
    local c = ringCentre()
    local flat = Vector3.new(hrp.Position.X - c.X, 0, hrp.Position.Z - c.Z)
    local r = flat.Magnitude
    if r < 0.1 then return dir end
    local inward = -flat.Unit
    if r > RING_SAFE then
        -- the further out we are, the harder we steer back
        local urgency = math.clamp((r - RING_SAFE) / 3, 0.5, 4)
        return (dir + inward * urgency).Unit
    end
    return dir
end
local function ringDistOf(pos)
    local c = ringCentre()
    return (Vector3.new(pos.X - c.X, 0, pos.Z - c.Z)).Magnitude
end
local function ringDistance(hrp)
    return ringDistOf(hrp.Position)
end
-- Deliberately slow: the ring is 19 studs across, so sprinting inside it overshoots.
local SUMO_SPEED = 26
-- The game switches to TrainingState for practice matches (see DuelClient.activeState),
-- so read the same way it does instead of assuming GameState is always the source.
local function activeDuelState()
    local ts = ReplicatedStorage:FindFirstChild("TrainingState")
    if ts and LocalPlayer:GetAttribute("InTrainingMatch") then return ts end
    return GameState
end

local function duelInfo()
    local st = activeDuelState()
    if not st then return nil end
    local a, b = byId(st:GetAttribute("DuelA")), byId(st:GetAttribute("DuelB"))
    local opp = (LocalPlayer == a) and b or ((LocalPlayer == b) and a or nil)
    if not opp then return nil end
    return {
        mode = st:GetAttribute("DuelMode"),
        phase = st:GetAttribute("DuelPhase"),
        opponent = opp,
        inDuel = true,
    }
end

-- ===== others =====
local function aliveOthers()
    local out = {}
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer and p:GetAttribute("Alive") == true then
            local c = p.Character
            if c and c:FindFirstChild("HumanoidRootPart") then table.insert(out, p) end
        end
    end
    return out
end
local function nearestOther()
    local hrp = myHRP()
    if not hrp then return nil end
    local best, bestd = nil, math.huge
    for _, p in ipairs(aliveOthers()) do
        local d = (p.Character.HumanoidRootPart.Position - hrp.Position).Magnitude
        if d < bestd then bestd, best = d, p end
    end
    return best
end
local function playerNames()
    local n = {}
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer and p.Character and p.Character:FindFirstChild("HumanoidRootPart") then
            table.insert(n, p.Name)
        end
    end
    if #n == 0 then n = { "(no players)" } end
    return n
end
local function getByName(n)
    for _, p in ipairs(Players:GetPlayers()) do if p.Name == n then return p end end
end

-- anti-AFK
task.spawn(function()
    while true do
        task.wait(3)
        pcall(function()
            local t = Remotes:FindFirstChild("AfkToggle")
            if t and LocalPlayer:GetAttribute("Afk") == true then t:FireServer(false) end
        end)
    end
end)

--[[ High-velocity sprint.
     The server damps velocity hard (asking for 30 yields ~8) and pins WalkSpeed to 16.
     Re-applying the velocity EVERY frame is what actually breaks through - a single push
     gets eaten in one physics step. We keep pushing until we arrive.

     BUT that is exactly what gets flagged as "speed". In legit mode we never touch
     AssemblyLinearVelocity at all: we only ever call Humanoid:Move, so the character moves
     at the same 16 studs/sec the server already allows for everyone. No advantage from
     movement, but nothing for an anti-cheat to see either. ]]
local function rotate(dir, ang)
    local c, s = math.cos(ang), math.sin(ang)
    return Vector3.new(dir.X * c - dir.Z * s, 0, dir.X * s + dir.Z * c)
end

--[[ Instrumentation. Cheap counters, so a live round can tell us whether the movement code
     is actually issuing instructions or bailing out before it moves anything. ]]
local dbg = { sprint = 0, bail = 0, move = 0, vel = 0, evade = 0, pass = 0, lastDir = Vector3.zero }
_G.HotEggDbg = dbg

-- Hits are decided by the server and broadcast back through DuelFx, so this is the only honest
-- scoreboard we have: it tells us whether the throw is actually landing rather than just firing.
-- Counts are written to disk so they survive leaving the game - in-memory counters died with the
-- Lua state and left us unable to answer "did it actually hit".
local STATS_PATH = "hotegg_stats.json"
local stats = { dealt = 0, taken = 0, duels = 0 }
pcall(function()
    if isfile and isfile(STATS_PATH) then
        local ok, parsed = pcall(function()
            return game:GetService("HttpService"):JSONDecode(readfile(STATS_PATH))
        end)
        if ok and type(parsed) == "table" then
            stats.dealt = tonumber(parsed.dealt) or 0
            stats.taken = tonumber(parsed.taken) or 0
            stats.duels = tonumber(parsed.duels) or 0
        end
    end
end)
dbg.hitDealt = stats.dealt
dbg.hitTaken = stats.taken
local function saveStats()
    pcall(function()
        writefile(STATS_PATH, game:GetService("HttpService"):JSONEncode(stats))
    end)
end

task.spawn(function()
    local fx = Remotes:WaitForChild("DuelFx", 15)
    if not fx then return end
    fx.OnClientEvent:Connect(function(kind, a2)
        if kind ~= "Hit" then return end
        if a2 == LocalPlayer.UserId then
            stats.taken = stats.taken + 1
        else
            stats.dealt = stats.dealt + 1
        end
        dbg.hitDealt = stats.dealt
        dbg.hitTaken = stats.taken
        saveStats()
    end)
end)

--[[ Pick a direction we can actually walk. Straight ahead first, then fanning out to either
     side, because refusing to move at all just lets the holder walk into us. ]]
local function clearDir(hrp, dir)
    if safeAhead(hrp, dir, 6) then return dir end
    for _, ang in ipairs({ 0.6, -0.6, 1.1, -1.1, 1.6, -1.6, 2.2, -2.2 }) do
        local d = rotate(dir, ang)
        if d.Magnitude > 0.01 and safeAhead(hrp, d.Unit, 6) then return d.Unit end
    end
    return nil
end

local function sprint(hrp, hum, dir, speed)
    if not hrp or not hum then return end
    dbg.sprint = dbg.sprint + 1
    dir = Vector3.new(dir.X, 0, dir.Z)
    if dir.Magnitude < 0.001 then return end
    dir = dir.Unit
    -- never run into a spot with no floor under it, but do not freeze either
    local ok = clearDir(hrp, dir)
    if not ok then
        dbg.bail = dbg.bail + 1
        hum:MoveTo(hrp.Position)
        return
    end
    dir = ok
    dbg.lastDir = dir
    if S.safeMode then
        -- Legit mode: humanoid movement only, at the speed the game itself permits.
        dbg.move = dbg.move + 1
        hum:Move(dir, false)
        return
    end
    dbg.vel = dbg.vel + 1
    -- MoveTo keeps the humanoid walking (keeps you "legitimate"), velocity does the work
    hum:MoveTo(hrp.Position + dir * 40)
    local v = hrp.AssemblyLinearVelocity
    hrp.AssemblyLinearVelocity = Vector3.new(dir.X * speed, v.Y, dir.Z * speed)
end

--[[ Duel movement: never boosted. Position changes in a duel come from the teleport, and
     ordinary travel happens at the game's own walk speed. Adding velocity on top is what
     showed up as "speed" on the anti-cheat, so duel code never calls sprint(). ]]
local function walk(hrp, hum, dir)
    if not hrp or not hum then return end
    local d = Vector3.new(dir.X, 0, dir.Z)
    if d.Magnitude < 0.001 then return end
    d = d.Unit
    local ok = clearDir(hrp, d)
    if not ok then
        hum:MoveTo(hrp.Position)
        return
    end
    hum:Move(ok, false)
end

local function runToward(hrp, hum, targetPos, speed, stopDist)
    if not hrp or not hum then return end
    local to = Vector3.new(targetPos.X - hrp.Position.X, 0, targetPos.Z - hrp.Position.Z)
    if to.Magnitude <= (stopDist or 0.5) then
        hum:MoveTo(hrp.Position)
        return
    end
    sprint(hrp, hum, to, speed)
end

local function runAway(hrp, hum, fromPos, speed)
    if not hrp or not hum then return end
    local away = Vector3.new(hrp.Position.X - fromPos.X, 0, hrp.Position.Z - fromPos.Z)
    if away.Magnitude < 0.1 then away = Vector3.new(1, 0, 0) end
    sprint(hrp, hum, away, speed)
end

-- ===== CORE 1: pass the egg onto another player =====
--[[ Teleport registers with the server, but only if you STAY in contact long enough for
     it to process the touch. So the loop is: close the gap, freeze on them, then hold
     still. If several dwells in a row fail we shrink the standoff and dwell longer,
     because a near miss looks identical to "nothing happened" from here. ]]
local PASS_STOP = 2.5      -- consider ourselves "on them" inside this
local passState = { dwellUntil = 0, lastTp = 0, fails = 0, lastLog = 0 }
RunService.Heartbeat:Connect(function()
    if not S.autoPass or not isAlive() or not iHoldEgg() then
        passState.fails = 0
        return
    end
    if GameState:GetAttribute("State") ~= "Round" then return end
    local hrp, hum = myHRP(), myHum()
    if not hrp or not hum then return end
    local target = nearestOther()
    if not target then return end
    local thrp = target.Character and target.Character:FindFirstChild("HumanoidRootPart")
    if not thrp then return end

    local now = os.clock()
    local tp = thrp.Position
    local dist = (Vector3.new(hrp.Position.X, 0, hrp.Position.Z) - Vector3.new(tp.X, 0, tp.Z)).Magnitude

    if S.method == "Sprint" then
        runToward(hrp, hum, tp, S.chaseSpeed, 0.5)
        return
    end

    -- it has been a while without the egg leaving us: get closer and dwell harder
    local stop = PASS_STOP
    local dwell = S.passDwell
    if passState.fails >= 2 then stop, dwell = 1.2, S.passDwell * 1.6 end
    if passState.fails >= 4 then stop, dwell = 0.4, S.passDwell * 2.4 end

    if dist > stop then
        local mayHop = (not S.safeMode) and (now - passState.lastTp) >= S.tpCooldown
        local dest = Vector3.new(tp.X, hrp.Position.Y, tp.Z)
        --[[ No distance cap on the pass hop. Capping it meant long gaps fell back to sprinting,
             and sprinting is what gets flagged as speed. A hop is instant, so the length of the
             hop does not matter to the speed check in the way that sustained velocity does. ]]
        if mayHop and (not S.groundGuard or floorY(dest.X, dest.Z)) then
            hrp.CFrame = CFrame.new(dest) * (hrp.CFrame - hrp.CFrame.Position)
            hum:MoveTo(hrp.Position)
            hrp.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
            passState.lastTp = now
            passState.dwellUntil = now + dwell
        else
            -- safe mode, or still on the teleport cooldown: walk, never sprint
            local d = Vector3.new(tp.X - hrp.Position.X, 0, tp.Z - hrp.Position.Z)
            if d.Magnitude > 0.1 then walk(hrp, hum, d.Unit) end
        end
    else
        -- on them: freeze completely so the server can process the touch
        hum:MoveTo(hrp.Position)
        hrp.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
        if now >= passState.dwellUntil then
            -- dwell ran out and we still have it: retry from a hair further in
            passState.fails = passState.fails + 1
            passState.dwellUntil = now + dwell
            if passState.fails >= 2 and not S.safeMode then
                pcall(function()
                    hrp.CFrame = CFrame.new(tp.X, hrp.Position.Y, tp.Z)
                end)
            end
            if (now - passState.lastLog) > 1.5 then
                passState.lastLog = now
                print(string.format("[HotEgg] pass attempts=%d dist=%.1f target=%s",
                    passState.fails, dist, target.Name))
            end
        end
    end
end)

-- ===== CORE 2: evade (max-speed sprint away from holder) =====
local evadeBoost = 1.0
RunService.Heartbeat:Connect(function()
    if not S.autoEvade or not isAlive() or iHoldEgg() then
        evadeBoost = 1.0
        return
    end
    if GameState:GetAttribute("State") ~= "Round" then return end
    local hrp, hum = myHRP(), myHum()
    local holder = holderPlayers()[1]
    if not hrp or not hum or not holder then return end
    local hhrp = holder.Character and holder.Character:FindFirstChild("HumanoidRootPart")
    if not hhrp or (hrp.Position - hhrp.Position).Magnitude >= S.evadeDistance then return end

    local v = hrp.AssemblyLinearVelocity
    local actual = math.sqrt(v.X * v.X + v.Z * v.Z)
    if actual < S.evadeSpeed * 0.5 and evadeBoost < 1.35 then
        evadeBoost = math.min(evadeBoost + 0.01, 1.35)
    end
    dbg.evade = dbg.evade + 1
    dbg.evadeDist = math.floor((hrp.Position - hhrp.Position).Magnitude)
    dbg.evadeBoost = evadeBoost
    dbg.evadeActual = math.floor(actual)
    --[[ No speed boost in rounds either. Escape does the teleporting; if it is not active we
         just walk away at normal speed, because a boosted velocity is what shows up as "speed". ]]
    local awayDir = Vector3.new(hrp.Position.X - hhrp.Position.X, 0, hrp.Position.Z - hhrp.Position.Z)
    if awayDir.Magnitude > 0.1 then
        walk(hrp, hum, awayDir.Unit)
    end
end)

-- ===== CORE 3: escape after passing (get out of reach so they can't pass it back) =====
--[[ Right after the egg leaves your hands you want to be far from it. The map changes
     every round, so instead of hardcoding a rooftop we scan for a standable spot on the
     current map that is as far as possible from every other player, and go there.
     Ground is verified with a raycast first, so you never jump into the void. ]]
local escapeState = { active = false, until_ = 0, lastTp = 0 }

-- best standable point on the active map, furthest from all other players
local function bestEscapeSpot(hrp)
    local others = {}
    for _, p in ipairs(aliveOthers()) do
        local o = p.Character and p.Character:FindFirstChild("HumanoidRootPart")
        if o then table.insert(others, o.Position) end
    end
    if #others == 0 then return nil end

    local origin = hrp.Position
    local best, bestScore = nil, -math.huge
    local radii = { 18, 26, 34, 44, 55 }
    for _, r in ipairs(radii) do
        for i = 0, 15 do
            local a = (i / 16) * math.pi * 2
            local x = origin.X + math.cos(a) * r
            local z = origin.Z + math.sin(a) * r
            local fy = floorY(x, z)
            if fy then
                local cand = Vector3.new(x, fy + 4, z)
                -- score = distance to the closest player (higher is safer)
                local nearest = math.huge
                for _, o in ipairs(others) do
                    local d = (Vector3.new(o.X, 0, o.Z) - Vector3.new(cand.X, 0, cand.Z)).Magnitude
                    if d < nearest then nearest = d end
                end
                if nearest > bestScore then bestScore, best = nearest, cand end
            end
        end
    end
    return best, bestScore
end

RunService.Heartbeat:Connect(function()
    if not S.autoEscape or not isAlive() then
        escapeState.active = false
        return
    end
    if GameState:GetAttribute("State") ~= "Round" then
        escapeState.active = false
        return
    end
    local hrp, hum = myHRP(), myHum()
    if not hrp or not hum then return end

    -- only escape while somebody ELSE holds it (i.e. right after we passed)
    if iHoldEgg() then
        escapeState.active = false
        return
    end
    local holder = holderPlayers()[1]
    if not holder then return end
    local hhrp = holder.Character and holder.Character:FindFirstChild("HumanoidRootPart")
    if not hhrp then return end

    local now = os.clock()
    if not escapeState.active then
        escapeState.active = true
        escapeState.until_ = now + 5
        escapeState.lastTp = 0
    end

    if now < escapeState.until_ then
        -- if the holder is comfortably far, just stay put
        local gap = (hrp.Position - hhrp.Position).Magnitude
        if gap < 40 then
            -- the scan is 80 raycasts, so only run it on the cooldown, not every frame
            if (now - (escapeState.lastScan or 0)) >= S.tpCooldown then
                escapeState.lastScan = now
                local spot, score = bestEscapeSpot(hrp)
                --[[ Teleport out, always. Even when the best spot found is not much further than
                     we already are, going is better than sprinting: the run is what the speed
                     check sees, and a short hop is invisible to it. ]]
                if (not S.safeMode) and spot then
                    hrp.CFrame = CFrame.new(spot) * (hrp.CFrame - hrp.CFrame.Position)
                    hrp.AssemblyLinearVelocity = Vector3.zero
                    escapeState.lastTp = now
                    dbg.escapeTp = (dbg.escapeTp or 0) + 1
                else
                    -- safe mode, or nothing standable found: walk, never sprint
                    local awayDir = Vector3.new(hrp.Position.X - hhrp.Position.X, 0, hrp.Position.Z - hhrp.Position.Z)
                    if awayDir.Magnitude > 0.1 then walk(hrp, hum, awayDir.Unit) end
                end
            end
        end
    else
        escapeState.active = false
    end
end)

-- keep walkspeed sane (the game caps it at 16 regardless of what we set)
task.spawn(function()
    while true do
        task.wait(1)
        local hum = myHum()
        if hum and hum.WalkSpeed > BASE_WALKSPEED then
            hum.WalkSpeed = BASE_WALKSPEED
        end
        -- Sumo turns AutoRotate off so our facing survives the push; put it back outside duels
        if hum and hum.AutoRotate == false and not duelInfo() then
            hum.AutoRotate = true
        end
    end
end)

-- ===== ground guard (rescue if you do fall) =====
task.spawn(function()
    while true do
        task.wait(0.3)
        if S.groundGuard and isAlive() and not escapeState.active then
            local hrp = myHRP()
            if hrp and hrp.Position.Y < FALL_Y then
                local info = duelInfo()
                if info then
                    -- fell out of the ring: put us back in the middle, not on the ledge.
                    -- In safe mode we do not do this at all: a Y-axis snap like this is the
                    -- single most obvious thing an anti-cheat can look for.
                    if not S.safeMode then
                        local c = ringCentre()
                        hrp.CFrame = CFrame.new(c.X, c.Y + 6, c.Z)
                        hrp.AssemblyLinearVelocity = Vector3.zero
                    end
                else
                    local fy = floorY(hrp.Position.X, hrp.Position.Z)
                    if fy then hrp.CFrame = CFrame.new(hrp.Position.X, fy + 3, hrp.Position.Z) end
                end
            end
        end
    end
end)

-- ===== duel: dodge =====
--[[ Throws are physical projectiles, so the way to not get hit is to not be where they
     aimed. We keep a standoff and circle, flipping direction at random so their lead
     cannot settle. Everything is clamped inside the ring, because leaving it loses the
     duel - circling at a radius wider than the ring was ring-ing us out. ]]
local dodgeState = { dir = 1, flipAt = 0 }
RunService.Heartbeat:Connect(function()
    if not S.autoDodge or not isAlive() then return end
    local info = duelInfo()
    if not info or info.phase ~= "Fight" or not info.opponent then return end
    local hrp, hum = myHRP(), myHum()
    local ohrp = info.opponent.Character and info.opponent.Character:FindFirstChild("HumanoidRootPart")
    if not hrp or not hum or not ohrp then return end

    local now = os.clock()
    local flat = Vector3.new(hrp.Position.X - ohrp.Position.X, 0, hrp.Position.Z - ohrp.Position.Z)
    local dist = flat.Magnitude
    if dist < 0.5 then flat = Vector3.new(1, 0, 0) end
    local away = flat.Unit
    local r = ringDistance(hrp)

    -- flip the circle direction on a timer for both modes
    if now > dodgeState.flipAt then
        dodgeState.dir = (math.random() < 0.5) and 1 or -1
        dodgeState.flipAt = now + 0.45 + math.random() * 0.7
    end

    if info.mode == "Sumo" then
        -- Auto Kill drives Sumo movement when it is on, so the two loops never fight.
        if S.autoKill then return end
        -- Straight lines only here too: no orbiting. Back off toward the centre, or stand.
        local c = ringCentre()
        local centrePos = Vector3.new(c.X, hrp.Position.Y, c.Z)
        if r > 17 then
            local dir = Vector3.new(centrePos.X - hrp.Position.X, 0, centrePos.Z - hrp.Position.Z)
            if dir.Magnitude > 0.1 then walk(hrp, hum, dir.Unit) end
        elseif dist < 8 then
            -- step away from them, but only if that keeps us inside the ring
            local nextPos = hrp.Position + away * 4
            if ringDistOf(nextPos) <= RING_SAFE then
                walk(hrp, hum, away)
            else
                hum:MoveTo(hrp.Position)
                hrp.AssemblyLinearVelocity = Vector3.new(0, hrp.AssemblyLinearVelocity.Y, 0)
            end
        else
            hum:MoveTo(hrp.Position)
            hrp.AssemblyLinearVelocity = Vector3.new(0, hrp.AssemblyLinearVelocity.Y, 0)
        end
        return
    end

    -- Egg Throw: Auto Kill owns movement in Egg mode, so it can keep a moving target (us).
    -- Previously this loop issued "stop here" every frame and cancelled the strafe entirely.
    if S.autoKill then return end

    local desired = math.min(S.dodgeRadius, RING_SAFE - 2)
    local radial = (dist > desired + 4) and -away or ((dist < desired - 6) and away or Vector3.zero)

    if radial.Magnitude > 0.001 then
        walk(hrp, hum, steerInsideRing(hrp, radial.Unit))
    else
        hum:MoveTo(hrp.Position)
        hrp.AssemblyLinearVelocity = Vector3.new(0, hrp.AssemblyLinearVelocity.Y, 0)
    end
end)

--[[ Watched the game spawn these live: the projectile is a Part named "ThrownEgg" parented
     straight to Workspace, created at the thrower's torso the instant they throw. Subscribing to
     DescendantAdded is therefore instant and exact - no polling an attribute and hoping the
     server got to it before the egg did. ]]
local lastEggDodge = 0
workspace.DescendantAdded:Connect(function(inst)
    if inst.Name ~= "ThrownEgg" then return end
    if not S.eggDodge or S.safeMode then return end
    local info = duelInfo()
    if not info or info.mode ~= "Egg" or info.phase ~= "Fight" then return end
    local hrp = myHRP()
    if not hrp then return end

    local now = os.clock()
    if now - lastEggDodge < 0.2 then return end
    lastEggDodge = now

    -- the egg spawns at the thrower; if the replicated position is not readable yet, use them
    local origin = inst.Position
    if origin.Magnitude < 1 then
        local o = info.opponent.Character and info.opponent.Character:FindFirstChild("HumanoidRootPart")
        origin = o and o.Position or nil
    end
    if not origin then return end

    local toMe = Vector3.new(hrp.Position.X - origin.X, 0, hrp.Position.Z - origin.Z)
    if toMe.Magnitude < 0.1 then toMe = Vector3.new(1, 0, 0) end
    if toMe.Magnitude > 70 then return end
    toMe = toMe.Unit
    local perp = Vector3.new(-toMe.Z, 0, toMe.X)

    -- two perpendicular choices; take whichever stays inside the ring
    local candidates = {}
    table.insert(candidates, hrp.Position + perp * S.eggDodgeDist)
    table.insert(candidates, hrp.Position - perp * S.eggDodgeDist)
    -- and going behind the thrower is a second safe option
    local o = info.opponent.Character and info.opponent.Character:FindFirstChild("HumanoidRootPart")
    if o then
        local f = o.CFrame.LookVector
        f = Vector3.new(f.X, 0, f.Z)
        if f.Magnitude > 0.1 then
            table.insert(candidates, o.Position - f.Unit * S.eggDodgeDist)
        end
    end

    local best, bestScore = nil, -math.huge
    for _, cand in ipairs(candidates) do
        local flat = Vector3.new(cand.X, hrp.Position.Y, cand.Z)
        local jump = (Vector3.new(flat.X - hrp.Position.X, 0, flat.Z - hrp.Position.Z)).Magnitude
        if jump <= S.eggDodgeMax and ringDistOf(flat) <= RING_SAFE then
            -- prefer the spot furthest off the egg's line of travel
            local offLine = (flat - origin)
            local along = offLine:Dot(toMe)
            local side = (offLine - toMe * along).Magnitude
            if side > bestScore then bestScore, best = side, flat end
        end
    end

    if not best then return end
    hrp.CFrame = CFrame.new(best) * (hrp.CFrame - hrp.CFrame.Position)
    hrp.AssemblyLinearVelocity = Vector3.zero
    dbg.eggDodgeTp = (dbg.eggDodgeTp or 0) + 1
end)

-- ===== duel: dodge the incoming throw =====
--[[ The server bumps ThrowReadyAt (and drops Ammo) the instant the opponent throws, so a
     jump in either value tells us a throw has just left their hand. We react before the
     projectile covers the distance: hop to the side they are not aiming at, which is directly
     behind them when that spot is still inside the ring. ]]
local throwWatch = { ready = nil, ammo = nil, last = 0 }
RunService.Heartbeat:Connect(function()
    if not S.eggDodge or S.safeMode then return end
    local info = duelInfo()
    if not info or info.phase ~= "Fight" or info.mode ~= "Egg" then return end
    local opp = info.opponent
    local hrp = myHRP()
    local ohrp = opp.Character and opp.Character:FindFirstChild("HumanoidRootPart")
    if not hrp or not ohrp then return end

    local ready = opp:GetAttribute("ThrowReadyAt")
    local ammo = opp:GetAttribute("Ammo")
    if typeof(ready) ~= "number" then return end
    local prevReady, prevAmmo = throwWatch.ready, throwWatch.ammo
    throwWatch.ready, throwWatch.ammo = ready, ammo
    if prevReady == nil then return end

    local threw = (ready > prevReady + 0.25)
        or (typeof(prevAmmo) == "number" and typeof(ammo) == "number" and ammo < prevAmmo)
    if not threw then return end

    local nowS = os.clock()
    if nowS - throwWatch.last < 0.2 then return end
    throwWatch.last = nowS

    local facing = ohrp.CFrame.LookVector
    facing = Vector3.new(facing.X, 0, facing.Z)
    if facing.Magnitude < 0.1 then facing = Vector3.new(1, 0, 0) end
    facing = facing.Unit

    -- where the throw was aimed: straight at us. get off that line.
    local behind = Vector3.new(
        ohrp.Position.X - facing.X * S.eggDodgeDist,
        hrp.Position.Y,
        ohrp.Position.Z - facing.Z * S.eggDodgeDist)

    local spot
    if ringDistOf(behind) <= RING_SAFE then
        spot = behind
    else
        local side = Vector3.new(-facing.Z, 0, facing.X)
        local cand = Vector3.new(
            hrp.Position.X + side.X * S.eggDodgeDist,
            hrp.Position.Y,
            hrp.Position.Z + side.Z * S.eggDodgeDist)
        if ringDistOf(cand) <= RING_SAFE then
            spot = cand
        else
            local c = ringCentre()
            spot = Vector3.new(c.X, hrp.Position.Y, c.Z)
        end
    end

    -- never take a hop longer than the dodge cap; if both candidate spots are far, just stand
    local jump = (Vector3.new(spot.X - hrp.Position.X, 0, spot.Z - hrp.Position.Z)).Magnitude
    if jump > S.eggDodgeMax then
        return
    end

    hrp.CFrame = CFrame.new(spot) * (hrp.CFrame - hrp.CFrame.Position)
    hrp.AssemblyLinearVelocity = Vector3.zero
    dbg.dodgeTp = (dbg.dodgeTp or 0) + 1
end)

-- ===== auto kill: duel =====
-- Mirrors DuelClient.onAction: Sumo fires DuelAttack() when in reach, Egg Throw fires
-- DuelThrow(aimPosition) when Ammo > 0 and the throw cooldown has elapsed. The client also
-- turns the character to face the target before firing, which the server expects, so we do
-- the same instead of only calling the remote.
local function faceToward(hrp, pos)
    local flat = Vector3.new(pos.X - hrp.Position.X, 0, pos.Z - hrp.Position.Z)
    if flat.Magnitude > 0.5 then
        hrp.CFrame = CFrame.lookAt(hrp.Position, hrp.Position + flat)
    end
end

--[[ Fixed-point solution for "where do I aim so the egg meets them".
     egg: speed 85, gravity 40 (ReplicatedStorage.Shared.Config).
     Target: moves at vq, and while airborne falls under character gravity 196.
     ping is the one-way-ish delay before the server actually launches. ]]
local function solveEggAim(origin, q0, vq, airborne, ping)
    local SPEED, EGG_GRAV, CHAR_GRAV = 85, 40, 196
    local t = (q0 - origin).Magnitude / SPEED + ping
    local aimPoint = q0
    for _ = 1, 4 do
        local q = q0 + vq * t
        if airborne then
            q = q + Vector3.new(0, -0.5 * CHAR_GRAV * t * t, 0)
        end
        aimPoint = q + Vector3.new(0, 0.5 * EGG_GRAV * t * t, 0)
        t = (aimPoint - origin).Magnitude / SPEED + ping
    end
    return aimPoint
end

local lastKillLog = 0

-- ===== sumo positioning =====
--[[ A push knocks the opponent along the line between you, so the only push worth
     throwing is one aimed at the rim. That means standing on the CENTRE side of them:
     push direction = away from the ring middle = straight out. Standing anywhere else
     just shoves them sideways across the ring and burns the cooldown.
     Dohyo is a Folder so there is no part to read; the ring centre comes from Config. ]]
local sumoState = { lastTp = 0, holdUntil = 0, facing = nil }
local eggState = { lastTp = 0 }

local function sumoPushSpot(hrp, ohrp)
    local c = ringCentre()
    local op = Vector3.new(ohrp.Position.X, hrp.Position.Y, ohrp.Position.Z)
    local outward = Vector3.new(op.X - c.X, 0, op.Z - c.Z)

    if outward.Magnitude < 1.5 then
        -- they are basically on the centre spot: pick any direction and shove
        outward = Vector3.new(op.X - hrp.Position.X, 0, op.Z - hrp.Position.Z)
        if outward.Magnitude < 1 then outward = Vector3.new(1, 0, 0) end
    end
    outward = outward.Unit

    -- stand just inside them, close enough to be in push reach
    local spot = op - outward * 3.0

    -- but never stand outside the ring ourselves
    local fromC = Vector3.new(spot.X - c.X, 0, spot.Z - c.Z)
    if fromC.Magnitude > RING_SAFE then
        local clamped = c + fromC.Unit * RING_SAFE
        spot = Vector3.new(clamped.X, hrp.Position.Y, clamped.Z)
    end
    return spot, outward
end

task.spawn(function()
    while true do
        task.wait(0.08)
        if S.autoKill then
            local info = duelInfo()
            if info and info.phase == "Fight" and info.opponent then
                local hrp, hum = myHRP(), myHum()
                local ohrp = info.opponent.Character and info.opponent.Character:FindFirstChild("HumanoidRootPart")
                if hrp and hum and ohrp then
                    local dist = (ohrp.Position - hrp.Position).Magnitude
                    local now = workspace:GetServerTimeNow()

                    if info.mode == "Sumo" then
                        --[[ Straight lines only. Earlier versions slid "tangentially along the
                             ring", which is a circle - that is what was spinning us out. Every
                             move here is either directly at the push spot, directly at the
                             centre, or standing still, and at a speed low enough not to
                             overshoot a 19-stud ring. ]]
                        local c = ringCentre()
                        local centrePos = Vector3.new(c.X, hrp.Position.Y, c.Z)
                        local rNow = ringDistance(hrp)
                        local myReady = now >= (LocalPlayer:GetAttribute("PushReadyAt") or 0)

                        -- stop the humanoid from auto-rotating us away from the push
                        hum.AutoRotate = false

                        if now < (sumoState.holdUntil or 0) then
                            -- just pushed: stand still and keep facing them until it resolves
                            hum:MoveTo(hrp.Position)
                            hrp.AssemblyLinearVelocity = Vector3.new(0, hrp.AssemblyLinearVelocity.Y, 0)
                            if sumoState.facing then faceToward(hrp, sumoState.facing) end
                        elseif rNow > 17 then
                            -- hard override: only when we are genuinely near the rim. Using a
                            -- tighter number than this fought the attack spot (which legitimately
                            -- sits at up to 15 studs) and bounced us back to the centre forever.
                            local toCentre = Vector3.new(centrePos.X - hrp.Position.X, 0, centrePos.Z - hrp.Position.Z)
                            if toCentre.Magnitude > 0.1 then
                                walk(hrp, hum, toCentre.Unit)
                            else
                                hum:MoveTo(hrp.Position)
                            end
                        elseif myReady then
                            local spot = sumoPushSpot(hrp, ohrp)
                            local toSpot = Vector3.new(spot.X - hrp.Position.X, 0, spot.Z - hrp.Position.Z)
                            local spotDist = toSpot.Magnitude

                            if spotDist > 2.0 and S.sumoTeleport and not S.safeMode
                               and spotDist <= S.sumoJump
                               and (now - sumoState.lastTp) >= math.max(S.tpCooldown, 1.0)
                               and ringDistOf(spot) <= RING_SAFE then
                                -- keep our facing: CFrame.new() alone snaps us to world -Z, which
                                -- is what looked like the character spinning round on every hop
                                hrp.CFrame = CFrame.new(spot) * (hrp.CFrame - hrp.CFrame.Position)
                                hrp.AssemblyLinearVelocity = Vector3.zero
                                sumoState.lastTp = now
                            elseif spotDist > 1.5 then
                                walk(hrp, hum, toSpot.Unit)
                            else
                                hum:MoveTo(hrp.Position)
                                hrp.AssemblyLinearVelocity = Vector3.new(0, hrp.AssemblyLinearVelocity.Y, 0)
                            end

                            local d2 = (ohrp.Position - hrp.Position).Magnitude
                            if d2 <= S.killRange then
                                --[[ Fire from a dead stop, facing them, and STAY facing them for a
                                     moment afterwards. The server resolves the push after it has
                                     processed the remote, so the instant we walk off toward the next
                                     spot the humanoid turns us around and the push is thrown the
                                     wrong way - that is what "it turns around after pushing" was. ]]
                                hum:MoveTo(hrp.Position)
                                hrp.AssemblyLinearVelocity = Vector3.new(0, hrp.AssemblyLinearVelocity.Y, 0)
                                faceToward(hrp, ohrp.Position)
                                sumoState.facing = ohrp.Position
                                sumoState.holdUntil = now + 0.25
                                local da = Remotes:FindFirstChild("DuelAttack")
                                if da then
                                    pcall(function() da:FireServer() end)
                                    dbg.attack = (dbg.attack or 0) + 1
                                end
                            end
                        else
                            --[[ Push on cooldown. Standing still for the whole cooldown is what felt
                                 like the bot freezing after every push, so instead we keep shadowing
                                 them at just outside their reach: close enough to be in position the
                                 moment our push comes back, far enough that they cannot land theirs. ]]
                            local shadow = 8.0
                            if dist > shadow + 1.5 then
                                local toThem = Vector3.new(ohrp.Position.X - hrp.Position.X, 0, ohrp.Position.Z - hrp.Position.Z)
                                if toThem.Magnitude > 0.1 then
                                    walk(hrp, hum, toThem.Unit)
                                end
                            elseif dist < shadow - 2.5 then
                                local awayNow = Vector3.new(hrp.Position.X - ohrp.Position.X, 0, hrp.Position.Z - ohrp.Position.Z)
                                if awayNow.Magnitude < 0.1 then awayNow = Vector3.new(1, 0, 0) end
                                local dir = awayNow.Unit
                                if rNow > 10 then
                                    dir = Vector3.new(centrePos.X - hrp.Position.X, 0, centrePos.Z - hrp.Position.Z)
                                    if dir.Magnitude > 0.1 then dir = dir.Unit else dir = awayNow.Unit end
                                end
                                walk(hrp, hum, dir)
                            else
                                hum:MoveTo(hrp.Position)
                                hrp.AssemblyLinearVelocity = Vector3.new(0, hrp.AssemblyLinearVelocity.Y, 0)
                            end
                        end
                    else
                        -- Egg Throw: get behind them first, then throw.
                        --[[ Standing still and lobbing from range is what made this feel passive:
                             half the throws were blocked by the cooldown while we stood in the
                             open. Instead we take the spot directly behind their facing (where
                             they are not looking), hop to it, and throw from close range in the
                             same cycle. ]]
                        local facing = ohrp.CFrame.LookVector
                        facing = Vector3.new(facing.X, 0, facing.Z)
                        if facing.Magnitude < 0.1 then facing = Vector3.new(1, 0, 0) end
                        facing = facing.Unit

                        local spot = Vector3.new(
                            ohrp.Position.X - facing.X * S.eggStandoff,
                            hrp.Position.Y,
                            ohrp.Position.Z - facing.Z * S.eggStandoff)

                        -- never hop outside the ring
                        local sc = ringCentre()
                        local sOff = Vector3.new(spot.X - sc.X, 0, spot.Z - sc.Z)
                        if sOff.Magnitude > RING_SAFE then
                            local cl = sc + sOff.Unit * RING_SAFE
                            spot = Vector3.new(cl.X, hrp.Position.Y, cl.Z)
                        end

                        local toSpot = Vector3.new(spot.X - hrp.Position.X, 0, spot.Z - hrp.Position.Z)
                        local spotDist = toSpot.Magnitude

                        if spotDist > 6.0 and S.eggTeleport then
                            --[[ Short hops only, and not very often. An uncapped teleport across the
                                 ring is a huge single-frame position change, which is exactly what a
                                 speed check measures - it does not care that it was "a teleport".
                                 If the spot is further than eggHopMax we simply do not move and throw
                                 from where we stand, which is still accurate at this range. ]]
                            if (now - eggState.lastTp) >= math.max(S.tpCooldown, 1.0)
                               and spotDist <= S.eggHopMax
                               and ringDistOf(spot) <= RING_SAFE then
                                hrp.CFrame = CFrame.new(spot) * (hrp.CFrame - hrp.CFrame.Position)
                                hrp.AssemblyLinearVelocity = Vector3.zero
                                eggState.lastTp = now
                                dbg.eggTp = (dbg.eggTp or 0) + 1
                            end
                        else
                            --[[ Movement in an Egg duel. Two jobs:
                                 1. Never stand still. The egg does not track, so constant lateral
                                    movement at walk speed is a genuine dodge.
                                 2. Hold a distance where THEIR throw is long and ours is not
                                    disadvantaged: the intercept solver is exact at any range, while
                                    they only get one guess at where we were. ]]
                            local toOpp = Vector3.new(ohrp.Position.X - hrp.Position.X, 0, ohrp.Position.Z - hrp.Position.Z)
                            local toOppUnit = toOpp.Magnitude > 0.1 and toOpp.Unit or Vector3.new(1, 0, 0)

                            if now >= (eggState.flipAt or 0) then
                                eggState.flipAt = now + S.eggStrafeFlip * (0.7 + math.random() * 0.6)
                                eggState.dir = -(eggState.dir or 1)
                            end

                            local perp = Vector3.new(-toOppUnit.Z, 0, toOppUnit.X) * (eggState.dir or 1)
                            local radial = Vector3.zero
                            if dist < S.eggKeepMin then
                                radial = -toOppUnit
                            elseif dist > S.eggKeepMax then
                                radial = toOppUnit
                            end

                            local move = perp + radial * 0.9
                            if move.Magnitude > 0.01 then
                                walk(hrp, hum, steerInsideRing(hrp, move.Unit))
                            end
                        end

                        --[[ Ballistic intercept.
                             The egg is a projectile with a fixed speed (85) that falls under gravity
                             (40), and the server decides the hit after it has flown. So the point to
                             aim at is where the target WILL BE when the egg arrives, not where they
                             are now.

                             Solved by fixed-point iteration: assume a flight time, move the target
                             forward by it, raise the aim by the gravity drop over that time, then
                             recompute the flight time from the new aim point and repeat. Converges in
                             3-4 passes at these ranges.

                             Three things that were missing before and cost hits:
                             - VERTICAL motion. A jumping target was treated as flat, so every jump
                               beat the throw. Their own gravity is subtracted while they are off the
                               floor, which is what makes an arc land where their arc lands.
                             - LATENCY. The server starts the egg when the remote arrives, so the
                               target has already moved by half our ping. That is added to the flight
                               time.
                             - The vertical velocity is taken raw, not smoothed: smoothing it lags a
                               jump badly, while horizontal jitter still needs smoothing. ]]
                        local ov = ohrp.AssemblyLinearVelocity
                        if ov.Magnitude > 80 then ov = ov.Unit * 80 end
                        local flatOv = Vector3.new(ov.X, 0, ov.Z)
                        if not eggState.vel then
                            eggState.vel = flatOv
                        else
                            eggState.vel = eggState.vel:Lerp(flatOv, 0.5)
                        end

                        local oppHum = info.opponent.Character:FindFirstChildOfClass("Humanoid")
                        local airborne = oppHum ~= nil and oppHum.FloorMaterial == Enum.Material.Air
                        local ping = math.min(LocalPlayer:GetNetworkPing() or 0, 0.2)

                        local vq = Vector3.new(eggState.vel.X, airborne and ov.Y or 0, eggState.vel.Z)
                        local aimDist = (ohrp.Position - hrp.Position).Magnitude
                        local q0 = ohrp.Position
                        local aim = solveEggAim(hrp.Position, q0, vq, airborne, ping)

                        local ammo = LocalPlayer:GetAttribute("Ammo") or 0
                        local readyAt = LocalPlayer:GetAttribute("ThrowReadyAt") or 0

                        if ammo > 0 and now >= readyAt and aimDist <= S.eggRange then
                            faceToward(hrp, aim)
                            local dt = Remotes:FindFirstChild("DuelThrow")
                            if dt then pcall(function() dt:FireServer(aim) end) end
                        elseif (now - lastKillLog) > 2 then
                            lastKillLog = now
                            print(string.format("[HotEgg] throw blocked: ammo=%s readyIn=%.1fs d=%.0f phase=%s",
                                tostring(ammo), math.max(0, readyAt - now), aimDist, tostring(info.phase)))
                        end
                    end
                end
            end
        end
    end
end)

-- ===== fly =====
local fly = { lv = nil, att = nil, vel = Vector3.zero }
local function stopFly()
    S.fly = false
    if fly.lv then pcall(function() fly.lv:Destroy() end) fly.lv = nil end
    if fly.att then pcall(function() fly.att:Destroy() end) fly.att = nil end
    fly.vel = Vector3.zero
    local hum = myHum()
    if hum then pcall(function() hum:ChangeState(Enum.HumanoidStateType.GettingUp) end) end
end
local function computeDir()
    local cam = workspace.CurrentCamera
    if not cam then return Vector3.zero end
    local d = Vector3.zero
    if UserInputService:IsKeyDown(Enum.KeyCode.W) then d += cam.CFrame.LookVector end
    if UserInputService:IsKeyDown(Enum.KeyCode.S) then d -= cam.CFrame.LookVector end
    if UserInputService:IsKeyDown(Enum.KeyCode.A) then d -= cam.CFrame.RightVector end
    if UserInputService:IsKeyDown(Enum.KeyCode.D) then d += cam.CFrame.RightVector end
    if UserInputService:IsKeyDown(Enum.KeyCode.Space) then d += Vector3.new(0, 1, 0) end
    if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then d -= Vector3.new(0, 1, 0) end
    if d.Magnitude > 0 then d = d.Unit end
    return d
end
local function startFly()
    local hrp, hum = myHRP(), myHum()
    if not hrp or not hum then
        WindUI:Notify({ Title = "Fly", Content = "No character yet.", Icon = "triangle-alert" })
        return false
    end
    S.fly = true
    fly.vel = Vector3.zero
    if S.flyMethod == "Physics" then
        fly.att = Instance.new("Attachment"); fly.att.Name = "MCPFlyAttachment"; fly.att.Parent = hrp
        fly.lv = Instance.new("LinearVelocity")
        fly.lv.Name = "MCPFly"; fly.lv.Attachment0 = fly.att
        fly.lv.MaxForce = math.huge; fly.lv.RelativeTo = Enum.ActuatorRelativeTo.World
        fly.lv.VectorVelocity = Vector3.zero; fly.lv.Parent = hrp
        pcall(function() hum:ChangeState(Enum.HumanoidStateType.Freefall) end)
    end
    return true
end
RunService.RenderStepped:Connect(function(dt)
    if not S.fly then return end
    local hrp, hum = myHRP(), myHum()
    if not hrp or not hum or hum.Health <= 0 then stopFly() return end
    local k = math.clamp(dt * (1 / math.max(S.smooth, 0.03)), 0, 1)
    fly.vel = fly.vel:Lerp(computeDir() * S.flySpeed, k)
    if fly.vel.Magnitude < 0.4 then fly.vel = Vector3.zero end
    if S.flyMethod == "Physics" and fly.lv then
        fly.lv.VectorVelocity = fly.vel
        if hum:GetState() ~= Enum.HumanoidStateType.Freefall then
            pcall(function() hum:ChangeState(Enum.HumanoidStateType.Freefall) end)
        end
        local flat = Vector3.new(fly.vel.X, 0, fly.vel.Z)
        if flat.Magnitude > 2 then hrp.CFrame = CFrame.lookAt(hrp.Position, hrp.Position + flat) end
    else
        if fly.vel.Magnitude > 0.1 then hrp.CFrame = hrp.CFrame + fly.vel * dt end
    end
end)

-- ===== UI =====
local Window = WindUI:CreateWindow({
    Title = "NHHub",
    Icon = "egg",
    Folder = "NHHub",
    Size = UDim2.fromOffset(600, 580),
    Theme = "Violet",
    Transparent = true,
    ToggleKey = S.toggleKey,
})

-- One long Main tab was the main usability problem: Fly sat below twenty unrelated
-- controls. Split by what you are doing at the time instead of by feature family.
local EggTab = Window:Tab({ Title = "Egg", Icon = "egg" })
local DuelTab = Window:Tab({ Title = "Duel", Icon = "swords" })
local MoveTab = Window:Tab({ Title = "Move", Icon = "move" })
local SettingsTab = Window:Tab({ Title = "Settings", Icon = "settings" })
local StatusTab = Window:Tab({ Title = "Status", Icon = "activity" })

-- ===== reopen button (fallback for the hotkey) =====
-- Remove our own button from any earlier run. Only this one: the WindUI window belongs to the
-- library and destroying it out from under a still-running copy breaks that copy.
do
    local roots = {}
    local ok, hidden = pcall(function() return gethui() end)
    if ok and hidden then table.insert(roots, hidden) end
    local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
    if playerGui then table.insert(roots, playerGui) end
    for _, root in ipairs(roots) do
        for _, child in ipairs(root:GetChildren()) do
            if child:IsA("ScreenGui") and child.Name == "HotEggReopen" then
                child:Destroy()
            end
        end
    end
end

local gui = Instance.new("ScreenGui")
gui.Name = "HotEggReopen"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
pcall(function() gui.Parent = gethui() end)
if not gui.Parent then gui.Parent = LocalPlayer:WaitForChild("PlayerGui") end

local btn = Instance.new("TextButton")
btn.Size = UDim2.fromOffset(84, 26)
btn.Position = UDim2.new(1, -94, 0, 8)
btn.BackgroundColor3 = Color3.fromRGB(24, 20, 38)
btn.TextColor3 = Color3.fromRGB(237, 233, 254)
btn.Font = Enum.Font.GothamBold
btn.TextSize = 13
btn.Text = "NHHub"
btn.AutoButtonColor = true
btn.Parent = gui
local corner = Instance.new("UICorner"); corner.CornerRadius = UDim.new(0, 6); corner.Parent = btn
local stroke = Instance.new("UIStroke"); stroke.Color = Color3.fromRGB(139, 92, 246); stroke.Parent = btn

local function toggleWindow()
    local ok = pcall(function() Window:Toggle() end)
    if not ok then pcall(function() Window:Open() end) end
end
btn.MouseButton1Click:Connect(toggleWindow)

UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    if input.KeyCode == S.toggleKey then toggleWindow() end
end)
pcall(function() Window:SetToggleKey(S.toggleKey) end)

local eggStatus = StatusTab:Paragraph({ Title = "Egg", Desc = "-" })
local duelStatus = StatusTab:Paragraph({ Title = "Duel", Desc = "-" })
local meStatus = StatusTab:Paragraph({ Title = "You", Desc = "-" })
local recStatus = StatusTab:Paragraph({ Title = "Record", Desc = "-" })

task.spawn(function()
    while true do
        task.wait(0.4)
        pcall(function()
            local hold = iHoldEgg()
            eggStatus:SetDesc(string.format("holder=%s | %s | cycle=%s",
                holderName() or "nobody",
                hold and "PASSING (running at them)" or "EVADING (running away)",
                tostring(GameState:GetAttribute("CyclePhase"))))
            local info = duelInfo()
            duelStatus:SetDesc(info and info.opponent
                and string.format("%s/%s vs %s", info.mode or "?", info.phase or "?", info.opponent.Name)
                or "not in a duel")
            local hum = myHum()
            meStatus:SetDesc(string.format("alive=%s state=%s walkspeed=%s pass=%s evade=%s",
                tostring(LocalPlayer:GetAttribute("Alive")),
                tostring(GameState:GetAttribute("State")),
                hum and tostring(hum.WalkSpeed) or "-",
                tostring(S.autoPass), tostring(S.autoEvade)))
            recStatus:SetDesc(string.format("landed %d  /  taken %d",
                dbg.hitDealt or 0, dbg.hitTaken or 0))
        end)
    end
end)

-- ===== controls: Egg =====
EggTab:Toggle({
    Title = "Auto Pass",
    Desc = "While you hold it: teleport onto the nearest player and stay long enough for the server to register the touch.",
    Icon = "egg",
    Value = false,
    Callback = function(state)
        S.autoPass = state
        WindUI:Notify({ Title = "Auto Pass", Content = state and "Armed - passes on touch" or "Off", Icon = "egg" })
    end,
})
EggTab:Dropdown({
    Title = "Pass method",
    Values = { "Teleport", "Sprint" },
    Value = "Teleport",
    Callback = function(v)
        S.method = v
        WindUI:Notify({ Title = "Pass method", Content = v == "Teleport" and "Teleport, then dwell" or "Sprint into them", Icon = "zap" })
    end,
})
EggTab:Slider({
    Title = "Pass trigger distance",
    Desc = "Only closes the gap when the target is further away than this.",
    Value = { Min = 2, Max = 30, Default = 4 }, Step = 1, Flag = "passtrigger",
    Callback = function(v) S.passTrigger = v end,
})
EggTab:Slider({
    Title = "Touch dwell (s)",
    Desc = "How long you stand still on contact. Under about 0.15s the server ignores the touch.",
    Value = { Min = 0.1, Max = 1.0, Default = 0.3 }, Step = 0.05, Flag = "passdwell",
    Callback = function(v) S.passDwell = v end,
})
EggTab:Slider({
    Title = "Sprint fallback speed",
    Desc = "Used only if the teleport touch does not take.",
    Value = { Min = 20, Max = 200, Default = 110 }, Step = 5, Flag = "chasespeed",
    Callback = function(v) S.chaseSpeed = v end,
})

EggTab:Divider()

EggTab:Toggle({
    Title = "Auto Evade",
    Desc = "While someone else holds it: walk away from the holder, never toward them.",
    Icon = "footprints",
    Value = false,
    Callback = function(state)
        S.autoEvade = state
        WindUI:Notify({ Title = "Auto Evade", Content = state and "Moving away from the holder" or "Off", Icon = "footprints" })
    end,
})
EggTab:Slider({
    Title = "Evade speed",
    Desc = "Movement speed while evading. 16 is the game's own walk speed.",
    Value = { Min = 20, Max = 200, Default = 110 }, Step = 5, Flag = "evadespeed",
    Callback = function(v) S.evadeSpeed = v end,
})
EggTab:Slider({
    Title = "Evade distance",
    Desc = "Only starts moving once the holder is closer than this.",
    Value = { Min = 20, Max = 150, Default = 70 }, Step = 5, Flag = "evadedist",
    Callback = function(v) S.evadeDistance = v end,
})

EggTab:Divider()

EggTab:Toggle({
    Title = "Auto Escape",
    Desc = "After you pass: move to the furthest safe spot so they cannot hand it straight back.",
    Icon = "arrow-up-from-line",
    Value = false,
    Callback = function(state)
        S.autoEscape = state
        WindUI:Notify({ Title = "Auto Escape", Content = state and "Breaking away after a pass" or "Off", Icon = "arrow-up-from-line" })
    end,
})

-- ===== controls: Settings =====
SettingsTab:Toggle({
    Title = "Legit Mode",
    Desc = "No teleports and no velocity injection at all - you move at the game's own walk speed. Slower, but there is nothing to flag.",
    Icon = "shield-check",
    Value = false,
    Callback = function(state)
        S.safeMode = state
        WindUI:Notify({
            Title = "Legit Mode",
            Content = state and "No teleports, no speed boost" or "Full speed and teleports",
            Icon = "shield-check",
        })
    end,
})

-- ===== controls: Move =====
MoveTab:Toggle({
    Title = "Ground Guard",
    Desc = "Checks the floor ahead and pulls you back if you are about to drop off the map.",
    Icon = "shield",
    Value = true,
    Callback = function(state) S.groundGuard = state end,
})

-- ===== controls: Duel =====
DuelTab:Toggle({
    Title = "Auto Kill",
    Desc = "Final duel only: pushes in Sumo, throws in Egg.",
    Icon = "swords",
    Value = false,
    Callback = function(state)
        S.autoKill = state
        WindUI:Notify({ Title = "Auto Kill", Content = state and "Armed for the duel" or "Off", Icon = "swords" })
    end,
})
DuelTab:Toggle({
    Title = "Auto Dodge",
    Desc = "Keep moving so their attacks miss instead of standing in range.",
    Icon = "wind",
    Value = false,
    Callback = function(state)
        S.autoDodge = state
        WindUI:Notify({ Title = "Auto Dodge", Content = state and "Dodging on" or "Off", Icon = "wind" })
    end,
})
DuelTab:Slider({
    Title = "Dodge standoff",
    Desc = "Distance held from the opponent. The ring is 19.2 studs, so keep this under 16.",
    Value = { Min = 8, Max = 16, Default = 13 }, Step = 1, Flag = "dodgeradius",
    Callback = function(v) S.dodgeRadius = v end,
})

DuelTab:Divider()

DuelTab:Toggle({
    Title = "Sumo - hop behind",
    Desc = "Hops to the centre side of them so the push carries them outward.",
    Icon = "move",
    Value = true,
    Callback = function(state)
        S.sumoTeleport = state
        WindUI:Notify({ Title = "Sumo hop", Content = state and "Hopping behind before the push" or "Off - walks into them", Icon = "move" })
    end,
})
DuelTab:Slider({
    Title = "Sumo hop distance",
    Desc = "Longest hop used to get behind them. Smaller is less obvious.",
    Value = { Min = 4, Max = 16, Default = 10 }, Step = 1, Flag = "sumojump",
    Callback = function(v) S.sumoJump = v end,
})

DuelTab:Divider()

DuelTab:Toggle({
    Title = "Egg - hop behind",
    Desc = "Teleports behind them before throwing instead of standing at range.",
    Icon = "move",
    Value = true,
    Callback = function(state)
        S.eggTeleport = state
        WindUI:Notify({ Title = "Egg hop", Content = state and "Hopping behind to throw" or "Off - throws from where it stands", Icon = "move" })
    end,
})
DuelTab:Slider({
    Title = "Egg hop standoff",
    Desc = "How far behind them to land. Closer is a flatter, more accurate throw.",
    Value = { Min = 4, Max = 16, Default = 6 }, Step = 1, Flag = "eggstandoff",
    Callback = function(v) S.eggStandoff = v end,
})
DuelTab:Slider({
    Title = "Aim lead",
    Desc = "Extra prediction on top of the solved intercept. Higher tracks runners, lower punishes juking.",
    Value = { Min = 0, Max = 10, Default = 4 }, Step = 0.5, Flag = "egglead",
    Callback = function(v) S.eggMaxLead = v end,
})
DuelTab:Toggle({
    Title = "Egg - strafe",
    Desc = "Walks sideways so their egg misses. Normal walk speed, so it never reads as speed.",
    Icon = "wind",
    Value = true,
    Callback = function(state)
        S.eggStrafe = state
        WindUI:Notify({ Title = "Egg strafe", Content = state and "Always moving sideways" or "Off - stands still", Icon = "wind" })
    end,
})

SettingsTab:Divider()

SettingsTab:Dropdown({
    Title = "Menu hotkey", Values = { "RightShift", "RightControl", "K", "P", "F1", "Insert" }, Value = "RightShift",
    Callback = function(v)
        local map = { RightShift = Enum.KeyCode.RightShift, RightControl = Enum.KeyCode.RightControl,
                      K = Enum.KeyCode.K, P = Enum.KeyCode.P, F1 = Enum.KeyCode.F1, Insert = Enum.KeyCode.Insert }
        if map[v] then
            S.toggleKey = map[v]
            pcall(function() Window:SetToggleKey(S.toggleKey) end)
            WindUI:Notify({ Title = "Hotkey", Content = "Now toggling with " .. v, Icon = "keyboard" })
        end
    end,
})

MoveTab:Divider()

MoveTab:Dropdown({
    Title = "Fly method", Values = { "Physics", "CFrame" }, Value = "Physics",
    Callback = function(v) S.flyMethod = v if S.fly then stopFly() end end,
})
MoveTab:Toggle({
    Title = "Fly", Desc = "WASD to move, Space up, Ctrl down.",
    Icon = "bird", Value = false,
    Callback = function(state)
        if state then if not startFly() then return end else stopFly() end
    end,
})
MoveTab:Slider({
    Title = "Fly speed", Value = { Min = 10, Max = 150, Default = 55 }, Step = 5, Flag = "flyspeed",
    Callback = function(v) S.flySpeed = v end,
})
MoveTab:Slider({
    Title = "Fly smoothing", Desc = "Lower is snappier, higher is smoother.",
    Value = { Min = 0.03, Max = 1.0, Default = 0.25 }, Step = 0.01, Flag = "smooth",
    Callback = function(v) S.smooth = v end,
})

MoveTab:Divider()

local tpDD
tpDD = MoveTab:Dropdown({
    Title = "Teleport to player", Values = playerNames(), AllowNone = true,
    Callback = function(v) S.teleportTarget = v end,
})

local function refresh()
    pcall(function() tpDD:Refresh(playerNames()) end)
end
Players.PlayerAdded:Connect(function() task.wait(1) refresh() end)
Players.PlayerRemoving:Connect(refresh)

WindUI:Notify({ Title = "NHHub", Content = "RightShift or the NHHub button opens the menu.", Duration = 7, Icon = "egg" })
