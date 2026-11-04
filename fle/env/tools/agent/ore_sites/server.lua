-- ore_sites: where does a mining layout fit on PURE ore? Read only.
-- spec (hex JSON): {"resource": "iron-ore", "w": 7, "h": 7, "x": cx, "y": cy, "radius": 40,
--   "drills": [{"x": 1.5, "y": 1.5, "r": 2.49}], "trees_ok": false, "limit": 8}
-- origins are integer left-top corners; drill x/y are relative to the origin.
storage.actions.ore_sites = function(player_index, spec_hex)
    local player = storage.agent_characters[player_index]
    local surface = player.surface
    local function unhex(h) return (h:gsub("%x%x", function(c) return string.char(tonumber(c, 16)) end)) end
    local s = helpers.json_to_table(unhex(spec_hex)) or {}
    local res, W, H = s.resource, s.w, s.h
    local R = s.radius or 40
    local limit = s.limit or 8
    local gx0, gy0 = math.floor(s.x - R - W), math.floor(s.y - R - H)
    local gx1, gy1 = math.ceil(s.x + R + W), math.ceil(s.y + R + H)
    local IGNORE = {["character"] = true, ["item-entity"] = true, ["corpse"] = true, ["character-corpse"] = true,
                    ["resource"] = true, ["highlight-box"] = true, ["speech-bubble"] = true, ["flying-text"] = true,
                    ["particle-source"] = true, ["entity-ghost"] = true, ["tile-ghost"] = true}
    -- per tile: ore name / amount and blocked (2 = our/enemy entity, 1 = tree/rock)
    local ore, amt, blk = {}, {}, {}
    local function k(x, y) return (y - gy0) * 100000 + (x - gx0) end
    for _, e in pairs(surface.find_entities_filtered{area = {{gx0, gy0}, {gx1, gy1}}, type = "resource"}) do
        local x, y = math.floor(e.position.x), math.floor(e.position.y)
        ore[k(x, y)] = e.name
        amt[k(x, y)] = e.amount
    end
    for _, e in pairs(surface.find_entities_filtered{area = {{gx0, gy0}, {gx1, gy1}}}) do
        if e.valid and not IGNORE[e.type] then
            local bb = e.bounding_box
            local v = (e.type == "tree" or e.type == "simple-entity") and 1 or 2
            for x = math.floor(bb.left_top.x + 0.01), math.ceil(bb.right_bottom.x - 0.01) - 1 do
                for y = math.floor(bb.left_top.y + 0.01), math.ceil(bb.right_bottom.y - 0.01) - 1 do
                    local kk = k(x, y)
                    if (blk[kk] or 0) < v then blk[kk] = v end
                end
            end
        end
    end
    local WATER = {"water", "deepwater", "water-green", "deepwater-green", "water-shallow", "water-mud"}
    for _, t in pairs(surface.find_tiles_filtered{area = {{gx0, gy0}, {gx1, gy1}}, name = WATER}) do
        blk[k(t.position.x, t.position.y)] = 2
    end
    local cands = {}
    local reasons = {blocked = 0, trees = 0, mixed = 0, no_ore = 0}
    for oy = math.floor(s.y - R), math.ceil(s.y + R) do
        for ox = math.floor(s.x - R), math.ceil(s.x + R) do
            local bad, trees = nil, 0
            for y = oy, oy + H - 1 do
                for x = ox, ox + W - 1 do
                    local b = blk[k(x, y)]
                    if b == 2 then bad = "blocked" break end
                    if b == 1 then trees = trees + 1 end
                end
                if bad then break end
            end
            if not bad and trees > 0 and not s.trees_ok then bad = "trees" end
            local total = 0
            if not bad then
                for _, d in ipairs(s.drills or {}) do
                    local r = d.r or 2.49
                    local cx, cy = ox + d.x, oy + d.y
                    local n = 0
                    for y = math.floor(cy - r), math.floor(cy + r) do
                        for x = math.floor(cx - r), math.floor(cx + r) do
                            local o = ore[k(x, y)]
                            if o and o ~= res then bad = "mixed" break end
                            if o then n = n + 1 total = total + amt[k(x, y)] end
                        end
                        if bad then break end
                    end
                    if bad then break end
                    if n == 0 then bad = "no_ore" break end
                end
            end
            if bad then
                reasons[bad] = reasons[bad] + 1
            else
                local dd = (ox + W / 2 - s.x) ^ 2 + (oy + H / 2 - s.y) ^ 2
                table.insert(cands, {x = ox, y = oy, d = math.sqrt(dd), amount = total, trees = trees})
            end
        end
    end
    table.sort(cands, function(a, b) return a.d < b.d end)
    local out = {sites = {}, found = #cands, reasons = reasons}
    for i = 1, math.min(limit, #cands) do table.insert(out.sites, cands[i]) end
    local j = helpers.table_to_json(out)
    return "OREHEX_" .. (j:gsub(".", function(ch) return string.format("%02x", ch:byte()) end))
end
