-- corpses: character corpses (they hold a dead agent's inventory) - list, or mine one (items to this character)
storage.actions.corpses = function(player_index, op, x, y, radius)
    local c = storage.agent_characters[player_index]
    local out = {}
    if op == "mine" then
        local cp = c.surface.find_entities_filtered{name = "character-corpse", position = {tonumber(x), tonumber(y)}, radius = 2, limit = 1}[1]
        if not cp then error('"corpses: no character corpse at ' .. x .. ',' .. y .. '"') end
        local d = math.sqrt((cp.position.x - c.position.x) ^ 2 + (cp.position.y - c.position.y) ^ 2)
        if d > 10 then error('"corpses: too far away (' .. string.format("%.0f", d) .. ' tiles) - walk within 10 first"') end
        local inv = cp.get_inventory(defines.inventory.character_corpse)
        local moved, left = 0, 0
        if inv then
            for i = 1, #inv do
                local st = inv[i]
                if st.valid_for_read then
                    local n = c.insert(st)
                    moved = moved + n
                    if n >= st.count then st.clear() else st.count = st.count - n left = left + st.count end
                end
            end
        end
        if inv and inv.is_empty() then cp.destroy() end
        out = {moved = moved, left = left}
    else
        local list = {}
        for _, cp in pairs(c.surface.find_entities_filtered{name = "character-corpse", position = {tonumber(x), tonumber(y)}, radius = tonumber(radius) or 3000}) do
            local inv = cp.get_inventory(defines.inventory.character_corpse)
            local n = 0
            if inv then for k, v in pairs(inv.get_contents()) do n = n + (v.count or v) end end
            if n > 0 then list[#list + 1] = {x = cp.position.x, y = cp.position.y, items = n} end
        end
        out = {corpses = list}
    end
    local j = helpers.table_to_json(out)
    return "CORPHEX_" .. (j:gsub(".", function(ch) return string.format("%02x", ch:byte()) end))
end
