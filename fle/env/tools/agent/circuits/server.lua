-- circuits: wires, combinators, control behaviour, rail graph (Factorio 2.x). Ops via circuits(op, ...).
local function c_unhex(h) return (h:gsub("%x%x", function(c) return string.char(tonumber(c, 16)) end)) end
local function c_out(t)
    local j = helpers.table_to_json(t)
    return "CIRCHEX_" .. (j:gsub(".", function(ch) return string.format("%02x", ch:byte()) end))
end
local function c_find(surface, x, y, name)
    local f = {position = {tonumber(x), tonumber(y)}, radius = 0.7}
    if name and name ~= "" then f.name = name end
    for _, e in pairs(surface.find_entities_filtered(f)) do
        if e.valid and e.type ~= "character" and e.type ~= "resource" then return e end
    end
    return nil
end
local CONN = {red = defines.wire_connector_id.circuit_red, green = defines.wire_connector_id.circuit_green}
local CONN_C = {red_input = defines.wire_connector_id.combinator_input_red, green_input = defines.wire_connector_id.combinator_input_green,
                red_output = defines.wire_connector_id.combinator_output_red, green_output = defines.wire_connector_id.combinator_output_green}
local function connector(e, color, side)
    local is_comb = e.type == "arithmetic-combinator" or e.type == "decider-combinator" or e.type == "selector-combinator"
    local id
    if tonumber(color) then id = tonumber(color)
    elseif is_comb then id = CONN_C[color .. "_" .. (side ~= "" and side or "input")]
    else id = CONN[color] end
    if not id then error("\"circuits: bad wire color/side " .. tostring(color) .. "/" .. tostring(side) .. "\"") end
    return e.get_wire_connector(id, true)
end

local C = {}
-- wire: spec {a = {x, y, name?, side?}, b = {...}, color = "red"|"green", disconnect = bool}
C.wire = function(player, spec)
    local s = player.surface
    local a, b = c_find(s, spec.a.x, spec.a.y, spec.a.name), c_find(s, spec.b.x, spec.b.y, spec.b.name)
    if not a or not b then error("\"circuits wire: no entity at " .. (a and "b" or "a") .. "\"") end
    local ca, cb = connector(a, spec.color or "red", spec.a.side or ""), connector(b, spec.color or "red", spec.b.side or "")
    local ok
    if spec.disconnect then ok = ca.disconnect_from(cb) else ok = ca.connect_to(cb, false) end
    return {ok = ok and true or false, a = a.name, b = b.name}
end
-- signals on the network at an entity (color, side)
C.signals = function(player, spec)
    local e = c_find(player.surface, spec.x, spec.y, spec.name)
    if not e then error("\"circuits signals: no entity there\"") end
    local id
    local is_comb = e.type == "arithmetic-combinator" or e.type == "decider-combinator" or e.type == "selector-combinator"
    if is_comb then id = CONN_C[(spec.color or "red") .. "_" .. (spec.side or "output")] else id = CONN[spec.color or "red"] end
    local net = e.get_circuit_network(id)
    local out = {}
    if net and net.signals then
        for _, sg in pairs(net.signals) do out[#out + 1] = {type = sg.signal.type or "item", name = sg.signal.name, count = sg.count} end
    end
    return {network = net and net.network_id or -1, signals = out}
end
-- constant combinator: spec {x, y, signals = [{type?, name, count}], enabled?}
C.constant = function(player, spec)
    local e = c_find(player.surface, spec.x, spec.y, "constant-combinator")
    if not e then error("\"circuits constant: no constant combinator there\"") end
    local cb = e.get_or_create_control_behavior()
    local sec = cb.get_section(1) or cb.add_section()
    for i = 1, sec.filters_count do sec.clear_slot(i) end
    for i, sg in ipairs(spec.signals or {}) do
        sec.set_slot(i, {value = {type = sg.type or "item", name = sg.name, quality = "normal"}, min = sg.count or 1})
    end
    if spec.enabled ~= nil then cb.enabled = spec.enabled end
    return {slots = #(spec.signals or {})}
end
-- arithmetic / decider: spec {x, y, parameters = {...verbatim 2.x...}}
C.arithmetic = function(player, spec)
    local e = c_find(player.surface, spec.x, spec.y, "arithmetic-combinator")
    if not e then error("\"circuits arithmetic: none there\"") end
    e.get_or_create_control_behavior().parameters = spec.parameters
    return {ok = true}
end
C.decider = function(player, spec)
    local e = c_find(player.surface, spec.x, spec.y, "decider-combinator")
    if not e then error("\"circuits decider: none there\"") end
    e.get_or_create_control_behavior().parameters = spec.parameters
    return {ok = true}
end
-- inserters around an entity and what they move: [{x, y, n, pick = {n, x, y}, drop = {n, x, y}}]
-- (spec.into = only those dropping into it, spec.from = only those taking from it)
C.inserters = function(player, spec)
    local e = c_find(player.surface, spec.x, spec.y, spec.name)
    if not e then error("\"circuits inserters: no entity there\"") end
    local bb = e.bounding_box
    local r = tonumber(spec.radius) or 3
    local out = {}
    for _, i in pairs(player.surface.find_entities_filtered{area = {{bb.left_top.x - r, bb.left_top.y - r}, {bb.right_bottom.x + r, bb.right_bottom.y + r}}, type = "inserter", force = player.force}) do
        local dt, pt = i.drop_target, i.pickup_target
        local into, from = dt and dt.unit_number == e.unit_number, pt and pt.unit_number == e.unit_number
        if (not spec.into or into) and (not spec.from or from) and (into or from) then
            out[#out + 1] = {n = i.name, x = i.position.x, y = i.position.y, into = into, from = from,
                drop = dt and {n = dt.name, x = dt.position.x, y = dt.position.y} or nil,
                pick = pt and {n = pt.name, x = pt.position.x, y = pt.position.y} or nil}
        end
    end
    local own = nil
    if e.type == "inserter" then
        local dt, pt = e.drop_target, e.pickup_target
        own = {drop = dt and {n = dt.name, x = dt.position.x, y = dt.position.y} or nil,
               pick = pt and {n = pt.name, x = pt.position.x, y = pt.position.y} or nil}
    end
    return {entity = e.name, inserters = out, own = own}
end

-- electric pole: network, wire reach, supply area, copper neighbours (each with its network)
local function pole_info(e)
    local out = {n = e.name, x = e.position.x, y = e.position.y, net = e.electric_network_id,
        reach = e.prototype.get_max_wire_distance(), supply = e.prototype.get_supply_area_distance(), nb = {}}
    local c = e.get_wire_connector(defines.wire_connector_id.pole_copper, false)
    if c then
        for _, w in pairs(c.connections) do
            local o = w.target.owner
            if o and o.valid and o.type == "electric-pole" then
                out.nb[#out.nb + 1] = {n = o.name, x = o.position.x, y = o.position.y, net = o.electric_network_id,
                    reach = o.prototype.get_max_wire_distance()}
            end
        end
    end
    return out
end
C.pole = function(player, spec)
    local e = player.surface.find_entities_filtered{position = {spec.x, spec.y}, radius = 0.7, type = "electric-pole", limit = 1}[1]
    if not e then return {none = true} end
    return pole_info(e)
end
-- copper wire between two poles (disconnect = true removes it)
C.pole_connect = function(player, spec)
    local s = player.surface
    local a = s.find_entities_filtered{position = {spec.a.x, spec.a.y}, radius = 0.7, type = "electric-pole", limit = 1}[1]
    local b = s.find_entities_filtered{position = {spec.b.x, spec.b.y}, radius = 0.7, type = "electric-pole", limit = 1}[1]
    if not a or not b then error('"circuits pole_connect: no pole at ' .. (a and "b" or "a") .. '"') end
    local ca = a.get_wire_connector(defines.wire_connector_id.pole_copper, true)
    local cb = b.get_wire_connector(defines.wire_connector_id.pole_copper, true)
    local ok
    if spec.disconnect then ok = ca.disconnect_from(cb) else ok = ca.connect_to(cb, false) end
    return {ok = ok and true or false, a = pole_info(a), b = pole_info(b)}
end

-- any control behaviour fields verbatim (train stop, chest, pump, inserter, lamp, ...)
C.control = function(player, spec)
    local e = c_find(player.surface, spec.x, spec.y, spec.name)
    if not e then error("\"circuits control: no entity there\"") end
    local cb = e.get_or_create_control_behavior()
    local set, failed = {}, {}
    for k, v in pairs(spec.fields or {}) do
        local ok, err = pcall(function() cb[k] = v end)
        if ok then set[#set + 1] = k else failed[#failed + 1] = k .. ": " .. string.sub(tostring(err), 1, 80) end
    end
    return {entity = e.name, set = set, failed = failed}
end
-- rail graph: blocks, signals with states, stops
C.graph = function(player, spec)
    local s = player.surface
    local area = {position = {tonumber(spec.x), tonumber(spec.y)}, radius = tonumber(spec.radius) or 60}
    local rails = s.find_entities_filtered{position = area.position, radius = area.radius,
        type = {"straight-rail", "half-diagonal-rail", "curved-rail-a", "curved-rail-b"}}
    local parent = {}
    local function find(u) while parent[u] ~= u do parent[u] = parent[parent[u]] u = parent[u] end return u end
    for _, r in pairs(rails) do parent[r.unit_number] = r.unit_number end
    local CDS = {defines.rail_connection_direction.straight, defines.rail_connection_direction.left, defines.rail_connection_direction.right}
    for _, r in pairs(rails) do
        for _, rd in ipairs({defines.rail_direction.front, defines.rail_direction.back}) do
            for _, cd in ipairs(CDS) do
                local o = r.get_connected_rail{rail_direction = rd, rail_connection_direction = cd}
                if o and parent[o.unit_number] and r.is_rail_in_same_rail_block_as(o) then
                    parent[find(r.unit_number)] = find(o.unit_number)
                end
            end
        end
    end
    local blocks = {}
    for _, r in pairs(rails) do local k = find(r.unit_number) blocks[k] = (blocks[k] or 0) + 1 end
    local sizes = {}
    for _, n in pairs(blocks) do sizes[#sizes + 1] = n end
    table.sort(sizes, function(a, b) return a > b end)
    local SS = {}
    for k, v in pairs(defines.signal_state) do SS[v] = k end
    local sigs = {}
    for _, g in pairs(s.find_entities_filtered{position = area.position, radius = area.radius, type = {"rail-signal", "rail-chain-signal"}}) do
        local st = nil
        pcall(function() st = g.type == "rail-chain-signal" and g.chain_signal_state or g.signal_state end)
        sigs[#sigs + 1] = {x = g.position.x, y = g.position.y, d = g.direction, chain = g.type == "rail-chain-signal",
                           state = st and (SS[st] or tostring(st)) or "?"}
    end
    local stops = {}
    for _, st in pairs(s.find_entities_filtered{position = area.position, radius = area.radius, type = "train-stop"}) do
        stops[#stops + 1] = {name = st.backer_name, x = st.position.x, y = st.position.y, rail = st.connected_rail ~= nil}
    end
    return {rails = #rails, blocks = #sizes, block_sizes = sizes, signals = sigs, stops = stops}
end

storage.actions.circuits = function(player_index, op, spec_hex)
    local player = storage.agent_characters[player_index]
    local f = C[op]
    if not f then error("\"circuits: unknown op " .. tostring(op) .. " (wire, signals, constant, arithmetic, decider, control, graph)\"") end
    local spec = helpers.json_to_table(c_unhex(spec_hex or "")) or {}
    return c_out(f(player, spec))
end
