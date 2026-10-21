--[[ NHHub registry - which script runs in which place.

     Add a game by adding a line here. loader.lua never needs to change again, and because this file
     is fetched with a cache-buster every run, the change is live immediately for everyone.

         [placeId] = { file = "name.lua", name = "Shown in the console" },

     A game that uses several places (lobby, match, training) gets one entry per PlaceId, all
     pointing at the same file. If a round teleports you somewhere and the menu disappears, the
     PlaceId for that place is missing from this table.
]]

return {
    [74589929543330] = { file = "hotegg.lua", name = "Hot Egg" },
    [107778070777162] = { file = "ugc.lua", name = "UGC" },

    -- [0000000000] = { file = "something.lua", name = "Something" },
}
