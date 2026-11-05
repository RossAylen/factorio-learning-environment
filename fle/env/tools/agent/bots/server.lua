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
    local f = {area = {{spec.x0, spec.y0}, {spec.x1, spec.y1}}, force = player.force}
    if spec.names then f.name = spec.names end
    for _, e in pairs(player.surface.find_entities_filtered(f)) do
        if e.valid and e.type ~= "character" and e.type ~= "entity-ghost" and e.unit_number then
            local r = {n = e.name, x = e.position.x, y = e.position.y, u = e.unit_number}
            if e.supports_direction then r.d = e.direction end
            if e.type == "assembling-machine" then
                pcall(function() local rc = e.get_recipe() if rc then r.r = rc.name end end)
            end
            if e.type == "underground-belt" then
                r.t = e.belt_to_ground_type
                local nb = nil
                pcall(function() nb = storage.neighbours and storage.neighbours(e) or nil end)
                if nb and nb.valid then r.px, r.py = nb.position.x, nb.position.y end
            end
            if spec.items and (e.type == "transport-belt" or e.type == "underground-belt" or e.type == "splitter") then
                local lanes = {}
                for li = 1, math.min(2, e.get_max_transport_line_index()) do
                    local c = {}
                    for _, it in pairs(e.get_transport_line(li).get_contents()) do c[it.name] = (c[it.name] or 0) + it.count end
                    lanes[li] = c
                end
                r.l = lanes
            end
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
                -- spec.lane = 1 | 2: only that lane (splitters/undergrounds: lanes 1,3,.. / 2,4,..)
                local lane_ok = (not spec.lane) or ((li - 1) % 2 + 1 == tonumber(spec.lane))
                for _, it in pairs(lane_ok and line.get_contents() or {}) do
                    if not keep[it.name] and (not spec.only or spec.only == it.name) then
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

-- follow a belt downstream from (x, y): [[x, y], ...] of the belt tiles items would ride (max tiles)
B.follow = function(player, spec)
    local surf = player.surface
    local DV = {[0] = {0, -1}, [4] = {1, 0}, [8] = {0, 1}, [12] = {-1, 0}}
    local out, seen = {}, {}
    local x, y = spec.x, spec.y
    for _ = 1, (spec.max or 400) do
        local e = surf.find_entities_filtered{position = {x, y}, radius = 0.4, type = {"transport-belt", "underground-belt", "splitter"}}[1]
        if not e then break end
        local k = math.floor(e.position.x * 2) .. "," .. math.floor(e.position.y * 2)
        if seen[k] then break end
        seen[k] = true
        out[#out + 1] = {x, y}
        local dv = DV[e.direction]
        if not dv then break end
        if e.type == "underground-belt" and e.belt_to_ground_type == "input" then
            local nb = storage.neighbours and storage.neighbours(e) or nil
            if nb and nb.valid then x, y = nb.position.x + dv[1], nb.position.y + dv[2]
            else break end
        else
            x, y = x + dv[1], y + dv[2]
        end
    end
    return {tiles = out}
end

-- trees, rocks and cliffs in an area: [{n, x, y, k = tree|rock|cliff}]
B.naturals = function(player, spec)
    local out = {}
    for _, e in pairs(player.surface.find_entities_filtered{area = {{spec.x0, spec.y0}, {spec.x1, spec.y1}},
            type = {"tree", "simple-entity", "cliff"}}) do
        out[#out + 1] = {n = e.name, x = e.position.x, y = e.position.y,
                         k = (e.type == "tree" and "tree") or (e.type == "cliff" and "cliff") or "rock"}
    end
    return {e = out}
end

-- unpowered: the same count as Ross's map HUD (status no_power / low_power over machines, inserters,
-- labs, turrets, radars, pumps) with positions
B.unpowered = function(player, spec)
    local st = defines.entity_status
    local none, low = {}, {}
    for _, e in pairs(player.surface.find_entities_filtered{force = player.force, type = {"assembling-machine", "furnace",
            "mining-drill", "inserter", "lab", "electric-turret", "radar", "pump", "offshore-pump"}}) do
        local v = e.status
        if v == st.no_power then none[#none + 1] = {n = e.name, x = e.position.x, y = e.position.y}
        elseif v == st.low_power then low[#low + 1] = {n = e.name, x = e.position.x, y = e.position.y} end
    end
    return {none = none, low = low}
end

-- power model for pole pruning: every pole (unit, supply distance, wire reach, copper neighbours, network
-- id) and every electric consumer (unit, centre, footprint half-size) in an area
B.power_model = function(player, spec)
    local s = player.surface
    local area = {{spec.x0, spec.y0}, {spec.x1, spec.y1}}
    local poles, cons = {}, {}
    for _, p in pairs(s.find_entities_filtered{area = area, type = "electric-pole", force = player.force}) do
        local nb = {}
        pcall(function()
            local c = p.get_wire_connector(defines.wire_connector_id.pole_copper, false)
            if c then for _, cn in pairs(c.connections) do
                local o = cn.target.owner
                if o and o.valid and o.type == "electric-pole" then nb[#nb + 1] = o.unit_number end
            end end
        end)
        local sd = 2.5
        pcall(function() sd = p.prototype.get_supply_area_distance(p.quality) end)
        local wr = 7.5
        pcall(function() wr = p.prototype.get_max_wire_distance(p.quality) end)
        poles[#poles + 1] = {u = p.unit_number, n = p.name, x = p.position.x, y = p.position.y, s = sd, w = wr, nb = nb,
                             net = p.electric_network_id}
    end
    for _, e in pairs(s.find_entities_filtered{area = area, force = player.force}) do
        if e.valid and e.type ~= "electric-pole" and e.unit_number then
            local ok, elec = pcall(function() return e.prototype.electric_energy_source_prototype ~= nil end)
            if ok and elec then
                local bb = e.prototype.collision_box
                local hw = math.max(0.5, (bb.right_bottom.x - bb.left_top.x) / 2)
                local hh = math.max(0.5, (bb.right_bottom.y - bb.left_top.y) / 2)
                cons[#cons + 1] = {u = e.unit_number, n = e.name, x = e.position.x, y = e.position.y, hw = hw, hh = hh,
                                   on = e.is_connected_to_electric_network()}
            end
        end
    end
    return {poles = poles, cons = cons}
end

-- dump: move the character's main inventory (all but keep-listed items) into a chest within 10:
-- an existing chest of ours with room, else a new iron chest placed from the inventory
B.dump = function(player, spec)
    local s = player.surface
    local keep = {}
    for _, k in ipairs(spec.keep or {}) do keep[k] = true end
    local inv = player.get_main_inventory()
    local chest = nil
    if spec.x then
        chest = s.find_entities_filtered{position = {spec.x, spec.y}, radius = 0.6, type = "container", force = player.force}[1]
    end
    if not chest then
        for _, c in pairs(s.find_entities_filtered{position = player.position, radius = 10, type = "container", force = player.force}) do
            local ci = c.get_inventory(defines.inventory.chest)
            if ci and ci.count_empty_stacks() >= 8 then chest = c break end
        end
    end
    if not chest then
        if inv.get_item_count("iron-chest") < 1 then error('"bots dump: no chest with room within 10 and no iron-chest in the inventory"') end
        local p = s.find_non_colliding_position("iron-chest", player.position, 8, 1, true)
        if not p then error('"bots dump: no free tile for a chest"') end
        chest = s.create_entity{name = "iron-chest", position = p, force = player.force, raise_built = true}
        inv.remove{name = "iron-chest", count = 1}
    end
    local ci = chest.get_inventory(defines.inventory.chest)
    local moved = 0
    for _, it in pairs(inv.get_contents()) do
        if not keep[it.name] then
            local n = ci.insert{name = it.name, count = it.count, quality = it.quality}
            if n > 0 then inv.remove{name = it.name, count = n, quality = it.quality} moved = moved + n end
        end
    end
    return {chest = {chest.position.x, chest.position.y}, moved = moved, free = inv.count_empty_stacks()}
end

-- ug_pair: an underground belt pair from a (entrance) to b (exit), direction along a->b, from the inventory
B.ug_pair = function(player, spec)
    local s = player.surface
    local name = spec.name or "underground-belt"
    if player.get_item_count(name) < 2 then error('"bots ug_pair: need 2 ' .. name .. ' in the inventory"') end
    local dx, dy = spec.bx - spec.ax, spec.by - spec.ay
    local d = (math.abs(dx) >= math.abs(dy)) and (dx > 0 and defines.direction.east or defines.direction.west)
              or (dy > 0 and defines.direction.south or defines.direction.north)
    local a = s.create_entity{name = name, position = {spec.ax, spec.ay}, direction = d, type = "input", force = player.force, raise_built = true}
    if not a then error('"bots ug_pair: cannot place the entrance"') end
    local b = s.create_entity{name = name, position = {spec.bx, spec.by}, direction = d, type = "output", force = player.force, raise_built = true}
    if not b then a.destroy() error('"bots ug_pair: cannot place the exit"') end
    player.remove_item{name = name, count = 2}
    local nb = nil
    pcall(function() nb = storage.neighbours and storage.neighbours(a) or nil end)
    return {a = {a.position.x, a.position.y, a.belt_to_ground_type}, b = {b.position.x, b.position.y, b.belt_to_ground_type},
            paired = nb ~= nil and nb == b}
end

-- tree stumps (corpses, no item) in an area: removed - they block rail pieces
B.stumps = function(player, spec)
    local n = 0
    for _, e in pairs(player.surface.find_entities_filtered{area = {{spec.x0, spec.y0}, {spec.x1, spec.y1}}, type = "corpse"}) do
        if e.valid and string.find(e.name, "stump", 1, true) then e.destroy() n = n + 1 end
    end
    return {removed = n}
end

-- underground belt pairs whose span crosses an area: [{ax, ay, bx, by, n}] (a = input/entrance)
B.spans = function(player, spec)
    local out, seen = {}, {}
    local m = 11
    for _, e in pairs(player.surface.find_entities_filtered{area = {{spec.x0 - m, spec.y0 - m}, {spec.x1 + m, spec.y1 + m}},
            type = "underground-belt", force = player.force}) do
        if e.valid and e.belt_to_ground_type == "input" and not seen[e.unit_number] then
            local nb = storage.neighbours and storage.neighbours(e) or nil
            if nb and nb.valid then
                seen[e.unit_number] = true
                local x0, x1 = math.min(e.position.x, nb.position.x), math.max(e.position.x, nb.position.x)
                local y0, y1 = math.min(e.position.y, nb.position.y), math.max(e.position.y, nb.position.y)
                if x1 >= spec.x0 and x0 <= spec.x1 and y1 >= spec.y0 and y0 <= spec.y1 then
                    out[#out + 1] = {ax = e.position.x, ay = e.position.y, bx = nb.position.x, by = nb.position.y, n = e.name}
                end
            end
        end
    end
    return {spans = out}
end

-- planned entities (spec.ents = [{name, x, y, d}]) whose footprint covers an underground span
-- (the tiles strictly between a pair's entrance and exit): [{i, name, x, y, ax, ay, bx, by}]
B.span_hits = function(player, spec)
    local ents = spec.ents or {}
    if #ents == 0 then return {hits = {}} end
    local x0, y0, x1, y1 = 1e9, 1e9, -1e9, -1e9
    for _, e in ipairs(ents) do
        x0, y0, x1, y1 = math.min(x0, e.x), math.min(y0, e.y), math.max(x1, e.x), math.max(y1, e.y)
    end
    local spans = B.spans(player, {x0 = x0 - 3, y0 = y0 - 3, x1 = x1 + 3, y1 = y1 + 3}).spans
    local hits = {}
    for i, e in ipairs(ents) do
        local pr = prototypes.entity[e.name]
        if pr then
            local cb = pr.collision_box
            local w, h = cb.right_bottom.x - cb.left_top.x, cb.right_bottom.y - cb.left_top.y
            local d = tonumber(e.d) or 0
            if d == 4 or d == 12 then w, h = h, w end
            local bx0, by0, bx1, by1 = e.x - w / 2, e.y - h / 2, e.x + w / 2, e.y + h / 2
            for _, sp in ipairs(spans) do
                -- tiles strictly between the two ends, along the pair's axis
                local dx, dy = sp.bx - sp.ax, sp.by - sp.ay
                local n = math.max(math.abs(dx), math.abs(dy))
                local sx, sy = (dx ~= 0) and (dx / math.abs(dx)) or 0, (dy ~= 0) and (dy / math.abs(dy)) or 0
                for k = 1, n - 1 do
                    local tx, ty = sp.ax + sx * k, sp.ay + sy * k
                    if tx > bx0 and tx < bx1 and ty > by0 and ty < by1 then
                        hits[#hits + 1] = {i = i, name = e.name, x = e.x, y = e.y, ax = sp.ax, ay = sp.ay, bx = sp.bx, by = sp.by}
                        break
                    end
                end
            end
        end
    end
    return {hits = hits}
end

-- enemy turrets (worms) and spawners near a point with their real attack range: [{n, x, y, k, range}]
B.enemy_reach = function(player, spec)
    local out = {}
    for _, e in pairs(player.surface.find_entities_filtered{position = {spec.x, spec.y}, radius = spec.r or 40,
            force = "enemy", type = {"turret", "unit-spawner", "unit"}}) do
        local range = 0
        pcall(function()
            local ap = e.prototype.attack_parameters
            if ap and ap.range then range = ap.range end
        end)
        out[#out + 1] = {n = e.name, x = e.position.x, y = e.position.y, k = e.type, range = range,
                         hp = e.health, max_hp = e.max_health}
    end
    return {e = out}
end

-- undo: pick up our entities by unit number into the character (a failed build's own pieces)
B.undo = function(player, spec)
    local want = {}
    for _, u in ipairs(spec.units or {}) do want[tonumber(u)] = true end
    local n, failed = 0, 0
    for _, e in pairs(player.surface.find_entities_filtered{area = {{spec.x0, spec.y0}, {spec.x1, spec.y1}}, force = player.force}) do
        if e.valid and e.unit_number and want[e.unit_number] then
            local ok = pcall(function() return player.mine_entity(e, true) end)
            if ok and not e.valid then n = n + 1 else failed = failed + 1 end
        end
    end
    return {removed = n, failed = failed}
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
