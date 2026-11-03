-- events: a queue of what happened in the world since the last drain (deaths of our entities
-- with everything needed to rebuild them, damage, finished research, enemy attack groups).
-- The handlers go through the scenario's dispatchers (control.lua DISPATCHED_EVENTS), so they
-- are identical on every peer.
storage.ev = storage.ev or {q = {}, dmg = {}, dropped = 0}

local function ev_push(e)
    local q = storage.ev.q
    if #q >= 2000 then table.remove(q, 1) storage.ev.dropped = storage.ev.dropped + 1 end
    table.insert(q, e)
end

local function ev_rec(ent)
    local r = {n = ent.name, x = ent.position.x, y = ent.position.y, d = ent.direction, type = ent.type}
    if ent.type == "underground-belt" then r.t = ent.belt_to_ground_type end
    if ent.type == "assembling-machine" then
        local ok, rc = pcall(function() return ent.get_recipe() end)
        if ok and rc then r.r = rc.name end
    end
    return r
end

script.on_event(defines.events.on_entity_died, function(ev)
    local e = ev.entity
    if not (e and e.valid) then return end
    if e.force and e.force.name == "player" then
        local r = ev_rec(e)
        r.k = "died"
        r.tick = ev.tick
        if ev.cause and ev.cause.valid then r.cause = ev.cause.name end
        ev_push(r)
    elseif e.type == "unit-spawner" or e.type == "turret" then
        ev_push({k = "enemy_structure_killed", n = e.name, x = e.position.x, y = e.position.y, tick = ev.tick})
    end
end)

script.on_event(defines.events.on_entity_damaged, function(ev)
    local e = ev.entity
    if not (e and e.valid and e.force and e.force.name == "player") then return end
    local key = e.unit_number or 0
    local last = storage.ev.dmg[key]
    if last and ev.tick - last < 600 then return end   -- at most once per 10 s per entity
    storage.ev.dmg[key] = ev.tick
    ev_push({k = "damaged", n = e.name, x = e.position.x, y = e.position.y, hp = e.health, tick = ev.tick,
             cause = (ev.cause and ev.cause.valid) and ev.cause.name or nil})
end)

script.on_event(defines.events.on_research_finished, function(ev)
    ev_push({k = "research", n = ev.research.name, tick = ev.tick})
end)

script.on_event(defines.events.on_unit_group_finished_gathering, function(ev)
    local g = ev.group
    if g and g.valid then
        ev_push({k = "attack_group", x = g.position.x, y = g.position.y, size = #g.members, tick = ev.tick})
    end
end)

storage.actions.events = function(player_index, drain)
    local q = storage.ev.q
    local out = {events = q, dropped = storage.ev.dropped, tick = game.tick}
    local j = helpers.table_to_json(out)
    if drain then storage.ev.q = {} storage.ev.dropped = 0 end
    return "EVHEX_" .. (j:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end
