-- alarm: silent circuit alarms built from real entities (sensor -> combinator -> programmable
-- speaker with volume 0, "show alert" + "show on map" + custom text). The engine evaluates them:
-- no per-tick script cost. storage.alarms keeps what we built so `list` can report state.
local function ah(t)
    local j = helpers.table_to_json(t)
    return "ALRMHEX_" .. (j:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end
storage.alarms = storage.alarms or {}
local R = defines.wire_connector_id.circuit_red
local CIN = defines.wire_connector_id.combinator_input_red
local COUT = defines.wire_connector_id.combinator_output_red
local A = {}

local function take(player, name, n)
    local inv = player.get_main_inventory()
    local have = inv and inv.get_item_count(name) or 0
    if have < n then return false end
    inv.remove{name = name, count = n}
    return true
end

local function need(player, list)
    local miss = {}
    local inv = player.get_main_inventory()
    for name, n in pairs(list) do
        local h = inv and inv.get_item_count(name) or 0
        if h < n then miss[#miss + 1] = name .. " x" .. (n - h) end
    end
    if #miss > 0 then error('"alarm: need in inventory: ' .. table.concat(miss, ", ") .. '"') end
end

-- a free tile near (x, y), preferring one inside an electric pole's supply area (speakers need power)
local function spot(surf, name, x, y, r)
    r = r or 5
    local poles = surf.find_entities_filtered{position = {x, y}, radius = r + 12, type = "electric-pole"}
    local function powered(px, py)
        for _, p in ipairs(poles) do
            local d = 2.5
            pcall(function() d = p.prototype.get_supply_area_distance(p.quality) end)
            if math.abs(p.position.x - px) <= d and math.abs(p.position.y - py) <= d then return true end
        end
        return false
    end
    local first
    local cx, cy = math.floor(x) + 0.5, math.floor(y) + 0.5
    for rad = 1, r do
        for dx = -rad, rad do
            for dy = -rad, rad do
                if math.max(math.abs(dx), math.abs(dy)) == rad then
                    local px, py = cx + dx, cy + dy
                    if surf.can_place_entity{name = name, position = {px, py}, build_check_type = defines.build_check_type.manual} then
                        if powered(px, py) then return {x = px, y = py} end
                        first = first or {x = px, y = py}
                    end
                end
            end
        end
    end
    return first or surf.find_non_colliding_position(name, {x, y}, r, 1, true)
end

local function place(player, name, pos, dir)
    local e = player.surface.create_entity{name = name, position = pos, force = player.force, direction = dir,
                                           raise_built = true}
    if not e then error('"alarm: could not place ' .. name .. ' at ' .. pos.x .. ',' .. pos.y .. '"') end
    take(player, name, 1)
    return e
end

local function speaker(player, near, text, icon, cond)
    local p = spot(player.surface, "programmable-speaker", near.x, near.y, 7)
    if not p then error('"alarm: no free tile for a speaker near ' .. near.x .. ',' .. near.y .. '"') end
    local s = place(player, "programmable-speaker", p)
    s.parameters = {playback_volume = 0, playback_mode = "local", allow_polyphony = false}
    s.alert_parameters = {show_alert = true, show_on_map = true, alert_message = text,
                          icon_signal_id = icon and {type = "item", name = icon} or nil}
    local cb = s.get_or_create_control_behavior()
    cb.circuit_condition = cond
    cb.circuit_parameters = {signal_value_is_pitch = false, instrument_id = 1, note_id = 1}
    return s
end

local function wire(a, ida, b, idb)
    return a.get_wire_connector(ida, true).connect_to(b.get_wire_connector(idb, true), false)
end

local function record(kind, text, ents, cond_kind, n)
    local id = #storage.alarms + 1
    local units = {}
    for _, e in ipairs(ents) do units[#units + 1] = e.unit_number end
    storage.alarms[id] = {id = id, kind = kind, text = text, speaker = ents[1], ents = ents, cond = cond_kind, n = n}
    return id, units
end

-- contamination: belts (read contents, hold) + constant combinator (-1e6 per allowed item) -> speaker "anything > 0"
A.contamination = function(player, spec)
    local surf = player.surface
    if not player.force.technologies["circuit-network"].researched then error('"alarm: research circuit-network first"') end
    need(player, {["programmable-speaker"] = 1, ["constant-combinator"] = 1})
    local belts = {}
    for _, t in ipairs(spec.tiles or {}) do
        local b = surf.find_entities_filtered{position = {t[1], t[2]}, radius = 0.4, type = "transport-belt", force = player.force}[1]
        if b then belts[#belts + 1] = b end
    end
    if #belts == 0 then error('"alarm: no plain belt on the sensor tiles (undergrounds/splitters cannot read)"') end
    for _, b in ipairs(belts) do
        local cb = b.get_or_create_control_behavior()
        cb.read_contents = true
        cb.read_contents_mode = defines.control_behavior.transport_belt.content_read_mode.hold
    end
    for i = 2, #belts do wire(belts[i - 1], R, belts[i], R) end
    local b0 = belts[1].position
    local cp = spot(surf, "constant-combinator", b0.x, b0.y, 5)
    local cc = place(player, "constant-combinator", cp)
    local sec = cc.get_or_create_control_behavior().get_section(1) or cc.get_or_create_control_behavior().add_section()
    for i, it in ipairs(spec.allowed or {}) do
        sec.set_slot(i, {value = {type = "item", name = it, quality = "normal"}, min = -1000000})
    end
    local s = speaker(player, cp, spec.text or "CONTAMINATED", spec.icon,
                      {first_signal = {type = "virtual", name = "signal-anything"}, comparator = ">", constant = 0})
    wire(belts[1], R, cc, R)
    wire(cc, R, s, R)
    local id, units = record("contamination", spec.text, {s, cc}, "anything>0")
    return {id = id, units = units, speaker = {s.position.x, s.position.y}, powered = s.is_connected_to_electric_network(), belts = #belts}
end

-- low: a container / accumulator / train stop -> arithmetic (each*1 -> A, the sum) -> speaker "A < n"
A.low = function(player, spec)
    local surf = player.surface
    if not player.force.technologies["circuit-network"].researched then error('"alarm: research circuit-network first"') end
    local src = surf.find_entities_filtered{position = {spec.x, spec.y}, radius = 0.9, force = player.force,
                                            type = {"container", "logistic-container", "accumulator", "train-stop"}}[1]
    if not src then error('"alarm: no chest/accumulator/train stop at ' .. spec.x .. ',' .. spec.y .. '"') end
    local n = spec.n or 1
    if src.type == "accumulator" then
        need(player, {["programmable-speaker"] = 1})
        local cb = src.get_or_create_control_behavior()
        pcall(function() cb.read_charge = true end)
        local s = speaker(player, src.position, spec.text or "LOW POWER", spec.icon,
                          {first_signal = {type = "virtual", name = "signal-A"}, comparator = "<", constant = n})
        pcall(function() cb.output_signal = {type = "virtual", name = "signal-A"} end)
        wire(src, R, s, R)
        local id, units = record("power", spec.text, {s}, "A<n", n)
        return {id = id, units = units, speaker = {s.position.x, s.position.y}, powered = s.is_connected_to_electric_network()}
    end
    if src.type == "train-stop" then
        need(player, {["programmable-speaker"] = 1})
        local cb = src.get_or_create_control_behavior()
        cb.read_trains_count = true
        cb.trains_count_signal = {type = "virtual", name = "signal-A"}
        local s = speaker(player, src.position, spec.text or "NO TRAIN", spec.icon,
                          {first_signal = {type = "virtual", name = "signal-A"}, comparator = "<", constant = n})
        wire(src, R, s, R)
        local id, units = record("train", spec.text, {s}, "A<n", n)
        return {id = id, units = units, speaker = {s.position.x, s.position.y}, powered = s.is_connected_to_electric_network()}
    end
    need(player, {["programmable-speaker"] = 1, ["arithmetic-combinator"] = 1})
    local ap = spot(surf, "arithmetic-combinator", src.position.x, src.position.y, 5)
    local ac = place(player, "arithmetic-combinator", ap)
    local acb = ac.get_or_create_control_behavior()
    acb.parameters = {first_signal = {type = "virtual", name = "signal-each"}, second_constant = 1, operation = "*",
                      output_signal = {type = "virtual", name = "signal-A"}}
    local s = speaker(player, ap, spec.text or "LOW", spec.icon,
                      {first_signal = {type = "virtual", name = "signal-A"}, comparator = spec.above and ">" or "<", constant = n})
    wire(src, R, ac, CIN)
    wire(ac, COUT, s, R)
    local id, units = record(spec.kind or "low", spec.text, {s, ac}, spec.above and "A>n" or "A<n", n)
    return {id = id, units = units, speaker = {s.position.x, s.position.y}, powered = s.is_connected_to_electric_network()}
end

-- train_fuel: locomotives have no circuit output for fuel, so this one is checked when alarms are
-- read (no per-tick cost); a firing one is also pushed as a custom alert to connected players
A.train_fuel = function(player, spec)
    local id = #storage.alarms + 1
    storage.alarms[id] = {id = id, kind = "train_fuel", text = spec.text or "TRAIN FUEL", cond = "train_fuel", n = spec.n or 10,
                          train = spec.train}
    return {id = id, units = {}, speaker = nil, powered = true}
end

local function train_fuel_state(a)
    local low = {}
    for _, t in pairs(game.train_manager.get_trains{surface = game.surfaces[1]}) do
        if not a.train or a.train == t.id then
            for _, grp in pairs({t.locomotives.front_movers, t.locomotives.back_movers}) do
                for _, lo in pairs(grp) do
                    local c = lo.get_fuel_inventory().get_item_count()
                    if c < (a.n or 10) then low[#low + 1] = {t.id, lo.position.x, lo.position.y, c, lo} end
                end
            end
        end
    end
    local first = low[1]
    if first then
        for _, pl in pairs(game.connected_players) do
            pcall(function() pl.add_custom_alert(first[5], {type = "item", name = "coal"}, (a.text or "TRAIN FUEL") .. ": train " .. first[1] .. " loco has " .. first[4], true) end)
        end
    end
    return {id = a.id, kind = a.kind, text = a.text, x = first and first[2] or 0, y = first and first[3] or 0,
            active = first ~= nil, value = first and ("train " .. first[1] .. " loco fuel " .. first[4] .. " (" .. #low .. " low)") or nil, powered = true}
end

-- what the alarm watches: the entities wired to its input side (the combinator input, or the
-- speaker itself when nothing sits between); none left = the target is gone (stale alarm)
local function target_of(a)
    local own = {}
    for _, e in ipairs(a.ents or {}) do if e.valid then own[e.unit_number or -1] = true end end
    local probe = (a.ents and a.ents[2] and a.ents[2].valid and a.ents[2].type == "arithmetic-combinator") and {a.ents[2], CIN} or {a.speaker, R}
    local tgt, n = nil, 0
    pcall(function()
        local wc = probe[1].get_wire_connector(probe[2], false)
        if wc then
            for _, c in pairs(wc.connections) do
                local o = c.target and c.target.owner
                if o and o.valid and not own[o.unit_number or -1] then
                    n = n + 1
                    tgt = tgt or o
                end
            end
        end
    end)
    return tgt, n
end

local function state(a)
    if a.cond == "train_fuel" then return train_fuel_state(a) end
    local s = a.speaker
    if not (s and s.valid) then return nil end
    local net = s.get_circuit_network(R)
    local sig = net and net.signals or {}
    local active, worst = false, nil
    if a.cond == "anything>0" then
        for _, v in ipairs(sig) do if v.count > 0 then active = true worst = v.signal.name break end end
    else
        local A_ = 0
        for _, v in ipairs(sig) do if v.signal.name == "signal-A" then A_ = v.count end end
        if a.cond == "A>n" then active = A_ > (a.n or 0) else active = A_ < (a.n or 1) end
        worst = A_
    end
    local tgt, ntg = target_of(a)
    return {id = a.id, kind = a.kind, text = a.text, x = s.position.x, y = s.position.y, active = active, value = worst,
            powered = s.is_connected_to_electric_network() and (s.energy or 0) > 0,
            tx = tgt and tgt.position.x, ty = tgt and tgt.position.y, tn = tgt and tgt.name, stale = ntg == 0}
end

local function remove_alarm(player, id)
    local a = storage.alarms[id]
    if not a then return 0 end
    local n = 0
    for _, e in ipairs(a.ents or {}) do
        if e.valid then
            local nm = e.name
            if e.destroy() then n = n + 1 player.insert{name = nm, count = 1} end
        end
    end
    storage.alarms[id] = nil
    return n
end

A.list = function(player, spec)
    local out, pruned = {}, {}
    for id, a in pairs(storage.alarms) do
        local st = state(a)
        if st and st.stale and spec.prune then
            -- the watched entity is gone (chest removed, row retired): speaker + combinators go too
            pruned[#pruned + 1] = {id = id, text = st.text, x = st.x, y = st.y, removed = remove_alarm(player, id)}
        elseif st then
            if not spec.active_only or st.active then out[#out + 1] = st end
        else
            storage.alarms[id] = nil
        end
    end
    return {alarms = out, pruned = pruned}
end

A.remove = function(player, spec)
    return {removed = remove_alarm(player, spec.id)}
end

storage.actions.alarm = function(player_index, op, spec_hex)
    local player = storage.agent_characters[player_index]
    local function unhex(h) return (h:gsub("%x%x", function(c) return string.char(tonumber(c, 16)) end)) end
    local f = A[op]
    if not f then error('"alarm: unknown op ' .. tostring(op) .. '"') end
    return ah(f(player, helpers.json_to_table(unhex(spec_hex or "")) or {}))
end
