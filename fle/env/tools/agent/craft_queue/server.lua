-- craft_queue: the character's hand-crafting queue (slow mode: crafting takes real time). Read only.
storage.actions.craft_queue = function(player_index)
    local player = storage.agent_characters[player_index]
    local out = {size = 0, items = {}}
    local ok, q = pcall(function() return player.crafting_queue end)
    if ok and q then
        for _, it in ipairs(q) do
            if not it.prerequisite then
                local r = it.recipe
                local name = type(r) == "string" and r or (r and r.name) or "?"
                out.items[name] = (out.items[name] or 0) + it.count
            end
        end
    end
    local ok2, n = pcall(function() return player.crafting_queue_size end)
    out.size = ok2 and n or 0
    local j = helpers.table_to_json(out)
    return "CQHEX_" .. (j:gsub(".", function(ch) return string.format("%02x", ch:byte()) end))
end
