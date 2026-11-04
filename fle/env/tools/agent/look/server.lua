-- look: what a player sees hovering over everything in a circle. Read only.
-- Entities grouped by name + status, with up to 4 examples each (position + a short detail:
-- recipe, contents, ammo, mined resource, fluid).
storage.actions.look = function(player_index, x, y, radius, names_hex, all_types)
    local player = storage.agent_characters[player_index]
    local surface = player.surface
    local force = player.force
    local function unhex(h) return (h:gsub("%x%x", function(c) return string.char(tonumber(c, 16)) end)) end
    local names = helpers.json_to_table(unhex(names_hex)) or {}
    local st = {}
    for k, v in pairs(defines.entity_status) do st[v] = k end
    local SKIP = {["transport-belt"] = true, ["underground-belt"] = true, ["pipe"] = true,
                  ["pipe-to-ground"] = true, ["electric-pole"] = true, ["character"] = true}
    local filt = {position = {tonumber(x), tonumber(y)}, radius = tonumber(radius) or 8, force = force}
    if #names > 0 then filt.name = names end
    local function inv_text(inv)
        if not inv then return nil end
        local c = inv.get_contents()
        if #c == 0 then return nil end
        table.sort(c, function(a, b) return a.count > b.count end)
        local parts = {}
        for i = 1, math.min(3, #c) do table.insert(parts, c[i].name .. "=" .. c[i].count) end
        if #c > 3 then table.insert(parts, "+" .. (#c - 3)) end
        return table.concat(parts, " ")
    end
    local function detail(e)
        local d = {}
        if e.type == "assembling-machine" or e.type == "furnace" then
            local r = e.get_recipe and e.get_recipe()
            if not r and e.type == "furnace" then pcall(function() r = e.previous_recipe end) end
            if r then table.insert(d, "recipe " .. (type(r.name) == "string" and r.name or (r.name and r.name.name) or "?")) end
            local out = inv_text(e.get_output_inventory())
            if out then table.insert(d, "out " .. out) end
        elseif e.type == "container" or e.type == "logistic-container" then
            table.insert(d, inv_text(e.get_inventory(defines.inventory.chest)) or "empty")
        elseif e.type == "ammo-turret" then
            table.insert(d, "ammo " .. (inv_text(e.get_inventory(defines.inventory.turret_ammo)) or "0"))
        elseif e.type == "mining-drill" then
            local t = e.mining_target
            table.insert(d, t and ("mines " .. t.name) or "mines nothing")
        elseif e.type == "lab" then
            table.insert(d, inv_text(e.get_inventory(defines.inventory.lab_input)) or "no packs")
        end
        if e.type ~= "character" and e.burner then
            table.insert(d, "fuel " .. (inv_text(e.burner.inventory) or "0"))
        end
        pcall(function()
            local c = e.get_fluid_contents and e.get_fluid_contents() or {}   -- 2.1: no e.fluidbox
            local k = 0
            for name, amt in pairs(c) do
                k = k + 1
                if k <= 3 then table.insert(d, name .. "=" .. math.floor(amt)) end
            end
        end)
        return table.concat(d, ", ")
    end
    local groups, order, total = {}, {}, 0
    for _, e in pairs(surface.find_entities_filtered(filt)) do
        if e.valid and (all_types or #names > 0 or not SKIP[e.type]) and e.type ~= "character" then
            total = total + 1
            local s = e.status and st[e.status] or "-"
            local k = e.name .. "|" .. s
            if not groups[k] then
                groups[k] = {name = e.name, status = s, n = 0, ex = {}}
                table.insert(order, k)
            end
            local g = groups[k]
            g.n = g.n + 1
            if #g.ex < 4 then
                local ok, d = pcall(detail, e)
                table.insert(g.ex, {x = e.position.x, y = e.position.y, d = ok and d or ""})
            end
        end
    end
    local out = {total = total, groups = {}}
    for _, k in ipairs(order) do table.insert(out.groups, groups[k]) end
    local j = helpers.table_to_json(out)
    return "LOOKHEX_" .. (j:gsub(".", function(ch) return string.format("%02x", ch:byte()) end))
end
