-- kpi: read-only base health numbers. op "prod": items produced (and science consumed) per hour for
-- the last N hours from the force's production statistics (ten_hours precision: 300 samples of 2
-- minutes); generation now. op "clean": cleanliness counts (redundant poles, belts to nowhere,
-- long-empty belts, machine statuses by area, rail components / open ends / pathless trains).
local function kh(t)
    local j = helpers.table_to_json(t)
    return "KPIHEX_" .. (j:gsub(".", function(ch) return string.format("%02x", ch:byte()) end))
end
local K = {}

K.prod = function(player, spec)
    local force = player.force
    local surf = player.surface
    local stats = force.get_item_production_statistics(surf)
    local hours = math.min(10, tonumber(spec.hours) or 10)
    local out = {items = {}, consumed = {}, tick = game.tick}
    local function series(name, cat)
        local s = {}
        for h = 1, hours do
            local tot = 0
            for k = (h - 1) * 30 + 1, h * 30 do
                local ok, n = pcall(function() return stats.get_flow_count{name = name, category = cat,
                    precision_index = defines.flow_precision_index.ten_hours, sample_index = k, count = true} end)
                if ok and n then tot = tot + n end
            end
            s[h] = math.floor(tot + 0.5)
        end
        return s
    end
    for _, n in ipairs(spec.items or {}) do out.items[n] = series(n, "input") end
    for _, n in ipairs(spec.consumed or {}) do out.consumed[n] = series(n, "output") end
    -- generation now (MW): every generator's output last tick
    local gen, units = 0, 0
    for _, e in pairs(surf.find_entities_filtered{type = {"generator", "solar-panel", "burner-generator"}, force = force}) do
        pcall(function() gen = gen + (e.energy_generated_last_tick or 0) units = units + 1 end)
    end
    out.power_mw = gen * 60 / 1e6
    out.generators = units
    local low, nopow = 0, 0
    for _, e in pairs(surf.find_entities_filtered{type = {"assembling-machine", "furnace", "lab", "mining-drill", "inserter"}, force = force}) do
        local s = e.status
        if s == defines.entity_status.low_power then low = low + 1
        elseif s == defines.entity_status.no_power then nopow = nopow + 1 end
    end
    out.low_power, out.no_power = low, nopow
    return out
end

local function area_key(x, y, size) return math.floor(x / size) * size .. "," .. math.floor(y / size) * size end

K.clean = function(player, spec)
    local force, surf = player.force, player.surface
    local area = spec.x0 and {{spec.x0, spec.y0}, {spec.x1, spec.y1}} or nil
    local function find(f) if area then f.area = area end f.force = force return surf.find_entities_filtered(f) end
    local res = {}
    -- 1. redundant poles: removing it keeps every powered entity in its supply area covered by
    -- another pole AND its copper neighbours still connected to each other (no network split)
    local poles = find{type = "electric-pole"}
    local red, red_at, red_list = 0, {}, {}
    local grid = {}
    for _, p in ipairs(poles) do
        local k = math.floor(p.position.x / 8) .. "," .. math.floor(p.position.y / 8)
        grid[k] = grid[k] or {}
        table.insert(grid[k], p)
    end
    local function others_near(x, y, r)
        local out = {}
        local gx0, gx1, gy0, gy1 = math.floor((x - r) / 8), math.floor((x + r) / 8), math.floor((y - r) / 8), math.floor((y + r) / 8)
        for ix = gx0, gx1 do for iy = gy0, gy1 do
            for _, q in ipairs(grid[ix .. "," .. iy] or {}) do out[#out + 1] = q end
        end end
        return out
    end
    local removed = {}
    local function covered_without(e, p)
        local bb = e.bounding_box
        for _, q in ipairs(others_near(e.position.x, e.position.y, 12)) do
            if q ~= p and q.valid and not removed[q.unit_number] then
                local sq = q.prototype.get_supply_area_distance()
                if bb.right_bottom.x > q.position.x - sq and bb.left_top.x < q.position.x + sq
                   and bb.right_bottom.y > q.position.y - sq and bb.left_top.y < q.position.y + sq then
                    return true
                end
            end
        end
        return false
    end
    local function nbs(p)
        local out = {}
        local c = p.get_wire_connector(defines.wire_connector_id.pole_copper, false)
        if c then for _, w in pairs(c.connections) do
            local o = w.target.owner
            if o and o.valid and o.type == "electric-pole" then out[#out + 1] = o end
        end end
        return out
    end
    local function connected_without(p)
        local ns = nbs(p)
        if #ns <= 1 then return true end
        local want = {}
        for _, n in ipairs(ns) do want[n.unit_number] = true end
        local seen, q, found = {[p.unit_number] = true, [ns[1].unit_number] = true}, {ns[1]}, 1
        local steps = 0
        while #q > 0 and steps < 3000 do
            local cur = table.remove(q)
            steps = steps + 1
            for _, o in ipairs(nbs(cur)) do
                if not seen[o.unit_number] and not removed[o.unit_number] then
                    seen[o.unit_number] = true
                    if want[o.unit_number] then found = found + 1 if found == #ns then return true end end
                    q[#q + 1] = o
                end
            end
        end
        return false
    end
    for _, p in ipairs(poles) do
        if p.valid then
            local sp = p.prototype.get_supply_area_distance()
            local ok = true
            for _, e in pairs(surf.find_entities_filtered{area = {{p.position.x - sp, p.position.y - sp}, {p.position.x + sp, p.position.y + sp}}, force = force}) do
                local powered = false
                if e.type ~= "electric-pole" then
                    pcall(function() powered = (e.electric_buffer_size or 0) > 0 end)
                end
                if powered then
                    if not covered_without(e, p) then ok = false break end
                end
            end
            if ok and connected_without(p) then
                -- greedy: count it as removed, so two poles covering each other are not both reported
                removed[p.unit_number] = true
                red = red + 1
                local k = area_key(p.position.x, p.position.y, 32)
                red_at[k] = (red_at[k] or 0) + 1
                if #red_list < 300 then red_list[#red_list + 1] = {x = p.position.x, y = p.position.y, n = p.name,
                    why = "its supply area stays covered and its neighbours stay connected without it"} end
            end
        end
    end
    res.poles = #poles
    res.redundant_poles = red
    res.redundant_at = red_at
    res.redundant_list = red_list
    -- 2. belts to nowhere + 3. empty belts (with first-seen-empty ticks kept in storage)
    local DV = {[0] = {0, -1}, [4] = {1, 0}, [8] = {0, 1}, [12] = {-1, 0}}
    local belts = find{type = "transport-belt"}
    storage.kpi_empty = storage.kpi_empty or {}
    local E = storage.kpi_empty
    local dead, dead_at, empty_long, empty_at, empty_now = 0, {}, 0, {}, 0
    local pick = {}
    for _, i in ipairs(find{type = "inserter"}) do
        local pp = i.pickup_position
        if pp then pick[math.floor(pp.x) .. "," .. math.floor(pp.y)] = true end
    end
    for _, b in ipairs(belts) do
        local dv = DV[b.direction]
        if dv then
            local tx, ty = b.position.x + dv[1], b.position.y + dv[2]
            -- area (not position+radius): a splitter is centred between two tiles, 0.5 from either tile centre
            local nxt = surf.find_entities_filtered{area = {{tx - 0.3, ty - 0.3}, {tx + 0.3, ty + 0.3}},
                type = {"transport-belt", "underground-belt", "splitter", "loader", "loader-1x1", "linked-belt"}}
            local fed_inserter = pick[math.floor(b.position.x) .. "," .. math.floor(b.position.y)]
            if #nxt == 0 and not fed_inserter then
                dead = dead + 1
                res.nowhere_list = res.nowhere_list or {}
                if #res.nowhere_list < 300 then res.nowhere_list[#res.nowhere_list + 1] = {x = b.position.x, y = b.position.y, why = "output tile has no belt and no inserter takes from it"} end
                local k = area_key(b.position.x, b.position.y, 32)
                dead_at[k] = (dead_at[k] or 0) + 1
            end
        end
        local n = 0
        for li = 1, 2 do n = n + b.get_transport_line(li).get_item_count() end
        local u = b.unit_number
        if n == 0 then
            empty_now = empty_now + 1
            E[u] = E[u] or game.tick
            if game.tick - E[u] >= 36000 then
                empty_long = empty_long + 1
                res.empty_list = res.empty_list or {}
                if #res.empty_list < 300 then res.empty_list[#res.empty_list + 1] = {x = b.position.x, y = b.position.y, why = "empty since tick " .. E[u]} end
                local k = area_key(b.position.x, b.position.y, 32)
                empty_at[k] = (empty_at[k] or 0) + 1
            end
        else
            E[u] = nil
        end
    end
    res.belts = #belts
    res.belts_to_nowhere = dead
    res.nowhere_at = dead_at
    res.belts_empty_now = empty_now
    res.belts_empty_10min = empty_long
    res.empty_at = empty_at
    -- 4. machines by status, grouped by 32x32 area
    local ST = {}
    for k, v in pairs(defines.entity_status) do ST[v] = k end
    local want = {output_full = true, item_ingredient_shortage = true, fluid_ingredient_shortage = true,
                  no_power = true, low_power = true, no_recipe = true, no_ingredients = true, no_input_fluid = true,
                  waiting_for_source_items = false, no_minable_resources = true, missing_required_fluid = true}
    local mstat, mat = {}, {}
    local ms = find{type = {"assembling-machine", "furnace", "lab", "mining-drill"}}
    for _, m in ipairs(ms) do
        local s = ST[m.status] or "?"
        mstat[s] = (mstat[s] or 0) + 1
        if s ~= "working" and s ~= "normal" then
            res.machine_list = res.machine_list or {}
            if #res.machine_list < 400 then res.machine_list[#res.machine_list + 1] = {x = m.position.x, y = m.position.y, n = m.name, why = s} end
            local k = s .. "@" .. area_key(m.position.x, m.position.y, 32)
            mat[k] = (mat[k] or 0) + 1
        end
    end
    res.machines = #ms
    res.machine_status = mstat
    res.machine_problems_at = mat
    -- 5. rails: components, open ends, trains without a path
    local RT = {"straight-rail", "half-diagonal-rail", "curved-rail-a", "curved-rail-b"}
    local rails = find{type = RT}
    local parent = {}
    local function f(u) while parent[u] ~= u do parent[u] = parent[parent[u]] u = parent[u] end return u end
    for _, r in ipairs(rails) do parent[r.unit_number] = r.unit_number end
    local open = 0
    local CDS = {defines.rail_connection_direction.straight, defines.rail_connection_direction.left, defines.rail_connection_direction.right}
    for _, r in ipairs(rails) do
        for _, rd in ipairs({defines.rail_direction.front, defines.rail_direction.back}) do
            local any = false
            for _, cd in ipairs(CDS) do
                local o = r.get_connected_rail{rail_direction = rd, rail_connection_direction = cd}
                if o then
                    any = true
                    if parent[o.unit_number] then parent[f(r.unit_number)] = f(o.unit_number) end
                end
            end
            if not any then open = open + 1 end
        end
    end
    local comps = {}
    for _, r in ipairs(rails) do comps[f(r.unit_number)] = true end
    local nc = 0
    for _ in pairs(comps) do nc = nc + 1 end
    local nopath, trains, manual = 0, 0, 0
    for _, t in pairs(game.train_manager.get_trains{surface = surf}) do
        trains = trains + 1
        if t.manual_mode then manual = manual + 1
        elseif not t.has_path then nopath = nopath + 1 end
    end
    res.rails, res.rail_components, res.rail_open_ends = #rails, nc, open
    res.trains, res.trains_manual, res.trains_no_path = trains, manual, nopath
    res.stops = #find{type = "train-stop"}
    return res
end

storage.actions.kpi_read = function(player_index, op, spec_hex)
    local player = storage.agent_characters[player_index]
    local function unhex(h) return (h:gsub("%x%x", function(c) return string.char(tonumber(c, 16)) end)) end
    local f = K[op]
    if not f then error('"kpi_read: unknown op ' .. tostring(op) .. ' (prod, clean)"') end
    return kh(f(player, helpers.json_to_table(unhex(spec_hex or "")) or {}))
end
