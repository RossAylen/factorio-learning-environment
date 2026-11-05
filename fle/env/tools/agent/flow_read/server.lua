-- flow_read: the production graph of an area in one read - machines (recipe, crafting speed, per
-- input/output item rates), inserters (rate from rotation speed x stack, what they pick from / drop
-- into, which belt lane they drop on), belts (lane capacity from belt speed, contents per lane, next
-- tile, underground partner) and recipe data for plan(). Paged by the client when large.
local function fh(t)
    local j = helpers.table_to_json(t)
    return "FLOWHEX_" .. (j:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end
local DV = {[0] = {0, -1}, [4] = {1, 0}, [8] = {0, 1}, [12] = {-1, 0}}

local function rec_rates(rc, speed)
    if not rc then return nil end
    local t = rc.energy > 0 and rc.energy or 0.5
    local per = speed / t
    local ins, outs = {}, {}
    for _, i in pairs(rc.ingredients) do ins[i.name] = (ins[i.name] or 0) + i.amount * per end
    for _, p in pairs(rc.products) do
        local amt = p.amount or ((p.amount_min or 0) + (p.amount_max or 0)) / 2
        outs[p.name] = (outs[p.name] or 0) + amt * (p.probability or 1) * per
    end
    return ins, outs
end

local F = {}
F.graph = function(player, spec)
    local surf, force = player.surface, player.force
    local area = {{spec.x0, spec.y0}, {spec.x1, spec.y1}}
    local out = {machines = {}, inserters = {}, belts = {}, tick = game.tick}
    local ST = {}
    for k, v in pairs(defines.entity_status) do ST[v] = k end
    for _, m in pairs(surf.find_entities_filtered{area = area, force = force, type = {"assembling-machine", "furnace", "lab", "mining-drill"}}) do
        local r = {u = m.unit_number, n = m.name, t = m.type, x = m.position.x, y = m.position.y, s = ST[m.status]}
        local speed = 1
        pcall(function() speed = m.crafting_speed end)
        if m.type == "lab" then
            -- every pack of the current research at the research rate
            local cr = force.current_research
            if cr then
                local spd = 1
                pcall(function() spd = m.prototype.get_researching_speed and m.prototype.get_researching_speed() or m.prototype.researching_speed or 1 end)
                pcall(function() spd = spd * (1 + (force.laboratory_speed_modifier or 0)) end)
                local ut = 30
                pcall(function() ut = (cr.research_unit_energy or 1800) / 60 end)
                r.i = {}
                for _, ing in pairs(cr.research_unit_ingredients) do r.i[ing.name] = ing.amount * spd / ut end
                r.r = "research:" .. cr.name
            end
            pcall(function()   -- the packs the lab holds (LABS STARVED names the missing one)
                local inv = m.get_inventory(defines.inventory.lab_input)
                if inv then
                    local c = {}
                    for _, it in pairs(inv.get_contents()) do c[it.name] = (c[it.name] or 0) + it.count end
                    r.inv = c
                end
            end)
        elseif m.type == "mining-drill" then
            pcall(function() speed = m.prototype.mining_speed end)
            local res = surf.find_entities_filtered{area = m.mining_area, type = "resource", limit = 1}[1]
            if res then
                local mp = res.prototype.mineable_properties
                local mt = (mp and mp.mining_time) or 1
                local pname = (mp and mp.products and mp.products[1] and mp.products[1].name) or res.name
                r.out = {[pname] = speed / mt}
            end
            local dp = m.drop_position
            if dp then r.dx, r.dy = dp.x, dp.y end
        else
            local rc = nil
            pcall(function() rc = m.get_recipe() end)
            if not rc and m.type == "furnace" then pcall(function() rc = m.previous_recipe and m.previous_recipe.name and prototypes.recipe[m.previous_recipe.name] end) end
            if rc then
                r.r = rc.name
                r.i, r.out = rec_rates(rc, speed)
            end
        end
        r.sp = speed
        local bb = m.bounding_box
        r.bb = {bb.left_top.x, bb.left_top.y, bb.right_bottom.x, bb.right_bottom.y}
        out.machines[#out.machines + 1] = r
    end
    out.chests = {}
    for _, c in pairs(surf.find_entities_filtered{area = area, force = force, type = {"container", "logistic-container"}}) do
        local inv = {}
        pcall(function() for _, it in pairs(c.get_inventory(defines.inventory.chest).get_contents()) do inv[it.name] = it.count end end)
        out.chests[#out.chests + 1] = {u = c.unit_number, n = c.name, x = c.position.x, y = c.position.y, inv = inv}
    end
    for _, i in pairs(surf.find_entities_filtered{area = area, force = force, type = "inserter"}) do
        local stack = 1
        pcall(function() stack = 1 + (i.force.inserter_stack_size_bonus or 0) end)
        if i.name:find("bulk") or i.name:find("stack") then pcall(function() stack = 1 + (i.force.bulk_inserter_capacity_bonus or 0) end) end
        local rate = 0
        pcall(function() rate = i.prototype.get_inserter_rotation_speed() * 60 * stack end)
        if rate == 0 then pcall(function() rate = i.prototype.inserter_rotation_speed * 60 * stack end) end
        local pt, dt = i.pickup_target, i.drop_target
        local r = {x = i.position.x, y = i.position.y, n = i.name, rate = rate,
                   px = i.pickup_position.x, py = i.pickup_position.y, qx = i.drop_position.x, qy = i.drop_position.y,
                   pu = pt and pt.unit_number or nil, pn = pt and pt.name or nil, pt = pt and pt.type or nil,
                   du = dt and dt.unit_number or nil, dn = dt and dt.name or nil, dtt = dt and dt.type or nil}
        local f = {}
        pcall(function() if i.use_filters then for k = 1, i.filter_slot_count do local fl = i.get_filter(k) if fl then f[#f + 1] = fl.name or fl end end end end)
        if #f > 0 then r.f = f end
        out.inserters[#out.inserters + 1] = r
    end
    for _, b in pairs(surf.find_entities_filtered{area = area, force = force, type = {"transport-belt", "underground-belt", "splitter"}}) do
        local lane = (b.prototype.belt_speed or 0.03125) * 60 * 4   -- items/s per lane (yellow 7.5)
        local r = {u = b.unit_number, n = b.name, t = b.type, x = b.position.x, y = b.position.y, d = b.direction, lane = lane}
        local l = {}
        for li = 1, math.min(2, b.get_max_transport_line_index()) do
            local c = {}
            for _, it in pairs(b.get_transport_line(li).get_contents()) do c[it.name] = it.count end
            l[li] = c
        end
        r.l = l
        if b.type == "underground-belt" then
            r.ut = b.belt_to_ground_type
            local nb = storage.neighbours and storage.neighbours(b) or nil
            if nb and nb.valid then r.pu = nb.unit_number end
        end
        if b.type == "splitter" then
            -- filter splitter: the filter item goes to the priority side, everything else to the other
            pcall(function()
                local f = b.splitter_filter
                if f then r.sf = (type(f) == "string" and f) or f.name or (f.name and f.name.name) end
                if type(r.sf) ~= "string" then r.sf = nil end
                r.sp = b.splitter_output_priority
            end)
        end
        local dv = DV[b.direction]
        if dv then r.nx, r.ny = b.position.x + dv[1], b.position.y + dv[2] end
        out.belts[#out.belts + 1] = r
    end
    return out
end

-- recipe data for plan(): spec.items -> {item: [{recipe, energy, ingredients, products, category}]}
F.recipes = function(player, spec)
    local force = player.force
    local out = {}
    for _, name in ipairs(spec.items or {}) do
        local list = {}
        for rn, rc in pairs(force.recipes) do
            if rc.enabled or spec.all then
                for _, p in pairs(rc.products) do
                    if p.name == name then
                        local ing = {}
                        for _, i in pairs(rc.ingredients) do ing[#ing + 1] = {name = i.name, amount = i.amount, type = i.type} end
                        local pr = {}
                        for _, q in pairs(rc.products) do pr[#pr + 1] = {name = q.name, amount = q.amount or ((q.amount_min or 0) + (q.amount_max or 0)) / 2, probability = q.probability} end
                        local cat = nil
                        pcall(function() cat = rc.category end)
                        if not cat then pcall(function() cat = rc.prototype.category end) end
                        if not cat then pcall(function() local cs = rc.prototype.categories cat = cs and (cs[1] or next(cs)) end) end
                        if type(cat) == "table" then cat = cat.name or cat[1] end
                        list[#list + 1] = {recipe = rn, energy = rc.energy, ingredients = ing, products = pr, category = cat}
                    end
                end
            end
        end
        out[name] = list
    end
    -- crafting speeds of the machines the force has
    local speeds = {}
    for _, n in ipairs({"assembling-machine-1", "assembling-machine-2", "assembling-machine-3", "stone-furnace", "steel-furnace",
                        "electric-furnace", "chemical-plant", "oil-refinery", "electric-mining-drill", "burner-mining-drill", "pumpjack"}) do
        local p = prototypes.entity[n]
        if p then pcall(function() speeds[n] = p.get_crafting_speed and p.get_crafting_speed() or p.crafting_speed or p.mining_speed end) end
    end
    return {recipes = out, speeds = speeds}
end

storage.actions.flow_read = function(player_index, op, spec_hex)
    local player = storage.agent_characters[player_index]
    local function unhex(h) return (h:gsub("%x%x", function(c) return string.char(tonumber(c, 16)) end)) end
    local f = F[op]
    if not f then error('"flow_read: unknown op ' .. tostring(op) .. '"') end
    return fh(f(player, helpers.json_to_table(unhex(spec_hex or "")) or {}))
end
