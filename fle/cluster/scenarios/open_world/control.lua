util = require("util")

-- ===================================================================================
-- Multiplayer support for FLE (so people can join and watch).
--
-- FLE sends its Lua to the server as console commands at runtime. That breaks joining in
-- three ways, fixed here:
--  1. FLE keeps functions in `storage`; a map save (made for every join) cannot serialise
--     functions. -> A metatable on storage routes functions and the actions/utils/INV
--     tables into fle_runtime (not saved). storage keeps only data.
--  2. FLE registers event handlers at runtime; a joining client only runs control.lua, so
--     its registered events differ from the server's ("script-event-mismatch").
--     -> The global `script` is a proxy: FLE's on_event/on_nth_tick calls store handlers
--     in fle_runtime, and the real registrations are a fixed set of dispatchers made here,
--     identical on every peer.
--  3. A joining client has none of FLE's functions. -> FLE also stores each script's source
--     in storage (plain data, saved with the map). On its first tick after loading, a
--     client replays those sources in a sandbox where data writes to storage are ignored
--     (the save already holds the data), rebuilding the same functions and handlers.
-- ===================================================================================

fle_runtime = fle_runtime or {}
fle_runtime.handlers = fle_runtime.handlers or {}
fle_runtime.nth = fle_runtime.nth or {}

local RUNTIME_TABLES = {actions = true, utils = true, INV = true}
local storage_mt = {
  __index = function(_, key) return fle_runtime[key] end,
  __newindex = function(t, key, value)
    if type(value) == "function" or RUNTIME_TABLES[key] then
      fle_runtime[key] = value
    else
      rawset(t, key, value)
    end
  end,
}

-- events FLE registers at runtime (mods/utils.lua, alerts.lua, request_path, move_to,
-- harvest_resource, place_entity, inspect_inventory)
local real_script = script
local DISPATCHED_EVENTS = {
  [defines.events.on_tick] = true,
  [defines.events.on_script_path_request_finished] = true,
  -- event-driven play (tools/agent/events): reacting to the world as it happens
  [defines.events.on_entity_died] = true,
  [defines.events.on_entity_damaged] = true,
  [defines.events.on_research_finished] = true,
  [defines.events.on_unit_group_finished_gathering] = true,
}
local DISPATCHED_NTH = {5, 15, 60}
local DISPATCHED_NTH_SET = {[5] = true, [15] = true, [60] = true}

local needs_replay = false

local function replay_sources()
  needs_replay = false
  local sources, order = rawget(storage, "__fle_src"), rawget(storage, "__fle_order")
  if not (sources and order) then return end
  -- storage as seen by replayed code: reads as usual, functions/runtime tables go to
  -- fle_runtime, data writes are dropped (the loaded save already contains them)
  local storage_view = setmetatable({}, {
    __index = function(_, key)
      local v = rawget(storage, key)
      if v ~= nil then return v end
      return fle_runtime[key]
    end,
    __newindex = function(_, key, value)
      if type(value) == "function" or RUNTIME_TABLES[key] then fle_runtime[key] = value end
    end,
  })
  local env = setmetatable({storage = storage_view}, {__index = _G})
  for _, name in ipairs(order) do
    local src = sources[name]
    if src then
      local chunk = load(src, "=" .. name, "t", env)
      if chunk then pcall(chunk) end
    end
  end
end

local function dispatch_event(event)
  if needs_replay then replay_sources() end
  local h = fle_runtime.handlers[event.name]
  if h then return h(event) end
end

local function make_nth_dispatcher(n)
  return function(event)
    if needs_replay then replay_sources() end
    local h = fle_runtime.nth[n]
    if h then return h(event) end
  end
end

local function register_dispatchers()
  for id in pairs(DISPATCHED_EVENTS) do real_script.on_event(id, dispatch_event) end
  for _, n in ipairs(DISPATCHED_NTH) do real_script.on_nth_tick(n, make_nth_dispatcher(n)) end
end

-- the `script` FLE code sees
script = setmetatable({}, {
  __index = function(_, key)
    if key == "on_event" then
      return function(id, handler, filters)
        local ids = type(id) == "table" and id or {id}
        for _, one in pairs(ids) do
          if DISPATCHED_EVENTS[one] then
            fle_runtime.handlers[one] = handler
          else
            real_script.on_event(one, handler, filters)
          end
        end
      end
    elseif key == "on_nth_tick" then
      return function(n, handler)
        if n and DISPATCHED_NTH_SET[n] then
          fle_runtime.nth[n] = handler
        else
          real_script.on_nth_tick(n, handler)
        end
      end
    end
    return real_script[key]
  end,
})

-- Spectators only: anyone who joins gets the spectator controller (no body), so they
-- cannot block placements, attract biters, or build/mine by accident. FLE agents are
-- character entities, not players, and are unaffected.
local function make_spectator(player)
  if not (player and player.valid) then return end
  if player.controller_type ~= defines.controllers.spectator then
    local body = player.character
    player.set_controller{type = defines.controllers.spectator}
    if body and body.valid then body.destroy() end
  end
  player.print("Spectator mode: this map is played by script. Fly with WASD, open the map with M.")
end

local function register_player_events()
  real_script.on_event(defines.events.on_player_joined_game, function(event)
    make_spectator(game.get_player(event.player_index))
  end)
  real_script.on_event(defines.events.on_player_respawned, function(event)
    make_spectator(game.get_player(event.player_index))
  end)
end

real_script.on_init(function()
  setmetatable(storage, storage_mt)
  register_dispatchers()
  register_player_events()
end)
real_script.on_load(function()
  setmetatable(storage, storage_mt)
  register_dispatchers()
  register_player_events()
  needs_replay = true   -- rebuild FLE's functions on the first tick (game is available then)
end)
