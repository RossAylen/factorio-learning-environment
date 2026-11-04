-- where: the character's real position (read).
-- step_out = 1: if the character overlaps anything it collides with (buildings, cliffs, rocks,
--   trees - a restore or a build can leave it there), move it to the nearest free spot (<= 6).
-- step_out = 2 (a path request failed): also mine trees/rocks within reach, then always look
--   for the nearest free spot; report what encloses the character.
storage.actions.where = function(player_index, step_out)
    local player = storage.utils.ensure_valid_character(player_index)
    local surface = player.surface
    local pos = player.position
    local mode = tonumber(step_out) or (step_out == true and 1 or 0)
    local out = {x = pos.x, y = pos.y, moved = false, mined = 0, around = ""}
    if mode == 0 then return out end
    local cmask = prototypes.entity["character"].collision_mask.layers
    local function collides(e)
        if not e.valid or e == player or e.type == "character" or e.type == "item-entity"
                or e.type == "corpse" or e.type == "resource" then return false end
        local ok, layers = pcall(function() return e.prototype.collision_mask.layers end)
        if not ok or not layers then return false end
        for l, _ in pairs(layers) do if cmask[l] then return true end end
        return false
    end
    if mode == 2 then
        for _, e in pairs(surface.find_entities_filtered{position = pos, radius = 3, type = {"tree", "simple-entity"}}) do
            if e.valid and e.minable then
                local ok = pcall(function() return player.mine_entity(e, false) end)
                if ok then out.mined = out.mined + 1 end
            end
        end
    end
    local inside = false
    local bb = player.bounding_box
    for _, e in pairs(surface.find_entities_filtered{area = {{bb.left_top.x - 0.05, bb.left_top.y - 0.05},
            {bb.right_bottom.x + 0.05, bb.right_bottom.y + 0.05}}}) do
        if collides(e) then inside = true break end
    end
    if inside or mode == 2 then
        local p = surface.find_non_colliding_position("character", pos, 6, 0.25)
        if p and ((p.x - pos.x) ^ 2 + (p.y - pos.y) ^ 2 > 0.01) then
            player.teleport(p)
            out.moved = true
        end
        if mode == 2 then
            local names = {}
            for _, e in pairs(surface.find_entities_filtered{position = player.position, radius = 3}) do
                if collides(e) and #names < 6 then
                    table.insert(names, e.name .. "@" .. e.position.x .. "," .. e.position.y)
                end
            end
            out.around = table.concat(names, " ")
        end
    end
    local np = player.position
    out.x, out.y = np.x, np.y
    return out
end
