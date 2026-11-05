-- rails: Factorio 2.x rail and train actions (FLE's place_entity cannot place rails: the item is
-- "rail" but the entities are straight-rail / half-diagonal-rail / curved-rail-a / curved-rail-b).
local function unhex(h) return (h:gsub("%x%x", function(c) return string.char(tonumber(c, 16)) end)) end
local function hexout(tag, t)
    local j = helpers.table_to_json(t)
    return tag .. (j:gsub(".", function(ch) return string.format("%02x", ch:byte()) end))
end
local RAILS = {["straight-rail"] = true, ["half-diagonal-rail"] = true, ["curved-rail-a"] = true, ["curved-rail-b"] = true}

local function item_cost(name)
    local p = prototypes.entity[name]
    local it = p and p.items_to_place_this and p.items_to_place_this[1]
    if it then return it.name, it.count or 1 end
    return name, 1
end

-- pieces: [{n, x, y, d}] -> {placed, already, failed: [{i, why}]}
storage.actions.rail_place = function(player_index, pieces_hex, reach)
    local player = storage.agent_characters[player_index]
    local surface = player.surface
    reach = tonumber(reach) or 10
    local pieces = helpers.json_to_table(unhex(pieces_hex)) or {}
    local out = {placed = 0, already = 0, failed = {}}
    for i, p in ipairs(pieces) do
        local why = nil
        local existing = surface.find_entities_filtered{name = p.n, position = {p.x, p.y}, radius = 0.2}
        if #existing > 0 and existing[1].direction == p.d then
            out.already = out.already + 1
        else
            local item, cost = item_cost(p.n)
            local dist = math.sqrt((player.position.x - p.x) ^ 2 + (player.position.y - p.y) ^ 2)
            if not RAILS[p.n] then why = "not a rail piece"
            elseif dist > reach then why = "too far (" .. math.floor(dist) .. ")"
            elseif player.get_item_count(item) < cost then why = "need " .. cost .. " " .. item
            elseif not surface.can_place_entity{name = p.n, position = {p.x, p.y}, direction = p.d, force = player.force,
                                                build_check_type = defines.build_check_type.manual} then
                local by = {}
                for _, b in pairs(surface.find_entities_filtered{position = {p.x, p.y}, radius = 2}) do
                    if b.valid and b.type ~= "character" and b.type ~= "resource" and #by < 2 then
                        by[#by + 1] = b.name .. "@" .. b.position.x .. "," .. b.position.y
                    end
                end
                why = "blocked " .. table.concat(by, " ")
            else
                local e = surface.create_entity{name = p.n, position = {p.x, p.y}, direction = p.d, force = player.force,
                                                raise_built = true}
                if e then
                    player.remove_item{name = item, count = cost}
                    out.placed = out.placed + 1
                else
                    why = "create failed"
                end
            end
        end
        if why then table.insert(out.failed, {i = i, why = why}) end
    end
    return hexout("RAILHEX_", out)
end

-- rails, open ends, stops, trains in a circle
storage.actions.rail_read = function(player_index, x, y, radius)
    local player = storage.agent_characters[player_index]
    local surface = player.surface
    local area = {position = {tonumber(x), tonumber(y)}, radius = tonumber(radius) or 60}
    local out = {rails = 0, open_ends = {}, stops = {}, trains = {}, signals = 0}
    local CDS = {defines.rail_connection_direction.straight, defines.rail_connection_direction.left,
                 defines.rail_connection_direction.right}
    for _, r in pairs(surface.find_entities_filtered{position = area.position, radius = area.radius,
                                                     type = {"straight-rail", "half-diagonal-rail", "curved-rail-a", "curved-rail-b"}}) do
        out.rails = out.rails + 1
        for _, rd in ipairs({defines.rail_direction.front, defines.rail_direction.back}) do
            local any = false
            for _, cd in ipairs(CDS) do
                if r.get_connected_rail{rail_direction = rd, rail_connection_direction = cd} then any = true break end
            end
            if not any and #out.open_ends < 40 then
                local L = r.get_rail_end(rd).location
                table.insert(out.open_ends, {x = L.position.x, y = L.position.y, d = L.direction})
            end
        end
    end
    out.signals = #surface.find_entities_filtered{position = area.position, radius = area.radius,
                                                   type = {"rail-signal", "rail-chain-signal"}}
    for _, s in pairs(surface.find_entities_filtered{position = area.position, radius = area.radius, type = "train-stop"}) do
        local lim = s.trains_limit
        if lim and lim >= 4294967295 then lim = nil end
        table.insert(out.stops, {name = s.backer_name, x = s.position.x, y = s.position.y, d = s.direction,
                                 rail = s.connected_rail ~= nil, limit = lim or -1, priority = s.train_stop_priority,
                                 trains_count = s.trains_count or 0})
    end
    local seen = {}
    local st = {}
    for k, v in pairs(defines.train_state) do st[v] = k end
    for _, l in pairs(surface.find_entities_filtered{position = area.position, radius = area.radius,
                                                     type = {"locomotive", "cargo-wagon", "fluid-wagon"}}) do
        local t = l.train
        if t and not seen[t.id] then
            seen[t.id] = true
            local recs = {}
            pcall(function()
                for _, rec in pairs(t.get_schedule().get_records()) do recs[#recs + 1] = rec.station or "?" end
            end)
            local fr = t.front_stock
            local pes, fuel, ints = nil, {}, {}
            pcall(function() if t.path_end_stop then pes = {name = t.path_end_stop.backer_name, x = t.path_end_stop.position.x, y = t.path_end_stop.position.y} end end)
            local fuel_min, nloc = nil, 0
            pcall(function()
                for _, grp in pairs({t.locomotives.front_movers, t.locomotives.back_movers}) do
                    for _, lo in pairs(grp) do
                        nloc = nloc + 1
                        local inv = lo.get_fuel_inventory()
                        local c = inv.get_item_count()
                        if lo.burner and lo.burner.currently_burning then c = c + 0.5 end
                        fuel_min = fuel_min and math.min(fuel_min, c) or c
                        for _, it in pairs(inv.get_contents()) do fuel[it.name] = (fuel[it.name] or 0) + it.count end
                    end
                end
            end)
            pcall(function() for _, i in pairs(t.get_schedule().get_interrupts()) do ints[#ints + 1] = i.name end end)
            table.insert(out.trains, {id = t.id, state = st[t.state] or tostring(t.state), manual = t.manual_mode,
                                      group = t.group or "", path_end_stop = pes, has_path = t.has_path, fuel = fuel,
                                      fuel_min = fuel_min, locos = nloc,
                                      interrupts = ints,
                                      speed = t.speed, x = fr and fr.position.x, y = fr and fr.position.y,
                                      station = t.station and t.station.backer_name or "", schedule = recs,
                                      cargo = t.get_contents and (function() local c = {} for _, it in pairs(t.get_contents()) do c[it.name] = it.count end return c end)() or {},
                                      stock = #t.carriages})
        end
    end
    return hexout("RAILHEX_", out)
end

-- a locomotive / wagon on the rail at (x, y); fuel = items from the player's inventory
storage.actions.train_place = function(player_index, name, x, y, d, fuel_name, fuel_count)
    local player = storage.agent_characters[player_index]
    local surface = player.surface
    if player.get_item_count(name) < 1 then error("\"no " .. name .. " in the inventory\"") end
    local e = surface.create_entity{name = name, position = {tonumber(x), tonumber(y)}, direction = tonumber(d) or 0,
                                    force = player.force, raise_built = true}
    if not e then error("\"cannot place " .. name .. " at " .. x .. "," .. y .. ": it must stand on straight rail long enough for it\"") end
    player.remove_item{name = name, count = 1}
    local fueled = 0
    if fuel_name and fuel_name ~= "" and (tonumber(fuel_count) or 0) > 0 then
        local inv = e.get_fuel_inventory and e.get_fuel_inventory()
        local have = player.get_item_count(fuel_name)
        local n = math.min(have, tonumber(fuel_count))
        if inv and n > 0 then
            fueled = inv.insert{name = fuel_name, count = n}
            if fueled > 0 then player.remove_item{name = fuel_name, count = fueled} end
        end
    end
    return {x = e.position.x, y = e.position.y, train = e.train and e.train.id or -1, fueled = fueled}
end

storage.actions.train_stop_name = function(player_index, x, y, name)
    local s = storage.agent_characters[player_index].surface.find_entities_filtered{type = "train-stop", position = {tonumber(x), tonumber(y)}, radius = 1.5}[1]
    if not s then error("\"no train stop near " .. x .. "," .. y .. "\"") end
    if name and name ~= "" then s.backer_name = name end
    return hexout("RAILHEX_", {name = s.backer_name})
end


-- the train to act on: by id (exact), else the locomotive nearest (x, y); ambiguous -> error with ids
local function pick_train(surface, x, y, train_id)
    train_id = tonumber(train_id) or 0
    if train_id > 0 then
        local t = game.train_manager.get_train_by_id(train_id)
        if not t then error('"no train with id ' .. train_id .. '"') end
        return t
    end
    local px, py = tonumber(x), tonumber(y)
    local best, bd, ids = nil, 1e9, {}
    for _, l in pairs(surface.find_entities_filtered{type = {"locomotive"}, position = {px, py}, radius = 8}) do
        if l.train then
            local d = (l.position.x - px) ^ 2 + (l.position.y - py) ^ 2
            ids[l.train.id] = true
            if d < bd then best, bd = l, d end
        end
    end
    if not best then
        local near = {}
        for _, l in pairs(surface.find_entities_filtered{type = {"locomotive"}, position = {px, py}, radius = 150}) do
            if l.train and #near < 4 then near[#near + 1] = "train " .. l.train.id .. " at " .. math.floor(l.position.x) .. "," .. math.floor(l.position.y) end
        end
        error('"no locomotive within 8 tiles of ' .. x .. ',' .. y .. (#near > 0 and ("; nearest: " .. table.concat(near, "; ")) or "; none within 150 tiles") .. '"')
    end
    local n, list = 0, {}
    for id in pairs(ids) do n = n + 1 list[#list + 1] = tostring(id) end
    if n > 1 and bd > 2.25 then
        error('"' .. n .. ' trains within 8 tiles of ' .. x .. ',' .. y .. ' (ids ' .. table.concat(list, ", ") ..
              ') and none on that tile: pass train_id= or the locomotive position"')
    end
    return best.train
end

-- records (hex JSON): [{station, wait: [{type, ticks?, compare?}]}]; auto = 1 -> automatic mode
storage.actions.train_schedule = function(player_index, x, y, records_hex, auto, train_id)
    local surface = storage.agent_characters[player_index].surface
    local t = pick_train(surface, x, y, train_id)
    local recs = helpers.json_to_table(unhex(records_hex)) or {}
    local sch = t.get_schedule()
    local list = {}
    for _, r in ipairs(recs) do
        local wc = {}
        for k, w in ipairs(r.wait or {}) do
            local c = {type = w.type, compare_type = (k == 1) and "or" or (w.compare or "or")}
            if w.ticks then c.ticks = w.ticks end
            table.insert(wc, c)
        end
        table.insert(list, {station = r.station, wait_conditions = wc})
    end
    sch.set_records(list)
    if tonumber(auto) == 1 then t.manual_mode = false end
    local names = {}
    for _, r in pairs(sch.get_records()) do names[#names + 1] = r.station end
    return hexout("RAILHEX_", {train = t.id, records = names, manual = t.manual_mode})
end

-- a train stop beside a straight rail: travel direction d, the stop 2 tiles to its right
storage.actions.rail_stop = function(player_index, x, y, d, name)
    local player = storage.agent_characters[player_index]
    if player.get_item_count("train-stop") < 1 then error("\"no train-stop in the inventory\"") end
    local e = player.surface.create_entity{name = "train-stop", position = {tonumber(x), tonumber(y)}, direction = tonumber(d) or 0,
                                           force = player.force, raise_built = true}
    if not e then error("\"cannot place a train stop at " .. x .. "," .. y .. "\"") end
    player.remove_item{name = "train-stop", count = 1}
    if name and name ~= "" then e.backer_name = name end
    return hexout("RAILHEX_", {x = e.position.x, y = e.position.y, name = e.backer_name, rail = e.connected_rail ~= nil})
end


-- ---- trains v2 (TRAINS.md gap list) ----
local function find_stop(surface, x, y)
    return surface.find_entities_filtered{type = "train-stop", position = {tonumber(x), tonumber(y)}, radius = 2}[1]
end

local function stop_info(s)
    local ids = {}
    pcall(function() for _, t in pairs(s.get_train_stop_trains()) do ids[#ids + 1] = t.id end end)
    local lim = s.trains_limit
    if lim and lim >= 4294967295 then lim = nil end
    return {name = s.backer_name, x = s.position.x, y = s.position.y, limit = lim or -1,
            priority = s.train_stop_priority, trains_count = s.trains_count or 0, trains = ids}
end

-- limit: -1 = no limit, -2 = unchanged, 0 = closed; priority: -2 = unchanged; enable: 1/0/-2
storage.actions.rail_stop_config = function(player_index, x, y, limit, priority, enable)
    local s = find_stop(storage.agent_characters[player_index].surface, x, y)
    if not s then error("\"no train stop near " .. x .. "," .. y .. "\"") end
    limit, priority, enable = tonumber(limit) or -2, tonumber(priority) or -2, tonumber(enable) or -2
    if limit == -1 then s.trains_limit = nil elseif limit >= 0 then s.trains_limit = limit end
    if priority >= 0 then s.train_stop_priority = math.min(255, priority) end
    if enable == 0 then
        storage.stop_saved_limit = storage.stop_saved_limit or {}
        storage.stop_saved_limit[s.unit_number] = s.trains_limit
        s.trains_limit = 0
    elseif enable == 1 and s.trains_limit == 0 then
        local saved = storage.stop_saved_limit and storage.stop_saved_limit[s.unit_number]
        s.trains_limit = saved
    end
    return hexout("RAILHEX_", stop_info(s))
end

-- wait conditions: verbatim WaitCondition tables; the old short form {type, ticks} still works;
-- compare_type defaults to the game's "and"
local function wait_list(ws)
    local out = {}
    for k, w in ipairs(ws or {}) do
        local c = {}
        for key, v in pairs(w) do c[key] = v end
        if c.compare == nil and c.compare_type == nil then c.compare_type = "and" end
        if c.compare then c.compare_type = c.compare c.compare = nil end
        if k == 1 then c.compare_type = c.compare_type or "and" end
        table.insert(out, c)
    end
    return out
end

local function record_list(rs)
    local out = {}
    for _, r in ipairs(rs or {}) do
        local rec = {station = r.station, wait_conditions = wait_list(r.wait_conditions or r.wait),
                     temporary = r.temporary}
        if r.rail then rec.rail = r.rail end
        table.insert(out, rec)
    end
    return out
end

-- spec (hex JSON): {records, interrupts: [{name, conditions, targets, inside_interrupt}], group, auto}
storage.actions.rail_schedule2 = function(player_index, x, y, spec_hex, train_id)
    local surface = storage.agent_characters[player_index].surface
    local t = pick_train(surface, x, y, train_id)
    local spec = helpers.json_to_table(unhex(spec_hex)) or {}
    if spec.group and spec.group ~= "" then t.group = spec.group end
    local sch = t.get_schedule()
    if spec.records then sch.set_records(record_list(spec.records)) end
    if spec.interrupts then
        local ints = {}
        for _, i in ipairs(spec.interrupts) do
            table.insert(ints, {name = i.name, conditions = wait_list(i.conditions), targets = record_list(i.targets),
                                inside_interrupt = i.inside_interrupt and true or false})
        end
        sch.set_interrupts(ints)
    end
    if spec.auto == nil or spec.auto then t.manual_mode = false end
    local names, ints = {}, {}
    for _, r in pairs(sch.get_records()) do names[#names + 1] = r.station or "(rail)" end
    pcall(function() for _, i in pairs(sch.get_interrupts()) do ints[#ints + 1] = i.name end end)
    return hexout("RAILHEX_", {train = t.id, records = names, interrupts = ints, group = t.group or "",
                               manual = t.manual_mode})
end

-- a rail / chain signal for trains travelling travel_d at the straight rail END (x, y): right of
-- travel, facing travel (measured on the lab: north -> (x+1.5, y-0.5) UP; south -> (x-1.5, y+0.5) DOWN)
local SIG_OFF = {[0] = {1.5, -0.5}, [4] = {0.5, 1.5}, [8] = {-1.5, 0.5}, [12] = {-0.5, -1.5}}
storage.actions.rail_signal = function(player_index, x, y, travel_d, chain)
    local player = storage.agent_characters[player_index]
    local name = (tonumber(chain) == 1) and "rail-chain-signal" or "rail-signal"
    local d = tonumber(travel_d) or 0
    local off = SIG_OFF[d]
    if not off then error("\"rails signal: travel direction must be 0/4/8/12 (straight ends); got " .. tostring(travel_d) .. "\"") end
    if player.get_item_count(name) < 1 then error("\"no " .. name .. " in the inventory\"") end
    local pos = {tonumber(x) + off[1], tonumber(y) + off[2]}
    -- measured: the signal stands right of travel and FACES the oncoming train (direction
    -- travel+8); with direction = travel it is placed but attaches to no rail
    local e = player.surface.create_entity{name = name, position = pos, direction = (d + 8) % 16, force = player.force, raise_built = true}
    if not e then error("\"cannot place " .. name .. " at " .. pos[1] .. "," .. pos[2] .. "\"") end
    local rails = 0
    pcall(function() rails = #e.get_connected_rails() end)
    if rails == 0 then
        e.destroy()
        error("\"" .. name .. " at " .. pos[1] .. "," .. pos[2] .. " does not attach to a rail: (x, y) must be a straight rail END and d the travel direction\"")
    end
    player.remove_item{name = name, count = 1}
    return {x = e.position.x, y = e.position.y, dir = e.direction, rails = rails}
end

-- clear an area of rail entities back into the inventory (trains are stopped first)
storage.actions.rail_remove = function(player_index, x, y, radius)
    local player = storage.agent_characters[player_index]
    local surface = player.surface
    local area = {position = {tonumber(x), tonumber(y)}, radius = tonumber(radius) or 20}
    local out = {stock = 0, stops = 0, signals = 0, rails = 0, left = 0}
    local groups = {
        {"stock", {"locomotive", "cargo-wagon", "fluid-wagon", "artillery-wagon"}},
        {"stops", {"train-stop"}},
        {"signals", {"rail-signal", "rail-chain-signal"}},
        {"rails", {"straight-rail", "curved-rail-a", "curved-rail-b", "half-diagonal-rail", "rail-ramp", "rail-support"}},
    }
    for _, g in ipairs(groups) do
        local ok = pcall(function()
            for _, e in pairs(surface.find_entities_filtered{position = area.position, radius = area.radius, type = g[2], force = player.force}) do
                if e.valid then
                    if e.train then e.train.manual_mode = true end
                    if player.mine_entity(e, true) then out[g[1]] = out[g[1]] + 1 else out.left = out.left + 1 end
                end
            end
        end)
    end
    return hexout("RAILHEX_", out)
end

-- a whole consist: spec "1-2" (locos-wagons) or "1-2-1"; the first loco at (x, y) facing d
storage.actions.rail_consist = function(player_index, x, y, d, spec, fuel_name, fuel_count)
    local player = storage.agent_characters[player_index]
    local surface = player.surface
    d = tonumber(d) or 0
    local parts = {}
    for n in string.gmatch(spec or "1-1", "%d+") do parts[#parts + 1] = tonumber(n) end
    local seq = {}
    for i = 1, parts[1] or 1 do seq[#seq + 1] = "locomotive" end
    for i = 1, parts[2] or 0 do seq[#seq + 1] = "cargo-wagon" end
    for i = 1, parts[3] or 0 do seq[#seq + 1] = "locomotive-back" end
    local V = {[0] = {0, 1}, [4] = {-1, 0}, [8] = {0, -1}, [12] = {1, 0}}   -- "behind" the front
    local v = V[d]
    if not v then error("\"rails consist: direction must be 0/4/8/12\"") end
    -- fuel_count is the TOTAL: split evenly over every locomotive (the rear one pulls on the way back)
    local nloco = 0
    for _, nm in ipairs(seq) do if nm ~= "cargo-wagon" then nloco = nloco + 1 end end
    local per = 0
    if fuel_name and fuel_name ~= "" and (tonumber(fuel_count) or 0) > 0 and nloco > 0 then
        local have = player.get_item_count(fuel_name)
        local total = math.min(have, tonumber(fuel_count))
        per = math.floor(total / nloco)
        if per < 20 then
            error("\"rails consist: " .. nloco .. " locomotives need at least 20 " .. fuel_name .. " each: pass fuel_count>=" ..
                  (20 * nloco) .. " (the TOTAL, split evenly) and hold that many (the character holds " .. have .. ")\"")
        end
    end
    local made, tid = {}, -1
    for i, nm in ipairs(seq) do
        local name, dir = nm, d
        if nm == "locomotive-back" then name, dir = "locomotive", (d + 8) % 16 end
        if player.get_item_count(name) < 1 then error("\"no " .. name .. " in the inventory for the consist\"") end
        local pos = {tonumber(x) + v[1] * 7 * (i - 1), tonumber(y) + v[2] * 7 * (i - 1)}
        local e = surface.create_entity{name = name, position = pos, direction = dir, force = player.force, raise_built = true}
        if not e then error("\"cannot place " .. name .. " at " .. pos[1] .. "," .. pos[2] .. " (needs straight rail)\"") end
        player.remove_item{name = name, count = 1}
        if name == "locomotive" and fuel_name and fuel_name ~= "" then
            local inv = e.get_fuel_inventory()
            local n = math.min(player.get_item_count(fuel_name), per)
            if inv and n > 0 then
                local got = inv.insert{name = fuel_name, count = n}
                if got > 0 then player.remove_item{name = fuel_name, count = got} end
            end
        end
        local fu = nil
        if name == "locomotive" then pcall(function() fu = e.get_fuel_inventory().get_item_count() end) end
        made[#made + 1] = {n = name, x = e.position.x, y = e.position.y, fuel = fu}
        tid = e.train and e.train.id or tid
    end
    local t = nil
    for _, m in ipairs(made) do
        local e = surface.find_entities_filtered{position = {m.x, m.y}, radius = 0.5, type = {"locomotive", "cargo-wagon"}}[1]
        if e and e.train then t = e.train end
    end
    return hexout("RAILHEX_", {train = t and t.id or tid, carriages = t and #t.carriages or #made, made = made})
end

-- the tool entry point: rails(op, ...)
storage.actions.rails = function(player_index, op, ...)
    local f = storage.actions[op]
    if not f then error("\"rails: unknown op " .. tostring(op) .. "\"") end
    return f(player_index, ...)
end
