-- turret_feed: why is a turret (nearly) out of ammo? Read only. For every ammo turret in the
-- area with fewer than `low` magazines, follow its feed one hop back the way a player would
-- look: which inserter drops into it, is that inserter powered, and does its pickup (belt,
-- chest) hold any ammo.
-- area (hex JSON): {"x0","y0","x1","y1"} or {} for every turret of the force.
storage.actions.turret_feed = function(player_index, area_hex, low, limit)
    local player = storage.agent_characters[player_index]
    local surface = player.surface
    local force = player.force
    low = tonumber(low) or 1
    limit = tonumber(limit) or 40
    local function unhex(h) return (h:gsub("%x%x", function(c) return string.char(tonumber(c, 16)) end)) end
    local area = helpers.json_to_table(unhex(area_hex)) or {}
    local st = {}
    for k, v in pairs(defines.entity_status) do st[v] = k end
    local filt = {force = force, type = {"ammo-turret"}}
    if area.x0 then filt.area = {{area.x0, area.y0}, {area.x1, area.y1}} end
    local function is_ammo(name)
        local p = prototypes.item[name]
        return p and p.type == "ammo"
    end
    local function ammo_in_inv(inv)
        local n = 0
        if not inv then return 0 end
        for _, it in pairs(inv.get_contents()) do
            if is_ammo(it.name) then n = n + it.count end
        end
        return n
    end
    local function ammo_of(e)
        if not (e and e.valid) then return 0 end
        if e.type == "transport-belt" or e.type == "underground-belt" or e.type == "splitter" then
            local n = 0
            for i = 1, e.get_max_transport_line_index() do
                for _, it in pairs(e.get_transport_line(i).get_contents()) do
                    if is_ammo(it.name) then n = n + it.count end
                end
            end
            return n
        end
        local inv = e.get_inventory(defines.inventory.chest)
        return ammo_in_inv(inv)
    end
    local out = {turrets = 0, ok = 0, low = {}, reasons = {}}
    for _, t in pairs(surface.find_entities_filtered(filt)) do
        out.turrets = out.turrets + 1
        local n = ammo_in_inv(t.get_inventory(defines.inventory.turret_ammo))
        if n >= low then
            out.ok = out.ok + 1
        else
            local rec = {x = t.position.x, y = t.position.y, ammo = n}
            local feeders = {}
            local bb = t.bounding_box
            for _, ins in pairs(surface.find_entities_filtered{type = "inserter", force = force,
                    area = {{bb.left_top.x - 3, bb.left_top.y - 3}, {bb.right_bottom.x + 3, bb.right_bottom.y + 3}}}) do
                if ins.drop_target == t then table.insert(feeders, ins) end
            end
            if #feeders == 0 then
                rec.reason = "no_inserter"
            else
                local ins = feeders[1]
                rec.ins_x, rec.ins_y = ins.position.x, ins.position.y
                rec.ins_status = ins.status and st[ins.status] or "none"
                local src = ins.pickup_target
                if src then
                    rec.src = src.name
                    rec.src_x, rec.src_y = src.position.x, src.position.y
                    rec.src_ammo = ammo_of(src)
                end
                if rec.ins_status == "no_power" or rec.ins_status == "low_power" then
                    rec.reason = "inserter_unpowered"
                elseif rec.ins_status == "no_fuel" then
                    rec.reason = "inserter_no_fuel"
                elseif rec.ins_status == "disabled_by_script" or rec.ins_status == "disabled" then
                    rec.reason = "inserter_disabled"
                elseif not src then
                    rec.reason = "inserter_picks_from_nothing"
                elseif (rec.src_ammo or 0) == 0 then
                    if src.type == "container" or src.type == "logistic-container" then
                        rec.reason = "chest_empty"
                    else
                        rec.reason = "belt_empty"
                    end
                else
                    rec.reason = "feeding"
                end
            end
            out.reasons[rec.reason] = (out.reasons[rec.reason] or 0) + 1
            if #out.low < limit then table.insert(out.low, rec) end
        end
    end
    local j = helpers.table_to_json(out)
    return "FEEDHEX_" .. (j:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end
