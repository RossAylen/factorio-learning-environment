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
            if fits then
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
                else
                    out.n_blocked = out.n_blocked + 1
                    local rec = {i = i, name = e.name, x = e.x, y = e.y, by = by}
                    if #by == 0 then
                        local t = surface.get_tile(e.x, e.y)
                        rec.why = "tile " .. (t and t.valid and t.name or "?")
                        out.blockers["tile:" .. (t and t.valid and t.name or "?")] = (out.blockers["tile:" .. (t and t.valid and t.name or "?")] or 0) + 1
                    end
                    if #out.blocked < limit then table.insert(out.blocked, rec) end
                end
            end
        end
    end
    local j = helpers.table_to_json(out)
    return "CANBHEX_" .. (j:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end
