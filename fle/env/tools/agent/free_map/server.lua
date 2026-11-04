-- free_map: what occupies each cell of a rectangle, as a text map. Read only.
-- cell chars: '.' free, 't' trees/rocks only (clearable), '#' our entities, 'w' water,
-- 'E' enemy buildings, 'o' free but on ore (fine to build on, not for a mine of another ore)
storage.actions.free_map = function(player_index, x0, y0, x1, y1, cell)
    local player = storage.agent_characters[player_index]
    local surface = player.surface
    local force = player.force
    x0, y0, x1, y1 = tonumber(x0), tonumber(y0), tonumber(x1), tonumber(y1)
    cell = tonumber(cell) or 4
    local IGNORE = {["character"] = true, ["item-entity"] = true, ["corpse"] = true, ["character-corpse"] = true,
                    ["highlight-box"] = true, ["speech-bubble"] = true, ["flying-text"] = true,
                    ["particle-source"] = true, ["entity-ghost"] = true, ["tile-ghost"] = true}
    local WATER = {"water", "deepwater", "water-green", "deepwater-green", "water-shallow", "water-mud", "water-wube"}
    local rows = {}
    local counts = {}
    local y = y0
    while y < y1 do
        local line = {}
        local x = x0
        while x < x1 do
            local area = {{x + 0.01, y + 0.01}, {x + cell - 0.01, y + cell - 0.01}}
            local c = "."
            local ore = false
            for _, e in pairs(surface.find_entities_filtered{area = area}) do
                if e.valid and not IGNORE[e.type] then
                    if e.type == "resource" then
                        ore = true
                    elseif e.force == force then
                        c = "#" break
                    elseif e.type == "tree" or e.type == "simple-entity" or e.type == "fish" then
                        if c == "." then c = "t" end
                    elseif e.force.name == "enemy" then
                        c = "E"
                    elseif c == "." then
                        c = "t"
                    end
                end
            end
            if c == "." or c == "t" then
                local ok, n = pcall(function() return surface.count_tiles_filtered{area = area, name = WATER, limit = 1} end)
                if ok and n and n > 0 then c = "w" end
            end
            if c == "." and ore then c = "o" end
            counts[c] = (counts[c] or 0) + 1
            table.insert(line, c)
            x = x + cell
        end
        table.insert(rows, table.concat(line))
        y = y + cell
    end
    local j = helpers.table_to_json({x0 = x0, y0 = y0, cell = cell, rows = rows, counts = counts})
    return "FREEHEX_" .. (j:gsub(".", function(ch) return string.format("%02x", ch:byte()) end))
end
