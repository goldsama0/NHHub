--[[ NHHub loader - the only URL you share.

         loadstring(game:HttpGet("https://raw.githubusercontent.com/goldsama0/NHHub/main/loader.lua"))()

     Run it in any supported game and it runs that game's script. It knows nothing about any game;
     the mapping lives in registry.lua, so supporting a new game is a one-line edit there and does
     not touch this file.

     Testing a game in a place it does not own (a baseplate, a test place):

         getgenv().NHHubGame = "hotegg.lua"
         loadstring(game:HttpGet(".../loader.lua"))()

     Clear it with getgenv().NHHubGame = nil to go back to routing by PlaceId.
]]

local BASE = "https://raw.githubusercontent.com/goldsama0/NHHub/main/"
local VERSION = "2.2"

local getenv = getgenv or function() return _G end

local function notify(text)
    pcall(function()
        game:GetService("StarterGui"):SetCore("SendNotification", {
            Title = "NHHub",
            Text = text,
            Duration = 6,
        })
    end)
end

-- raw.githubusercontent sits behind a CDN that caches for a few minutes, so every fetch carries a
-- version stamp. The second HttpGet argument asks the executor to skip its own cache as well.
local function fetch(path)
    local url = BASE .. path .. "?v=" .. tostring(os.time())
    local ok, body = pcall(function()
        return game:HttpGet(url, true)
    end)
    if not ok or type(body) ~= "string" or #body < 40 then
        print(string.format("[NHHub] download failed: %s (%s)", url, tostring(body)))
        return nil
    end
    return body
end

local function compile(body, name)
    local chunk, err = loadstring(body, "=NHHub:" .. name)
    if not chunk then
        print(string.format("[NHHub] compile error in %s: %s", name, tostring(err)))
    end
    return chunk
end

-- 1. registry: PlaceId -> file
local registryBody = fetch("registry.lua")
if not registryBody then
    notify("Could not load the game registry.")
    return
end

local registryChunk = compile(registryBody, "registry.lua")
if not registryChunk then
    notify("Registry is broken - see console.")
    return
end

local okRegistry, registry = pcall(registryChunk)
if not okRegistry or type(registry) ~= "table" then
    print("[NHHub] registry did not return a table: " .. tostring(registry))
    notify("Registry is broken - see console.")
    return
end

local entry = registry[game.PlaceId]
local forced = getenv().NHHubGame
if forced then
    entry = { file = forced, name = "forced by NHHubGame" }
end

if not entry then
    print(string.format("[NHHub] no script for PlaceId %d (%s)", game.PlaceId, tostring(game.Name)))
    notify("This game is not supported yet.")
    return
end

-- 2. core: shared plumbing, handed to the game script
local coreBody = fetch("core.lua")
if not coreBody then
    notify("Could not load NHHub core.")
    return
end

local coreChunk = compile(coreBody, "core.lua")
if not coreChunk then
    notify("Core is broken - see console.")
    return
end

local okCore, core = pcall(coreChunk)
if not okCore or type(core) ~= "table" then
    print("[NHHub] core did not return a table: " .. tostring(core))
    notify("Core is broken - see console.")
    return
end

-- Game modules read this instead of a vararg: some executors compile fetched chunks as plain
-- functions, where "local core = ..." is a syntax error.
getenv().NHHubCore = core

-- 3. the game itself
local gameBody = fetch(entry.file)
if not gameBody then
    notify("Could not load the script for this game.")
    return
end

local gameChunk = compile(gameBody, entry.file)
if not gameChunk then
    notify("Script error - see console.")
    return
end

getenv().NHHub = {
    version = VERSION,
    placeId = game.PlaceId,
    file = entry.file,
    name = entry.name,
    coreVersion = core.VERSION,
}

print(string.format("[NHHub] v%s -> %s (placeId %d, core v%s)",
    VERSION, entry.file, game.PlaceId, tostring(core.VERSION)))

local okRun, runError = pcall(gameChunk, entry)

if not okRun then
    print("[NHHub] runtime error in " .. entry.file .. ": " .. tostring(runError))
    notify("Script error - see console.")
end
