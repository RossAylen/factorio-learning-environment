-- can_build: would these entities fit, and what stands in the way? Read only.
-- ents (hex JSON): [{"name", "x", "y", "d" (real game direction, 0 N .. 12 W)}, ...]
storage.actions.can_build = function(player_index, ents_hex, limit)
    local player = storage.agent_characters[player_index]
    local surface = player.surface
    local force = player.force
    limit = tonumber(limit) or 30
    local function unhex(h) return (h:gsub("%x%x", function(c) return string.char(tonumber(c, 16)) end)) end
    local ents = helpers.json_to_table(unhex(ents_hex)) or {}
    local IGNORE = {["character"] = true, ["item-entity"] = true, ["corpse"] = true, ["character-corpse"] = true,
                    ["resource"] = true, ["highlight-box"] = true, ["speech-bubble"] = true, ["flying-text"] = true,
                    ["entity-ghost"] = true, ["tile-ghost"] = true, ["particle-source"] = true}
    local out = {ok = 0, blocked = {}, n_blocked = 0, blockers = {}}
    for i, e in ipairs(ents) do
        local proto = prototypes.entity[e.name]
        if not proto then
            out.n_blocked = out.n_blocked + 1
            if #out.blocked < limit then table.insert(out.blocked, {i = i, name = e.name, x = e.x, y = e.y, why = "unknown entity"}) end
        else
            local d = tonumber(e.d) or 0
            local fits = surface.can_place_entity{name = e.name, position = {e.x, e.y}, direction = d, force = force,
                build_check_type = defines.build_check_type.manual}
            -- can_place_entity says yes to a fast-replace (a belt over an underground belt, an
            -- inserter over another inserter) - but the build creates entities, it never replaces:
            -- anything solid already in the footprint blocks, unless it is this very entity
            local replace = nil
            if fits then
                local cb0 = proto.collision_box
                local w0, h0 = cb0.right_bottom.x - cb0.left_top.x, cb0.right_bottom.y - cb0.left_top.y
                if d == 4 or d == 12 then w0, h0 = h0, w0 end
                for _, b in pairs(surface.find_entities_filtered{area = {{e.x - w0 / 2 + 0.05, e.y - h0 / 2 + 0.05},
                        {e.x + w0 / 2 - 0.05, e.y + h0 / 2 - 0.05}}}) do
                    if b.valid and not IGNORE[b.type] and b.type ~= "tree" and b.type ~= "simple-entity" then
                        local same_pos = math.abs(b.position.x - e.x) < 0.1 and math.abs(b.position.y - e.y) < 0.1
                        local same_dir = (not b.supports_direction) or b.direction == d
                        if not (b.name == e.name and same_pos and same_dir) then
                            replace = {name = b.name, x = b.position.x, y = b.position.y, own = (b.force == force) or nil}
                            if b.name == e.name and same_pos then replace.why = "same entity, direction " .. b.direction .. " not " .. d end
                            break
                        end
                    end
                end
            end
            if fits and replace then
                out.n_blocked = out.n_blocked + 1
                out.blockers[replace.name] = (out.blockers[replace.name] or 0) + 1
                if #out.blocked < limit then
                    table.insert(out.blocked, {i = i, name = e.name, x = e.x, y = e.y, by = {replace},
                                               why = replace.why or ("would replace " .. replace.name)})
                end
            elseif fits then
                out.ok = out.ok + 1
            else
                local cb = proto.collision_box
                local w, h = cb.right_bottom.x - cb.left_top.x, cb.right_bottom.y - cb.left_top.y
                if d == 4 or d == 12 then w, h = h, w end
                local by = {}
                local same = false
                for _, b in pairs(surface.find_entities_filtered{area = {{e.x - w / 2 + 0.05, e.y - h / 2 + 0.05},
                        {e.x + w / 2 - 0.05, e.y + h / 2 - 0.05}}}) do
                    if b.valid and not IGNORE[b.type] then
                        if b.name == e.name and math.abs(b.position.x - e.x) < 0.1 and math.abs(b.position.y - e.y) < 0.1 then
                            same = true
                        end
                        if #by < 3 then
                            table.insert(by, {name = b.name, x = b.position.x, y = b.position.y,
                                              own = (b.force == force) or nil})
                        end
                        local k = b.type == "tree" and "tree" or (b.type == "simple-entity" and "rock" or b.name)
                        out.blockers[k] = (out.blockers[k] or 0) + 1
                    end
                end
                if same then
                    out.ok = out.ok + 1
                    out.already = (out.already or 0) + 1
                elseif #by == 0 then
                    -- nothing solid in the footprint: only water / void / out-of-map tiles block;
                    -- characters (place_entity moves them aside) and items on the ground do not
                    local bad_tile = nil
                    for tx = math.floor(e.x - w / 2 + 0.05), math.floor(e.x + w / 2 - 0.05) do
                        for ty = math.floor(e.y - h / 2 + 0.05), math.floor(e.y + h / 2 - 0.05) do
                            local t = surface.get_tile(tx, ty)
                            if t and t.valid then
                                local hard = false
                                pcall(function() hard = t.collides_with("water_tile") end)
                                if not hard and (t.name == "out-of-map" or t.name == "empty-space" or
                                        string.find(t.name, "water") or t.name == "lava") then hard = true end
                                if hard then bad_tile = t.name break end
                            end
                        end
                        if bad_tile then break end
                    end
                    if bad_tile then
                        out.n_blocked = out.n_blocked + 1
                        out.blockers["tile:" .. bad_tile] = (out.blockers["tile:" .. bad_tile] or 0) + 1
                        if #out.blocked < limit then
                            table.insert(out.blocked, {i = i, name = e.name, x = e.x, y = e.y, by = {}, why = "tile " .. bad_tile})
                        end
                    else
                        out.ok = out.ok + 1
                        out.soft = (out.soft or 0) + 1   -- a character / ground items: not an obstacle
                    end
                else
                    out.n_blocked = out.n_blocked + 1
                    local rec = {i = i, name = e.name, x = e.x, y = e.y, by = by}
                    if #out.blocked < limit then table.insert(out.blocked, rec) end
                end
            end
        end
    end
    local j = helpers.table_to_json(out)
    return "CANBHEX_" .. (j:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end
