util = require("util")

-- FLE keeps its Lua helpers in `storage` (storage.actions.*, storage.utils.*, ...), but a
-- map save cannot serialise functions: "Cannot serialise lua functions". A save happens
-- whenever a player joins (to send them the map), so every join crashed the server and it
-- restarted on a fresh map. Route functions, and the tables that hold them, into a
-- runtime-only table instead; `storage` keeps only data and saves normally.
fle_runtime = fle_runtime or {}
local RUNTIME_TABLES = {actions = true, utils = true, INV = true}
local storage_mt = {
  __index = function(_, key)
    return fle_runtime[key]
  end,
  __newindex = function(t, key, value)
    if type(value) == "function" or RUNTIME_TABLES[key] then
      fle_runtime[key] = value
    else
      rawset(t, key, value)
    end
  end,
}
local function install_storage_routing()
  setmetatable(storage, storage_mt)
end

-- Spectators only: the map is played by script (FLE drives its own character entities,
-- which are not LuaPlayers). Anyone who joins becomes a spectator: no body, so they
-- cannot block placements, get chased by biters, or build/mine by accident.
local function make_spectator(player)
  if not (player and player.valid) then return end
  if player.controller_type ~= defines.controllers.spectator then
    local body = player.character
    player.set_controller{type = defines.controllers.spectator}
    if body and body.valid then body.destroy() end
  end
  player.print("Spectator mode: this map is played by script. Fly with WASD, open the map with M.")
end

script.on_init(install_storage_routing)
script.on_load(install_storage_routing)
script.on_event(defines.events.on_player_joined_game, function(event)
  make_spectator(game.get_player(event.player_index))
end)
script.on_event(defines.events.on_player_respawned, function(event)
  make_spectator(game.get_player(event.player_index))
end)
