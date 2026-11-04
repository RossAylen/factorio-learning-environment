-- vitals: is this agent's character alive, its health, recent character deaths (all agents), evolution
storage.actions.vitals = function(player_index, since)
    local c = storage.agent_characters and storage.agent_characters[player_index]
    local out = {alive = (c ~= nil and c.valid) and true or false, tick = game.tick, me = player_index, deaths = {}}
    if out.alive then
        out.x, out.y, out.hp = c.position.x, c.position.y, c.health
        out.max_hp = c.max_health
    end
    pcall(function() out.evo = game.forces.enemy.get_evolution_factor(game.surfaces[1]) end)
    since = tonumber(since) or -1
    if since < 0 then since = game.tick - 108000 end
    for _, d in ipairs(storage.deaths or {}) do
        if d.tick >= since then out.deaths[#out.deaths + 1] = d end
    end
    local j = helpers.table_to_json(out)
    return "VITHEX_" .. (j:gsub(".", function(ch) return string.format("%02x", ch:byte()) end))
end
