--[[ NHHub loader
     This is the only URL you share:

         loadstring(game:HttpGet("https://raw.githubusercontent.com/goldsama0/NHHub/main/NHHub.luau"))()

     Run it in any supported game and it fetches that game's script and runs it. Each game script is
     completely standalone, so adding a game means: write the script, upload it next to this file,
     add one line to MODULES below. Nothing else changes and the shared URL stays the same.

     Testing a game in a place it does not own (a baseplate, a test place) - set the override first:

         getgenv().NHHubGame = "hotegg.luau"
         loadstring(game:HttpGet(".../NHHub.luau"))()
]]

local BASE = "https://raw.githubusercontent.com/goldsama0/NHHub/main/"
local VERSION = "2.0"

-- placeId -> file in this repo. To support a new game, add its PlaceId here.
-- A single game often owns several places (lobby, match, training); list every one of them.
local MODULES = {
    [74589929543330] = "hotegg.luau", -- Hot Egg
    -- [0000000000]   = "othergame.luau",
}

local function notify(title, text)
    pcall(function()
        game:GetService("StarterGui"):SetCore("SendNotification", {
            Title = title,
            Text = text,
            Duration = 6,
        })
    end)
end

local getenv = getgenv or function() return _G end
local forced = getenv().NHHubGame

local fileName = forced or MODULES[game.PlaceId]

if not fileName then
    print(string.format("[NHHub] no script for PlaceId %d (%s)", game.PlaceId, tostring(game.Name)))
    notify("NHHub", "This game is not supported yet.")
    return
end

local url = BASE .. fileName .. "?v=" .. tostring(os.time())

-- The CDN in front of raw.githubusercontent caches files for a few minutes. The ?v= above defeats
-- it; the second HttpGet argument asks the executor to skip its own cache too.
local okFetch, body = pcall(function()
    return game:HttpGet(url, true)
end)

if not okFetch or type(body) ~= "string" or #body < 200 then
    print(string.format("[NHHub] download failed for %s: %s", url, tostring(body)))
    notify("NHHub", "Download failed - check the URL.")
    return
end

local chunk, compileError = loadstring(body, "=NHHub:" .. fileName)

if not chunk then
    print("[NHHub] compile error in " .. fileName .. ": " .. tostring(compileError))
    notify("NHHub", "Script error - see console.")
    return
end

getenv().NHHub = {
    version = VERSION,
    placeId = game.PlaceId,
    file = fileName,
}

print(string.format("[NHHub] v%s -> %s (placeId %d)", VERSION, fileName, game.PlaceId))

local okRun, runError = pcall(chunk)

if not okRun then
    print("[NHHub] runtime error in " .. fileName .. ": " .. tostring(runError))
    notify("NHHub", "Script error - see console.")
end
