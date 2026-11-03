-- enemies_near: what the player would see around a position (units, spawners, worms).
storage.actions.enemies_near = function(player_index, x, y, radius)
    local player = storage.agent_characters[player_index]
    local surface = player.surface
    radius = tonumber(radius) or 40
    local units, spawners, worms = 0, 0, 0
    local nearest, nd = nil, math.huge
    for _, e in pairs(surface.find_entities_filtered{position = {x, y}, radius = radius, force = "enemy"}) do
        if e.type == "unit" then units = units + 1
        elseif e.type == "unit-spawner" then spawners = spawners + 1
        elseif e.type == "turret" then worms = worms + 1 end
        if e.type == "unit" or e.type == "unit-spawner" or e.type == "turret" then
            local d = (e.position.x - x) ^ 2 + (e.position.y - y) ^ 2
            if d < nd then nd = d nearest = e end
        end
    end
    return {units = units, spawners = spawners, worms = worms,
            nearest_x = nearest and nearest.position.x or 0, nearest_y = nearest and nearest.position.y or 0,
            nearest_dist = nearest and math.sqrt(nd) or -1,
            evolution = game.forces.enemy.get_evolution_factor(surface)}
end
