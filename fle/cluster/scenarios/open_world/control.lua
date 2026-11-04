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
  -- Data writes are dropped only WHILE the sources replay (their top-level setup is already
  -- in the save). The functions defined here keep this view as their `storage`, so after the
  -- replay it must write through to the real storage, or every action on a joined client
  -- would silently lose its writes (storage.walking_queues = ..., storage.paths = ...) and
  -- the clients state would drift from the servers: a desync.
  local replaying = true
  local storage_view = setmetatable({}, {
    __index = function(_, key)
      local v = rawget(storage, key)
      if v ~= nil then return v end
      return fle_runtime[key]
    end,
    __newindex = function(_, key, value)
      if type(value) == "function" or RUNTIME_TABLES[key] then
        fle_runtime[key] = value
      elseif not replaying then
        storage[key] = value
      end
    end,
    __pairs = function() return pairs(storage) end,
  })
  -- globals the sources define (dump, serpent helpers, ...) must land in _G as they did on the
  -- server, or later console commands that use them fail on the joined client only
  local env = setmetatable({storage = storage_view}, {__index = _G, __newindex = _G})
  for _, name in ipairs(order) do
    local src = sources[name]
    if src then
      fle_runtime.current_src = name
      local chunk = load(src, "=" .. name, "t", env)
      if chunk then pcall(chunk) end
    end
  end
  fle_runtime.current_src = nil
  replaying = false
end

-- A runtime handler that throws must never take the server down (Factorio stops a
-- multiplayer game on any script error in an event): run it protected, log the error and
-- queue it for the agents (tools/agent/events reads storage.ev.q).
local function report_handler_error(where, err)
  local msg = tostring(err)
  log("FLE handler error in " .. where .. ": " .. msg)
  local ev = rawget(storage, "ev")
  if ev and ev.q then
    if #ev.q >= 2000 then table.remove(ev.q, 1) end
    table.insert(ev.q, {k = "script_error", where = where, msg = string.sub(msg, 1, 300), tick = game and game.tick or 0})
  end
end

-- Several scripts may register the same event (alerts.lua and utils.lua both use on_tick).
-- Handlers are kept per SOURCE SCRIPT and run in sorted source order, so the set and the
-- order are the same on the server (scripts loaded and reloaded over time) and on a client
-- that replays the sources once: the last registration of each script wins, nothing else.
local function run_all(tbl, where, event)
  if not tbl then return end
  if type(tbl) == "function" then   -- a pre-keyed save: one handler
    local ok, err = pcall(tbl, event)
    if not ok then report_handler_error(where, err) end
    return
  end
  local keys = {}
  for k in pairs(tbl) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do
    local ok, err = pcall(tbl[k], event)
    if not ok then report_handler_error(where .. " (" .. k .. ")", err) end
  end
end

local function dispatch_event(event)
  if needs_replay then replay_sources() end
  run_all(fle_runtime.handlers[event.name], "event " .. tostring(event.name), event)
end

local function make_nth_dispatcher(n)
  return function(event)
    if needs_replay then replay_sources() end
    run_all(fle_runtime.nth[n], "nth_tick " .. n, event)
  end
end

local function keyed_set(tbl, id, handler)
  local cur = tbl[id]
  if type(cur) ~= "table" then cur = {} tbl[id] = cur end
  cur[fle_runtime.current_src or "_"] = handler
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
            keyed_set(fle_runtime.handlers, one, handler)
          else
            real_script.on_event(one, handler, filters)
          end
        end
      end
    elseif key == "on_nth_tick" then
      return function(n, handler)
        if n and DISPATCHED_NTH_SET[n] then
          keyed_set(fle_runtime.nth, n, handler)
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
