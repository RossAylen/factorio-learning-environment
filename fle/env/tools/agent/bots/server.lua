-- bots: construction robot orders and logistic network reads (Factorio 2.x).
local function b_unhex(h) return (h:gsub("%x%x", function(c) return string.char(tonumber(c, 16)) end)) end
local function b_out(t)
    local j = helpers.table_to_json(t)
    return "BOTSHEX_" .. (j:gsub(".", function(ch) return string.format("%02x", ch:byte()) end))
end
local B = {}

-- ghost a blueprint (export string) at position: the game places every ghost with recipes,
-- wires and control settings, exactly as a player pasting it
B.ghost_bp = function(player, spec)
    local inv = game.create_inventory(1)
    local stack = inv[1]
    stack.set_stack{name = "blueprint", count = 1}
    local rc = stack.import_stack(spec.bp)
    if rc ~= 0 and rc ~= nil and rc < 0 then inv.destroy() error("\"bots ghost: blueprint string did not import\"") end
    local ghosts = stack.build_blueprint{surface = player.surface, force = player.force,
        position = {tonumber(spec.x), tonumber(spec.y)}, build_mode = defines.build_mode.forced,
        skip_fog_of_war = false, direction = tonumber(spec.d) or 0}
    inv.destroy()
    return {ghosts = #ghosts}
end

-- remove ghosts in an area (names = inner names to remove; all when absent)
B.unghost = function(player, spec)
    local n = 0
    for _, g in pairs(player.surface.find_entities_filtered{area = {{spec.x0, spec.y0}, {spec.x1, spec.y1}}, type = "entity-ghost", force = player.force}) do
        local keep = false
        if spec.names then keep = true for _, nm in ipairs(spec.names) do if g.ghost_name == nm then keep = false end end end
        if not keep then g.destroy() n = n + 1 end
    end
    return {removed = n}
end

-- ghosts in an area: [{n (inner name), x, y}]
B.ghosts = function(player, spec)
    local out = {}
    for _, g in pairs(player.surface.find_entities_filtered{area = {{spec.x0, spec.y0}, {spec.x1, spec.y1}}, type = "entity-ghost", force = player.force}) do
        out[#out + 1] = {n = g.ghost_name, x = g.position.x, y = g.position.y}
    end
    return {ghosts = out}
end

-- move items from the character to the entity at x,y (robots into a roboport, stock into a storage chest)
B.insert = function(player, spec)
    local e = player.surface.find_entities_filtered{position = {spec.x, spec.y}, radius = 1.5, force = player.force, limit = 1}[1]
    if not e then error('"bots insert: no entity at ' .. spec.x .. ',' .. spec.y .. '"') end
    local have = player.get_item_count(spec.name)
    local n = math.min(have, spec.count or have)
    if n <= 0 then error('"bots insert: no ' .. spec.name .. ' in the inventory"') end
    local put = e.insert{name = spec.name, count = n}
    if put > 0 then player.remove_item{name = spec.name, count = put} end
    return {inserted = put, into = e.name}
end

-- our entities in an area with what a blueprint diff needs: [{n, x, y, d (rotatable only), r (recipe), u (unit)}]
B.area = function(player, spec)
    local out = {}
    for _, e in pairs(player.surface.find_entities_filtered{area = {{spec.x0, spec.y0}, {spec.x1, spec.y1}}, force = player.force}) do
        if e.valid and e.type ~= "character" and e.type ~= "entity-ghost" and e.unit_number then
            local r = {n = e.name, x = e.position.x, y = e.position.y, u = e.unit_number}
            if e.supports_direction then r.d = e.direction end
            if e.type == "assembling-machine" then
                pcall(function() local rc = e.get_recipe() if rc then r.r = rc.name end end)
            end
            if e.type == "underground-belt" then r.t = e.belt_to_ground_type end
            out[#out + 1] = r
        end
    end
    return {e = out, tick = game.tick}
end

-- items on belt tiles: spec.tiles = [[x, y], ...] -> {items = {name = count}, first = {name = [x, y]}}
B.belt_items = function(player, spec)
    local items, first = {}, {}
    for _, t in ipairs(spec.tiles or {}) do
        for _, e in pairs(player.surface.find_entities_filtered{position = {t[1], t[2]}, radius = 0.4,
                type = {"transport-belt", "underground-belt", "splitter"}}) do
            for li = 1, e.get_max_transport_line_index() do
                for _, it in pairs(e.get_transport_line(li).get_contents()) do
                    items[it.name] = (items[it.name] or 0) + it.count
                    if not first[it.name] then first[it.name] = {e.position.x, e.position.y} end
                end
            end
        end
    end
    return {items = items, first = first}
end

-- take every item except spec.keep off the belt tiles into the character (like picking the belts
-- up and down again): spec.tiles = [[x, y], ...] -> {taken = {name = count}, left = {name = count}}
B.belt_purge = function(player, spec)
    local taken, left = {}, {}
    local keep = {}
    for _, k in ipairs(spec.keep or {}) do keep[k] = true end
    for _, t in ipairs(spec.tiles or {}) do
        for _, e in pairs(player.surface.find_entities_filtered{position = {t[1], t[2]}, radius = 0.4,
                type = {"transport-belt", "underground-belt", "splitter"}}) do
            for li = 1, e.get_max_transport_line_index() do
                local line = e.get_transport_line(li)
                for _, it in pairs(line.get_contents()) do
                    if not keep[it.name] then
                        local n = player.insert{name = it.name, count = it.count, quality = it.quality}
                        if n > 0 then
                            line.remove_item{name = it.name, count = n, quality = it.quality}
                            taken[it.name] = (taken[it.name] or 0) + n
                        end
                        if n < it.count then left[it.name] = (left[it.name] or 0) + it.count - n end
                    end
                end
            end
        end
    end
    return {taken = taken, left = left}
end

-- inserters taking from the given belt tiles: spec.tiles = [[x, y], ...] -> [{x, y, n, px, py, drop = {n, x, y}}]
B.taps = function(player, spec)
    local want, out, seen = {}, {}, {}
    local x0, y0, x1, y1 = 1e9, 1e9, -1e9, -1e9
    for _, t in ipairs(spec.tiles or {}) do
        want[math.floor(t[1]) .. "," .. math.floor(t[2])] = true
        x0, y0, x1, y1 = math.min(x0, t[1]), math.min(y0, t[2]), math.max(x1, t[1]), math.max(y1, t[2])
    end
    if x0 > x1 then return {taps = out} end
    for _, i in pairs(player.surface.find_entities_filtered{area = {{x0 - 3, y0 - 3}, {x1 + 3, y1 + 3}}, type = "inserter", force = player.force}) do
        local pp = i.pickup_position
        if pp and want[math.floor(pp.x) .. "," .. math.floor(pp.y)] and not seen[i.unit_number] then
            seen[i.unit_number] = true
            local dt = i.drop_target
            out[#out + 1] = {x = i.position.x, y = i.position.y, n = i.name, px = pp.x, py = pp.y,
                             drop = dt and {n = dt.name, x = dt.position.x, y = dt.position.y} or nil}
        end
    end
    return {taps = out}
end

-- single ghosts: [{n, x, y, d, recipe?, type?}]
B.ghost = function(player, spec)
    local n = 0
    for _, p in ipairs(spec.entities or {}) do
        local g = player.surface.create_entity{name = "entity-ghost", inner_name = p.n, position = {p.x, p.y},
            direction = p.d or 0, force = player.force, type = p.type, raise_built = true}
        if g then
            n = n + 1
            if p.recipe then pcall(function() g.set_recipe(p.recipe) end) end
        end
    end
    return {ghosts = n}
end

-- deconstruction orders in an area (names = only these), or cancel
B.deconstruct = function(player, spec)
    local f = {area = {{spec.x0, spec.y0}, {spec.x1, spec.y1}}, force = player.force}
    if spec.names then f.name = spec.names end
    local n = 0
    for _, e in pairs(player.surface.find_entities_filtered(f)) do
        if e.valid and e.type ~= "character" then
            if spec.cancel then
                if e.cancel_deconstruction(player.force) then n = n + 1 end
            elseif e.order_deconstruction(player.force) then n = n + 1 end
        end
    end
    return {ordered = n}
end

-- upgrade orders: map {from_name: to_name} in an area
B.upgrade = function(player, spec)
    local n = 0
    for from, to in pairs(spec.map or {}) do
        for _, e in pairs(player.surface.find_entities_filtered{area = {{spec.x0, spec.y0}, {spec.x1, spec.y1}}, name = from, force = player.force}) do
            if e.valid and e.order_upgrade{target = to, force = player.force} then n = n + 1 end
        end
    end
    return {ordered = n}
end

-- the construction network at a point: coverage, robots, storage, ghosts and what they still need
B.network = function(player, spec)
    local pos = {tonumber(spec.x), tonumber(spec.y)}
    local net = player.surface.find_logistic_network_by_position(pos, player.force)
    local out = {covered = false}
    if not net then return out end
    local cell = net.find_cell_closest_to(pos)
    out.covered = cell ~= nil and cell.is_in_construction_range(pos)
    out.robots = net.all_construction_robots
    out.robots_free = net.available_construction_robots
    out.logistic_robots = net.all_logistic_robots
    out.roboports = #net.cells
    local charging = 0
    for _, c in pairs(net.cells) do charging = charging + (c.charging_robot_count or 0) + (c.to_charge_robot_count or 0) end
    out.charging = charging
    local stock = {}
    pcall(function() for _, it in pairs(net.get_contents()) do stock[it.name] = (stock[it.name] or 0) + it.count end end)
    out.stock = stock
    if spec.x0 then
        local need, ghosts, decon = {}, 0, 0
        local area = {{spec.x0, spec.y0}, {spec.x1, spec.y1}}
        for _, g in pairs(player.surface.find_entities_filtered{area = area, type = "entity-ghost", force = player.force}) do
            ghosts = ghosts + 1
            local it = g.ghost_prototype.items_to_place_this and g.ghost_prototype.items_to_place_this[1]
            if it then need[it.name] = (need[it.name] or 0) + (it.count or 1) end
        end
        for _, e in pairs(player.surface.find_entities_filtered{area = area, force = player.force, to_be_deconstructed = true}) do
            decon = decon + 1
        end
        local missing = {}
        for k, v in pairs(need) do if (stock[k] or 0) < v then missing[k] = v - (stock[k] or 0) end end
        local upg = 0
        pcall(function() upg = #player.surface.find_entities_filtered{area = area, force = player.force, to_be_upgraded = true} end)
        out.ghosts, out.need, out.missing, out.to_deconstruct, out.to_upgrade = ghosts, need, missing, decon, upg
    end
    return out
end

storage.actions.bots = function(player_index, op, spec_hex)
    local player = storage.agent_characters[player_index]
    local f = B[op]
    if not f then error("\"bots: unknown op " .. tostring(op) .. " (ghost_bp, ghost, deconstruct, upgrade, network)\"") end
    return b_out(f(player, helpers.json_to_table(b_unhex(spec_hex or "")) or {}))
end
