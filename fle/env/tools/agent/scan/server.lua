-- scan: a LEAN read of our entities by name within a radius - position plus the few fields the
-- helpers need (chest contents, furnace output, fuel, turret ammo, drill drop tile, status).
-- get_entities serialises everything (seconds on a big base); this is milliseconds.
storage.actions.scan = function(player_index, names_hex, x, y, radius, limit)
    local player = storage.agent_characters[player_index]
    local surface = player.surface
    local function unhex(h) return (h:gsub("%x%x", function(c) return string.char(tonumber(c, 16)) end)) end
    local names = helpers.json_to_table(unhex(names_hex)) or {}
    local st = {}
    for k, v in pairs(defines.entity_status) do st[v] = k end
    limit = tonumber(limit) or 3000
    local function contents(inv)
        if not inv then return nil end
        local out = {}
        for _, it in pairs(inv.get_contents()) do out[it.name] = (out[it.name] or 0) + it.count end
        return out
    end
    local out = {}
    for _, e in pairs(surface.find_entities_filtered{position = {tonumber(x), tonumber(y)}, radius = tonumber(radius),
                                                     name = names, force = player.force}) do
        if #out >= limit then break end
        local r = {n = e.name, x = e.position.x, y = e.position.y}
        if e.type == "electric-pole" then r.net = e.electric_network_id end
        local s = e.status and st[e.status]
        if s then r.s = s end
        if e.type == "container" or e.type == "logistic-container" then
            r.inv = contents(e.get_inventory(defines.inventory.chest))
        elseif e.type == "furnace" or e.type == "assembling-machine" then
            r.out = contents(e.get_output_inventory())
        elseif e.type == "ammo-turret" then
            r.ammo = contents(e.get_inventory(defines.inventory.turret_ammo))
        elseif e.type == "mining-drill" then
            local dp = e.drop_position
            if dp then r.dx, r.dy = dp.x, dp.y end
        end
        if e.burner then r.fuel = contents(e.burner.inventory) end
        table.insert(out, r)
    end
    local j = helpers.table_to_json(out)
    return "SCANHEX_" .. (j:gsub(".", function(ch) return string.format("%02x", ch:byte()) end))
end
