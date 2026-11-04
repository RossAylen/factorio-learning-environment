-- where: the character's real position (read). With step_out = true, a character standing
-- INSIDE a solid entity (a building placed over it, a row built around it) is moved to the
-- nearest free spot within 3 tiles first - in the game a player is never inside a building.
storage.actions.where = function(player_index, step_out)
    local player = storage.utils.ensure_valid_character(player_index)
    local pos = player.position
    local moved = false
    if step_out == 1 or step_out == "1" or step_out == true then
        local surface = player.surface
        local inside = false
        local bb = player.bounding_box
        for _, e in pairs(surface.find_entities_filtered{area = bb}) do
            if e.valid and e ~= player and e.type ~= "character" and e.type ~= "resource"
                    and e.type ~= "item-entity" and e.type ~= "corpse" and e.type ~= "transport-belt"
                    and e.type ~= "underground-belt" and e.type ~= "splitter" then
                local ok, col = pcall(function()
                    return e.prototype.collision_mask and e.prototype.collision_mask.layers and e.prototype.collision_mask.layers.player
                end)
                if ok and col then inside = true break end
            end
        end
        if inside then
            local p = surface.find_non_colliding_position("character", pos, 3, 0.25)
            if p then
                player.teleport(p)
                pos = player.position
                moved = true
            end
        end
    end
    return {x = pos.x, y = pos.y, moved = moved}
end
