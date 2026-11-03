-- repair_entities: the character repairs damaged friendly entities within reach, spending
-- repair packs (durability = HP) like a player would; time is charged at the pack's speed.
storage.actions.repair_entities = function(player_index, radius, scan_radius)
    local player = storage.agent_characters[player_index]
    scan_radius = tonumber(scan_radius) or 0
    if scan_radius > 0 then
        -- list damaged entities (positions) around the character without repairing
        local out = {}
        for _, e in pairs(player.surface.find_entities_filtered{position = player.position, radius = scan_radius,
                                                              force = player.force}) do
            if e.valid and e.health and e.type ~= "character" then
                local maxh = nil
                pcall(function() maxh = e.max_health end)
                if not maxh then pcall(function() maxh = e.prototype.get_max_health() end) end
                if maxh and e.health < maxh - 0.01 then table.insert(out, {e.position.x, e.position.y}) end
            end
        end
        return {damaged = out, count = #out}
    end
    radius = math.min(tonumber(radius) or 10, player.reach_distance or 10)
    local inv = player.get_inventory(defines.inventory.character_main)
    local speed = 2
    pcall(function() speed = prototypes.item["repair-pack"].speed or 2 end)
    local repaired, hp_total, still = 0, 0, 0
    for _, e in pairs(player.surface.find_entities_filtered{position = player.position, radius = radius,
                                                          force = player.force}) do
        if e.valid and e.health and e.type ~= "character" then
            local maxh = nil
            pcall(function() maxh = e.max_health end)
            if not maxh then pcall(function() maxh = e.prototype.get_max_health() end) end
            if maxh and e.health < maxh then
                local need = maxh - e.health
                while need > 0.01 do
                    local stack = inv.find_item_stack("repair-pack")
                    if not stack then break end
                    local use = math.min(stack.durability, need)
                    stack.drain_durability(use)
                    e.health = e.health + use
                    need = need - use
                    hp_total = hp_total + use
                end
                if need > 0.01 then still = still + 1 else repaired = repaired + 1 end
            end
        end
    end
    storage.elapsed_ticks = storage.elapsed_ticks + math.ceil(hp_total / speed)
    return {repaired = repaired, hp = math.floor(hp_total), still_damaged = still,
            packs_left = inv.get_item_count("repair-pack")}
end
