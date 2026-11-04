-- audit_read: for every machine in an area, is each required input actually connected to a
-- source that can deliver it? Read only.
-- machines: assembling-machine (incl. chem plants, refineries), furnace, lab, ammo-turret, boiler
storage.actions.audit_read = function(player_index, x0, y0, x1, y1, limit)
    local player = storage.agent_characters[player_index]
    local surface = player.surface
    local force = player.force
    limit = tonumber(limit) or 800
    local area = {{tonumber(x0), tonumber(y0)}, {tonumber(x1), tonumber(y1)}}
    local st = {}
    for k, v in pairs(defines.entity_status) do st[v] = k end
    local BELT = {["transport-belt"] = true, ["underground-belt"] = true, ["splitter"] = true}

    -- who drops onto / picks from what (one pass over inserters and drills in the area + margin)
    local big = {{area[1][1] - 40, area[1][2] - 40}, {area[2][1] + 40, area[2][2] + 40}}
    local drops_into, picks_from = {}, {}
    for _, ins in pairs(surface.find_entities_filtered{area = big, type = "inserter", force = force}) do
        local d, p = ins.drop_target, ins.pickup_target
        if d and d.unit_number then
            drops_into[d.unit_number] = drops_into[d.unit_number] or {}
            table.insert(drops_into[d.unit_number], ins)
        end
        if p and p.unit_number then
            picks_from[p.unit_number] = (picks_from[p.unit_number] or 0) + 1
        end
    end
    local drill_onto = {}
    for _, dr in pairs(surface.find_entities_filtered{area = big, type = "mining-drill", force = force}) do
        local d = dr.drop_target
        if d and d.unit_number then
            drill_onto[d.unit_number] = drill_onto[d.unit_number] or {}
            table.insert(drill_onto[d.unit_number], dr)
        end
    end

    local function recipe_of(e)
        local r = nil
        pcall(function() r = e.get_recipe() end)
        if not r and e.type == "furnace" then pcall(function() r = e.previous_recipe end) end
        if r and r.name and type(r.name) ~= "string" then r = r.name end   -- {name=proto, quality}
        if type(r) == "table" and r.object_name == nil and r.name then r = prototypes.recipe[r.name] end
        if type(r) == "string" then r = prototypes.recipe[r] end
        return r
    end
    local function products(e)
        local out = {}
        if e.type == "assembling-machine" or e.type == "furnace" then
            local r = recipe_of(e)
            if r then for _, p in pairs(r.products) do if p.type == "item" then out[p.name] = true end end end
            local ok, inv = pcall(function() return e.get_output_inventory() end)
            if ok and inv then for _, it in pairs(inv.get_contents()) do out[it.name] = true end end
        elseif e.type == "container" or e.type == "logistic-container" then
            local inv = e.get_inventory(defines.inventory.chest)
            if inv then for _, it in pairs(inv.get_contents()) do out[it.name] = true end end
        elseif e.type == "mining-drill" then
            local t = e.mining_target
            if t then
                local ok, pr = pcall(function() return t.prototype.mineable_properties.products end)
                if ok and pr then for _, p in pairs(pr) do out[p.name] = true end end
            end
        end
        return out
    end

    -- items a belt network can deliver: items on it + what feeds it (upstream BFS), cached
    local net_cache = {}
    local function belt_items(b0)
        if net_cache[b0.unit_number] then return net_cache[b0.unit_number] end
        local items, seen, queue, n = {}, {}, {b0}, 0
        local members = {}
        while #queue > 0 and n < 3000 do
            local b = table.remove(queue)
            if b and b.valid and b.unit_number and not seen[b.unit_number] then
                seen[b.unit_number] = true
                n = n + 1
                table.insert(members, b.unit_number)
                for i = 1, b.get_max_transport_line_index() do
                    for _, it in pairs(b.get_transport_line(i).get_contents()) do items[it.name] = true end
                end
                for _, ins in pairs(drops_into[b.unit_number] or {}) do
                    local src = ins.pickup_target
                    if src then
                        if BELT[src.type] then table.insert(queue, src)
                        else for k, _ in pairs(products(src)) do items[k] = true end end
                    end
                end
                for _, dr in pairs(drill_onto[b.unit_number] or {}) do
                    for k, _ in pairs(products(dr)) do items[k] = true end
                end
                local ok, nb = pcall(function() return b.belt_neighbours end)
                if ok and nb and nb.inputs then for _, u in pairs(nb.inputs) do table.insert(queue, u) end end
                if b.type == "underground-belt" and b.belt_to_ground_type == "output" then
                    local ok2, o = pcall(function() return b.neighbours end)
                    if ok2 and o then table.insert(queue, o) end
                end
            end
        end
        for _, u in ipairs(members) do net_cache[u] = items end
        return items
    end

    local AMMO, FUEL = {}, {}
    local function is_ammo(n) local p = prototypes.item[n] return p and p.type == "ammo" end
    local function is_fuel(n) local p = prototypes.item[n] return p and p.fuel_value and p.fuel_value > 0 end

    local research_packs = {}
    local cr = force.current_research
    if cr then for _, ing in pairs(cr.research_unit_ingredients) do table.insert(research_packs, ing.name) end end

    local out = {machines = {}, research = cr and cr.name or "", truncated = false}
    local types = {"assembling-machine", "furnace", "lab", "ammo-turret", "boiler"}
    for _, e in pairs(surface.find_entities_filtered{area = area, type = types, force = force}) do
        if #out.machines >= limit then out.truncated = true break end
        local rec = {x = e.position.x, y = e.position.y, n = e.name, t = e.type,
                     s = e.status and st[e.status] or "-", inp = {}, p = {}}
        local need = {}       -- {item, kind}  kind: item / fluid / ammo / fuel
        if e.type == "assembling-machine" or e.type == "furnace" then
            local r = recipe_of(e)
            if r then
                rec.r = r.name
                rec.en = r.energy
                rec.sp = e.crafting_speed
                for _, ing in pairs(r.ingredients) do
                    table.insert(need, {ing.name, ing.type == "fluid" and "fluid" or "item", ing.amount})
                end
                for _, pr in pairs(r.products) do table.insert(rec.p, pr.name) end
            end
        elseif e.type == "lab" then
            for _, pk in ipairs(research_packs) do table.insert(need, {pk, "item", 1}) end
        elseif e.type == "ammo-turret" then
            table.insert(need, {"ammo", "ammo", 1})
        elseif e.type == "boiler" then
            table.insert(need, {"fuel", "fuel", 1})
        end
        local feeders = drops_into[e.unit_number] or {}
        for _, nd in ipairs(need) do
            local item, kind, amt = nd[1], nd[2], nd[3]
            local res = {item, 0, "no_inserter", amt}
            if kind == "fluid" then
                local ok_f = false
                pcall(function()
                    for i = 1, #e.fluidbox do
                        local f = e.fluidbox[i]
                        if f and f.name == item then ok_f = true end
                        local c = e.fluidbox.get_connections(i)
                        if c and #c > 0 and e.fluidbox.get_prototype(i).production_type == "input" then
                            ok_f = ok_f or (#c > 0)
                        end
                    end
                end)
                res = {item, ok_f and 1 or 0, ok_f and "ok" or "no_pipe", amt}
            elseif #feeders > 0 then
                res = {item, 0, "source_lacks", amt}
                for _, ins in ipairs(feeders) do
                    local src = ins.pickup_target
                    local items = {}
                    if not src then
                        res[3] = "inserter_picks_nothing"
                    elseif BELT[src.type] then
                        items = belt_items(src)
                    elseif src.type == "lab" then
                        res = {item, 2, "lab@" .. src.position.x .. "," .. src.position.y, amt}
                        break
                    else
                        items = products(src)
                    end
                    local hit = false
                    for k, _ in pairs(items) do
                        if k == item or (kind == "ammo" and is_ammo(k)) or (kind == "fuel" and is_fuel(k)) then hit = true break end
                    end
                    if hit then res = {item, 1, "ok", amt} break end
                    if src then res[5] = src.name .. "@" .. src.position.x .. "," .. src.position.y end
                end
            elseif kind == "fuel" or kind == "ammo" then
                -- hand-filled? count what is inside
                local inv = (kind == "fuel") and e.get_fuel_inventory() or e.get_inventory(defines.inventory.turret_ammo)
                if inv and not inv.is_empty() then res = {item, 1, "hand_filled", amt} end
            end
            table.insert(rec.inp, res)
        end
        if #rec.p > 0 and not picks_from[e.unit_number] and e.type ~= "lab" and e.type ~= "ammo-turret" and e.type ~= "boiler" then
            rec.no_taker = 1
        end
        table.insert(out.machines, rec)
    end
    local j = helpers.table_to_json(out)
    return "AUDHEX_" .. (j:gsub(".", function(ch) return string.format("%02x", ch:byte()) end))
end
