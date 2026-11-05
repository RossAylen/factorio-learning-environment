-- bots: construction robot orders and logistic network reads (Factorio 2.x).
local function b_unhex(h) return (h:gsub("%x%x", function(c) return string.char(tonumber(c, 16)) end)) end
local function b_out(t)
    local j = helpers.table_to_json(t)
    return "BOTSHEX_" .. (j:gsub(".", function(ch) return string.format("%02x", ch:byte()) end))
end
local B = {}

-- transaction tracking: controller.TXN brackets each tool call with a scan and appends new units
-- to storage.txn_units[pi]
-- fluid probe (2.1 API, all pcall'd): spec.x, spec.y -> the entity there (name, status, recipe, every
-- fluid box: contents, capacity, filter, production type, segment id + segment contents, connections
-- with their targets); spec.x0..y1 -> every fluid entity in the area grouped by segment
-- (count, span, contents, statuses)
local function fb_info(e)
    local out = {}
    local fb = nil
    pcall(function() fb = storage.fb and storage.fb(e) or e.fluidbox end)
    if not fb then return out end
    for i = 1, #fb do
        local r = {i = i}
        pcall(function() local f = fb[i] if f then r.fluid, r.amount = f.name, math.floor(f.amount * 10) / 10 end end)
        pcall(function() r.cap = fb.get_capacity(i) end)
        pcall(function() local f = fb.get_filter(i) if f then r.filter = f.name end end)
        pcall(function() local pr = fb.get_prototype(i) pr = pr[1] or pr r.ptype = pr.production_type end)
        pcall(function() r.seg = fb.get_fluid_segment_id(i) end)
        pcall(function()
            local ns = {}
            for _, c in pairs(fb.get_connections(i)) do ns[#ns + 1] = {c.owner.name, c.owner.position.x, c.owner.position.y} end
            r.nb = ns
        end)
        pcall(function()
            local c = fb.get_fluid_segment_contents(i)
            if c then local t = {} for k, v in pairs(c) do t[k] = math.floor(v) end r.seg_contents = t end
        end)
        pcall(function()
            local cs = {}
            for _, c in pairs(fb.get_pipe_connections(i)) do
                local t = {x = c.target_position and c.target_position.x, y = c.target_position and c.target_position.y,
                           type = c.connection_type, flow = c.flow_direction}
                if c.target then
                    pcall(function() t.to = c.target.owner.name t.tx, t.ty = c.target.owner.position.x, c.target.owner.position.y end)
                end
                cs[#cs + 1] = t
            end
            r.conn = cs
        end)
        out[#out + 1] = r
    end
    return out
end
local SN = {}
for k, v in pairs(defines.entity_status) do SN[v] = k end
B.fluid_probe = function(player, spec)
    local s = player.surface
    if spec.x then
        local es = s.find_entities_filtered{position = {spec.x, spec.y}, radius = spec.radius or 0.7, force = player.force}
        local out = {}
        for _, e in pairs(es) do
            if e.type ~= "character" then
                local r = {n = e.name, t = e.type, x = e.position.x, y = e.position.y, d = e.direction, status = SN[e.status] }
                pcall(function() local rc = e.get_recipe() if rc then r.recipe = rc.name end end)
                pcall(function() r.mirror = e.mirroring end)
                r.boxes = fb_info(e)
                out[#out + 1] = r
            end
        end
        return {at = out}
    end
    local segs = {}
    for _, e in pairs(s.find_entities_filtered{area = {{spec.x0, spec.y0}, {spec.x1, spec.y1}}, force = player.force,
            type = {"pipe", "pipe-to-ground", "pump", "storage-tank", "offshore-pump", "mining-drill", "assembling-machine",
                    "oil-refinery", "chemical-plant", "boiler", "generator", "fluid-turret", "furnace"}}) do
        local fb = nil
        pcall(function() fb = storage.fb and storage.fb(e) or e.fluidbox end)
        if fb then
            for i = 1, #fb do
                local id = nil
                pcall(function() id = fb.get_fluid_segment_id(i) end)
                if id and spec.seg and id == spec.seg then
                    local ns = {}
                    pcall(function() for _, c in pairs(fb.get_connections(i)) do ns[#ns + 1] = {c.owner.position.x, c.owner.position.y} end end)
                    segs.__list = segs.__list or {}
                    segs.__list[#segs.__list + 1] = {n = e.name, x = e.position.x, y = e.position.y, nb = ns}
                end
                if id then
                    local g = segs[id]
                    if not g then
                        g = {id = id, n = 0, x0 = e.position.x, y0 = e.position.y, x1 = e.position.x, y1 = e.position.y, names = {}, status = {}}
                        pcall(function()
                            local c = fb.get_fluid_segment_contents(i)
                            if c then local t = {} for k, v in pairs(c) do t[k] = math.floor(v) end g.contents = t end
                        end)
                        segs[id] = g
                    end
                    g.n = g.n + 1
                    g.x0, g.y0 = math.min(g.x0, e.position.x), math.min(g.y0, e.position.y)
                    g.x1, g.y1 = math.max(g.x1, e.position.x), math.max(g.y1, e.position.y)
                    g.names[e.name] = (g.names[e.name] or 0) + 1
                    local st = SN[e.status] or "none"
                    g.status[st] = (g.status[st] or 0) + 1
                end
            end
        end
    end
    local out = {}
    local list = segs.__list
    segs.__list = nil
    for _, g in pairs(segs) do out[#out + 1] = g end
    return {segments = out, entities = list}
end

-- unit-number watermarks: unit numbers only grow, so "built in the last N ticks" = unit number above
-- the highest one that existed N ticks ago. op records one mark per >= 3 game-minutes (kept 3 h);
-- spec.age (ticks) -> cutoff (nil = no mark that old yet: then the oldest mark, conservative)
B.unit_wm = function(player, spec)
    storage.unit_wm = storage.unit_wm or {}
    local wm = storage.unit_wm
    local last = wm[#wm]
    if not last or game.tick - last.t >= 10800 then
        local mx = 0
        for _, e in pairs(player.surface.find_entities_filtered{force = player.force}) do
            local u = e.unit_number
            if u and u > mx then mx = u end
        end
        wm[#wm + 1] = {t = game.tick, u = mx}
        while #wm > 1 and game.tick - wm[1].t > 648000 do table.remove(wm, 1) end
    end
    local cutoff, oldest = nil, wm[1]
    for _, m in ipairs(wm) do
        if game.tick - m.t >= (spec.age or 108000) then cutoff = m.u end
    end
    return {cutoff = cutoff or (oldest and oldest.u), exact = cutoff ~= nil, marks = #wm, tick = game.tick}
end

-- resources under drill spots: spec.pts = [[x, y], ...], spec.r (half side, 2.5 = electric drill) ->
-- {at = [{name = amount}, ...]} (same order)
B.ore_at = function(player, spec)
    local s = player.surface
    local r = spec.r or 2.5
    local out = {}
    for i, p in ipairs(spec.pts or {}) do
        local c = {}
        for _, e in pairs(s.find_entities_filtered{area = {{p[1] - r, p[2] - r}, {p[1] + r, p[2] + r}}, type = "resource"}) do
            c[e.name] = (c[e.name] or 0) + e.amount
        end
        out[i] = c
    end
    return {at = out}
end

-- unlock state from the FORCE: spec.recipe -> {enabled}, spec.tech -> {researched, level}
B.tech = function(player, spec)
    local f = player.force
    local out = {}
    if spec.recipe then
        local r = f.recipes[spec.recipe]
        out.recipe_exists = r ~= nil
        out.enabled = r ~= nil and r.enabled or false
    end
    if spec.tech then
        local t = f.technologies[spec.tech]
        out.tech_exists = t ~= nil
        out.researched = t ~= nil and t.researched or false
        if t then out.level = t.level end
    end
    return out
end

-- LAB ONLY (the caller refuses on the live instance): infinity sources / voids for measuring designs.
-- spec.kind = "item" (spec.item, spec.n per refill) | "fluid" (spec.fluid, spec.temperature) | "void" | "void_fluid"
B.infinity = function(player, spec)
    local s = player.surface
    local pos = {spec.x, spec.y}
    if spec.kind == "item" or spec.kind == "void" then
        local c = s.create_entity{name = "infinity-chest", position = pos, force = player.force, raise_built = true}
        if not c then error('"bots infinity: no room for an infinity chest at ' .. spec.x .. ',' .. spec.y .. '"') end
        if spec.kind == "item" then
            c.set_infinity_container_filter(1, {name = spec.item, count = spec.n or 100, mode = "exactly"})
        else
            c.remove_unfiltered_items = true
        end
        return {name = c.name, x = c.position.x, y = c.position.y, kind = spec.kind}
    end
    local p = s.create_entity{name = "infinity-pipe", position = pos, force = player.force, raise_built = true}
    if not p then error('"bots infinity: no room for an infinity pipe at ' .. spec.x .. ',' .. spec.y .. '"') end
    if spec.kind == "fluid" then
        p.set_infinity_pipe_filter{name = spec.fluid, percentage = 1.0, mode = "exactly", temperature = spec.temperature}
    else
        p.set_infinity_pipe_filter{name = spec.fluid or "water", percentage = 0.0, mode = "exactly"}
    end
    return {name = p.name, x = p.position.x, y = p.position.y, kind = spec.kind}
end

-- spec.pi, spec.clear: the units this agent created during the current transaction (still alive)
B.txn = function(player, spec)
    storage.txn_units = storage.txn_units or {}
    local t = storage.txn_units[spec.pi] or {}
    local alive = {}
    for _, u in ipairs(t) do alive[#alive + 1] = u end   -- the caller intersects with an area scan
    if spec.clear then storage.txn_units[spec.pi] = nil end
    return {units = alive, n = #t}
end

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
            if e.type == "splitter" then
                pcall(function()
                    local f = e.splitter_filter
                    if f then r.sf = (type(f) == "string" and f) or f.name end
                    if type(r.sf) ~= "string" then r.sf = nil end
                    if e.splitter_output_priority ~= "none" then r.sp = e.splitter_output_priority end
                    if e.splitter_input_priority ~= "none" then r.si = e.splitter_input_priority end
                end)
            end
            if e.type == "inserter" then
                pcall(function()
                    if e.use_filters then
                        local fs = {}
                        for i = 1, e.filter_slot_count do
                            local f = e.get_filter(i)
                            local nm = f and ((type(f) == "string" and f) or f.name)
                            if type(nm) == "string" then fs[#fs + 1] = nm end
                        end
                        if #fs > 0 then r.f = fs r.fm = e.inserter_filter_mode end
                    end
                end)
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
            -- never a production chest (an inserter takes from / puts into it): dumps put iron and sulfur
            -- into adv2's copper input chest
            local used = false
            for _, i in pairs(s.find_entities_filtered{area = {{c.position.x - 3, c.position.y - 3}, {c.position.x + 3, c.position.y + 3}}, type = "inserter"}) do
                if i.pickup_target == c or i.drop_target == c then used = true break end
            end
            local ci = c.get_inventory(defines.inventory.chest)
            if not used and ci and ci.count_empty_stacks() >= 8 then chest = c break end
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
    -- say WHAT is in the way (the old "cannot place the entrance" left agents guessing)
    local function blocker(x, y)
        local out = {}
        for _, e in pairs(s.find_entities_filtered{position = {x, y}, radius = 0.45}) do
            if e.type ~= "character" then out[#out + 1] = e.name .. "@" .. e.position.x .. "," .. e.position.y end
        end
        local t = s.get_tile(x, y)
        if t and t.valid and t.collides_with and pcall(function() return t.collides_with("water_tile") end) and t.collides_with("water_tile") then out[#out + 1] = "water" end
        return #out > 0 and table.concat(out, " ") or "nothing visible (a cliff/ghost/reserved tile?)"
    end
    local span = math.max(math.abs(dx), math.abs(dy)) - 1
    local maxd = 4
    pcall(function() maxd = prototypes.entity[name].max_underground_distance end)
    if span > maxd then error('"bots ug_pair: span ' .. span .. ' tiles is longer than ' .. name .. ' reaches (' .. maxd .. ')"') end
    -- create_entity does not check collisions: it put an entrance ON a chest
    for _, q in ipairs({{spec.ax, spec.ay, "entrance"}, {spec.bx, spec.by, "exit"}}) do
        if not s.can_place_entity{name = name, position = {q[1], q[2]}, direction = d, force = player.force} then
            error('"bots ug_pair: cannot place the ' .. q[3] .. ' at ' .. q[1] .. ',' .. q[2] .. ': ' .. blocker(q[1], q[2]) .. '"')
        end
    end
    local a = s.create_entity{name = name, position = {spec.ax, spec.ay}, direction = d, type = "input", force = player.force, raise_built = true}
    if not a then error('"bots ug_pair: cannot place the entrance at ' .. spec.ax .. ',' .. spec.ay .. ': ' .. blocker(spec.ax, spec.ay) .. '"') end
    local b = s.create_entity{name = name, position = {spec.bx, spec.by}, direction = d, type = "output", force = player.force, raise_built = true}
    if not b then a.destroy() error('"bots ug_pair: cannot place the exit at ' .. spec.bx .. ',' .. spec.by .. ': ' .. blocker(spec.bx, spec.by) .. '"') end
    player.remove_item{name = name, count = 2}
    local nb = nil
    pcall(function() nb = storage.neighbours and storage.neighbours(a) or nil end)
    return {a = {a.position.x, a.position.y, a.belt_to_ground_type}, b = {b.position.x, b.position.y, b.belt_to_ground_type},
            paired = nb ~= nil and nb == b}
end

-- fluid systems in an area: per fluid system id, the fluids in it and the fluids its machine
-- fluidboxes are filtered for; mixed = more than one
B.fluid_mix = function(player, spec)
    local s = player.surface
    local sys = {}
    local types = {"pipe", "pipe-to-ground", "pump", "storage-tank", "offshore-pump", "mining-drill", "assembling-machine",
                   "furnace", "boiler", "generator", "fluid-turret", "infinity-pipe"}
    for _, e in pairs(s.find_entities_filtered{area = {{spec.x0, spec.y0}, {spec.x1, spec.y1}}, force = player.force, type = types}) do
        for i = 1, 10 do
            local ok, id = pcall(function()
                if e.get_fluid_segment_id then return e.get_fluid_segment_id(i) end
                return e.fluidbox.get_fluid_system_id(i)
            end)
            if not ok then break end
            if id then
                local r = sys[id] or {fluids = {}, filters = {}, n = 0, x = e.position.x, y = e.position.y, names = {}}
                sys[id] = r
                r.n = r.n + 1
                pcall(function()
                    local f = e.get_fluid_segment_fluid and e.get_fluid_segment_fluid(i) or e.fluidbox[i]
                    if f and f.name then r.fluids[f.name] = (r.fluids[f.name] or 0) + (f.amount or 0) end
                end)
                pcall(function()
                    local fl = e.get_fluid_filter and e.get_fluid_filter(i) or e.fluidbox.get_filter(i)
                    if fl and fl.name then r.filters[fl.name] = true end
                end)
                if #r.names < 4 then r.names[#r.names + 1] = e.name end
            end
        end
    end
    local out = {}
    for id, r in pairs(sys) do
        local kinds = {}
        for k, _ in pairs(r.fluids) do kinds[k] = true end
        for k, _ in pairs(r.filters) do kinds[k] = true end
        local list = {}
        for k, _ in pairs(kinds) do list[#list + 1] = k end
        out[#out + 1] = {id = id, x = r.x, y = r.y, n = r.n, fluids = list, mixed = #list > 1, names = r.names}
    end
    return {systems = out}
end

-- storage chest helper: an existing chest of ours near (x, y) with room (not in `skip`), else a new
-- iron chest placed from the inventory
-- a chest is pure storage only when no inserter takes from it or puts into it (line chests, ammo chests,
-- cell buffers and relays are never used: 270 plates landed in an ammo chest)
local function is_storage(s, c)
    for _, i in pairs(s.find_entities_filtered{area = {{c.position.x - 3, c.position.y - 3}, {c.position.x + 3, c.position.y + 3}}, type = "inserter"}) do
        local pt, dt = i.pickup_target, i.drop_target
        if (pt and pt == c) or (dt and dt == c) then return false end
    end
    return true
end
local function storage_chest(player, x, y, skip)
    local s = player.surface
    for _, c in pairs(s.find_entities_filtered{position = {x, y}, radius = 12, type = "container", force = player.force}) do
        if not skip[c.unit_number] and is_storage(s, c) then
            local ci = c.get_inventory(defines.inventory.chest)
            if ci and ci.count_empty_stacks() >= 4 then return c end
        end
    end
    local inv = player.get_main_inventory()
    if inv.get_item_count("iron-chest") < 1 then return nil end
    local p = s.find_non_colliding_position("iron-chest", {x, y}, 10, 1, true)
    if not p then return nil end
    local c = s.create_entity{name = "iron-chest", position = p, force = player.force, raise_built = true}
    if c then inv.remove{name = "iron-chest", count = 1} end
    return c
end

-- empty_chests: move the contents of the listed chests (units) into storage chests nearby (never into
-- the character: a full inventory made the forced pickup spill thousands of plates on the ground)
B.empty_chests = function(player, spec)
    local s = player.surface
    local skip, moved, left, used = {}, {}, {}, {}
    for _, u in ipairs(spec.units or {}) do skip[tonumber(u)] = true end
    for _, c in pairs(s.find_entities_filtered{area = {{spec.x0, spec.y0}, {spec.x1, spec.y1}}, type = "container", force = player.force}) do
        if skip[c.unit_number] then
            local ci = c.get_inventory(defines.inventory.chest)
            for _, it in pairs(ci.get_contents()) do
                local rest = it.count
                for _ = 1, 6 do
                    if rest <= 0 then break end
                    local dst = storage_chest(player, c.position.x, c.position.y, skip)
                    if not dst then break end
                    local n = dst.get_inventory(defines.inventory.chest).insert{name = it.name, count = rest, quality = it.quality}
                    used[dst.position.x .. "," .. dst.position.y] = true
                    if n <= 0 then skip[dst.unit_number] = true else
                        ci.remove{name = it.name, count = n, quality = it.quality}
                        moved[it.name] = (moved[it.name] or 0) + n
                        rest = rest - n
                    end
                end
                if rest > 0 then left[it.name] = (left[it.name] or 0) + rest end
            end
        end
    end
    local ul = {}
    for k, _ in pairs(used) do ul[#ul + 1] = k end
    return {moved = moved, left = left, chests = ul}
end

-- gather_ground: items lying on the ground in an area -> storage chests nearby
B.gather_ground = function(player, spec)
    local s = player.surface
    local moved, n = {}, 0
    local skip, used = {}, {}
    for _, e in pairs(s.find_entities_filtered{area = {{spec.x0, spec.y0}, {spec.x1, spec.y1}}, type = "item-entity"}) do
        if e.valid and e.stack and e.stack.valid_for_read then
            local dst = storage_chest(player, e.position.x, e.position.y, skip)
            if not dst then break end
            local name, count = e.stack.name, e.stack.count
            used[dst.position.x .. "," .. dst.position.y] = true
            local k = dst.get_inventory(defines.inventory.chest).insert(e.stack)
            if k >= count then e.destroy() n = n + 1 moved[name] = (moved[name] or 0) + k
            elseif k > 0 then e.stack.count = count - k moved[name] = (moved[name] or 0) + k end
        end
    end
    local ul = {}
    for k, _ in pairs(used) do ul[#ul + 1] = k end
    return {moved = moved, stacks = n, chests = ul}
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
