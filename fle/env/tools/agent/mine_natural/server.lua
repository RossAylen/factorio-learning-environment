-- mine_natural: mine the trees / rocks standing at the given positions (within the character's
-- reach), like a player clicking them. Dead trees and rocks give what they give.
storage.actions.mine_natural = function(player_index, pos_hex)
    local player = storage.agent_characters[player_index]
    local surface = player.surface
    local function unhex(h) return (h:gsub("%x%x", function(c) return string.char(tonumber(c, 16)) end)) end
    local pts = helpers.json_to_table(unhex(pos_hex)) or {}
    local mined, far, none = 0, 0, 0
    local reach = player.resource_reach_distance or 2.7
    for _, p in ipairs(pts) do
        local es = surface.find_entities_filtered{position = {p[1], p[2]}, radius = 0.8, type = {"tree", "simple-entity"}}
        if #es == 0 then none = none + 1 end
        for _, e in pairs(es) do
            if e.valid and e.minable then
                local d = math.sqrt((e.position.x - player.position.x) ^ 2 + (e.position.y - player.position.y) ^ 2)
                if d > reach + 8 then far = far + 1
                elseif pcall(function() return player.mine_entity(e, false) end) then mined = mined + 1 end
            end
        end
    end
    return {mined = mined, far = far, none = none}
end
