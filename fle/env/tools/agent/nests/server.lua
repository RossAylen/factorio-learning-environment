-- nests: enemy spawners and worms around a point, with the pollution where they stand (a nest
-- inside the pollution cloud absorbs it and sends attacks). Read only.
storage.actions.nests = function(player_index, x, y, radius, limit)
    local player = storage.agent_characters[player_index]
    local surface = player.surface
    x, y, radius, limit = tonumber(x), tonumber(y), tonumber(radius) or 200, tonumber(limit) or 60
    local out = {nests = {}, total = 0, polluted = 0, cloud_radius = 0}
    local list = surface.find_entities_filtered{position = {x, y}, radius = radius, force = "enemy",
                                                 type = {"unit-spawner", "turret"}}
    for _, e in pairs(list) do
        local d = math.sqrt((e.position.x - x) ^ 2 + (e.position.y - y) ^ 2)
        local pol = surface.get_pollution(e.position)
        out.total = out.total + 1
        if pol > 0 then out.polluted = out.polluted + 1 end
        table.insert(out.nests, {x = e.position.x, y = e.position.y, name = e.name, type = e.type,
                                 d = math.floor(d), pollution = math.floor(pol)})
    end
    table.sort(out.nests, function(a, b) return a.d < b.d end)
    while #out.nests > limit do table.remove(out.nests) end
    -- how far the cloud reaches: farthest polluted chunk centre on 8 rays (32-tile steps)
    for a = 0, 7 do
        local ang = a * math.pi / 4
        for r = 32, 640, 32 do
            if surface.get_pollution({x + math.cos(ang) * r, y + math.sin(ang) * r}) <= 0 then break end
            if r > out.cloud_radius then out.cloud_radius = r end
        end
    end
    local j = helpers.table_to_json(out)
    return "NESTHEX_" .. (j:gsub(".", function(ch) return string.format("%02x", ch:byte()) end))
end
