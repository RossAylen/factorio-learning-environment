-- contam: continuous, cheap belt-contamination detection. The planner side stores per registered
-- line the items that belong on it and a few belt tiles near its consumer end; every 300 ticks a
-- handful of lines are checked (round robin, capped) and foreign items become events.
local function ch(t)
    local j = helpers.table_to_json(t)
    return "CONTHEX_" .. (j:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end
storage.contam = storage.contam or {lines = {}, events = {}, next = 1}

local function check_line(surf, L)
    local ok_items = {}
    for _, n in ipairs(L.items or {}) do ok_items[n] = true end
    for _, t in ipairs(L.tiles or {}) do
        for _, e in pairs(surf.find_entities_filtered{position = {t[1], t[2]}, radius = 0.4,
                type = {"transport-belt", "underground-belt", "splitter"}}) do
            for li = 1, math.min(2, e.get_max_transport_line_index()) do
                for _, it in pairs(e.get_transport_line(li).get_contents()) do
                    if not ok_items[it.name] then
                        local key = L.id .. "|" .. it.name
                        local ev = storage.contam.events[key]
                        if ev then
                            ev.count = ev.count + it.count
                            ev.last_seen = game.tick
                        else
                            storage.contam.events[key] = {line = L.id, item = it.name, x = e.position.x, y = e.position.y,
                                first_seen = game.tick, last_seen = game.tick, count = it.count}
                        end
                    end
                end
            end
        end
    end
end

script.on_nth_tick(60, function(ev)
    if ev.tick % 300 ~= 0 then return end
    local C = storage.contam
    if not C or #C.lines == 0 then return end
    local surf = game.surfaces[1]
    local n = math.min(#C.lines, 8)   -- 8 lines x ~4 tiles per check: well under 2 ms
    for _ = 1, n do
        if C.next > #C.lines then C.next = 1 end
        pcall(check_line, surf, C.lines[C.next])
        C.next = C.next + 1
    end
end)

local A = {}
A.set_lines = function(player, spec)
    storage.contam.lines = spec.lines or {}
    storage.contam.next = 1
    return {lines = #storage.contam.lines}
end
A.events = function(player, spec)
    local out = {}
    for k, e in pairs(storage.contam.events) do
        if not spec.since or e.last_seen >= spec.since then out[#out + 1] = e end
    end
    if spec.clear then storage.contam.events = {} end
    return {events = out, tick = game.tick, lines = #storage.contam.lines}
end
A.check_now = function(player, spec)
    local surf = player.surface
    for _, L in ipairs(storage.contam.lines) do pcall(check_line, surf, L) end
    return A.events(player, {})
end
-- what puts items onto the belt tile (x, y): inserters dropping there, belts/undergrounds/splitters
-- pointing into it (other than `from`, the line's own previous tile)
A.injectors = function(player, spec)
    local surf = player.surface
    local x, y = spec.x, spec.y
    local out = {}
    for _, i in pairs(surf.find_entities_filtered{position = {x, y}, radius = 3, type = "inserter"}) do
        local dp = i.drop_position
        if dp and math.floor(dp.x) == math.floor(x) and math.floor(dp.y) == math.floor(y) then
            local pt = i.pickup_target
            out[#out + 1] = {k = "inserter", n = i.name, x = i.position.x, y = i.position.y,
                             from = pt and (pt.name .. "@" .. pt.position.x .. "," .. pt.position.y) or nil}
        end
    end
    local DV = {[0] = {0, -1}, [4] = {1, 0}, [8] = {0, 1}, [12] = {-1, 0}}
    for _, b in pairs(surf.find_entities_filtered{area = {{x - 1.6, y - 1.6}, {x + 1.6, y + 1.6}},
            type = {"transport-belt", "underground-belt", "splitter"}}) do
        local dv = DV[b.direction]
        if dv and not (b.position.x == x and b.position.y == y) then
            local outputs = b.type ~= "underground-belt" or b.belt_to_ground_type == "output"
            if outputs and math.abs(b.position.x + dv[1] - x) < 0.6 and math.abs(b.position.y + dv[2] - y) < 0.6 then
                local skip = spec.from and math.abs(b.position.x - spec.from[1]) < 0.1 and math.abs(b.position.y - spec.from[2]) < 0.1
                if not skip then out[#out + 1] = {k = b.type, n = b.name, x = b.position.x, y = b.position.y} end
            end
        end
        if b.type == "underground-belt" and b.belt_to_ground_type == "output" and b.position.x == x and b.position.y == y then
            local nb = storage.neighbours and storage.neighbours(b) or nil
            out[#out + 1] = {k = "underground pair", n = b.name, x = b.position.x, y = b.position.y,
                             from = nb and nb.valid and (nb.position.x .. "," .. nb.position.y) or "unpaired"}
        end
    end
    return {injectors = out}
end
-- filter the inserters given (spec.ins = [[x, y], ...]) to spec.items (2.x: every non-burner inserter filters)
A.filter_inserters = function(player, spec)
    local n, failed = 0, {}
    for _, p in ipairs(spec.ins or {}) do
        local i = player.surface.find_entities_filtered{position = {p[1], p[2]}, radius = 0.4, type = "inserter", force = player.force}[1]
        if i then
            local ok = pcall(function()
                i.use_filters = true
                i.inserter_filter_mode = "whitelist"
                for k = 1, i.filter_slot_count do i.set_filter(k, nil) end
                for k, item in ipairs(spec.items or {}) do if k <= i.filter_slot_count then i.set_filter(k, item) end end
            end)
            if ok then n = n + 1 else failed[#failed + 1] = i.name .. "@" .. p[1] .. "," .. p[2] end
        end
    end
    return {filtered = n, failed = failed}
end
-- splitter at (x, y): filter `item` to the `side` output (left/right)
A.splitter_filter = function(player, spec)
    local s = player.surface.find_entities_filtered{position = {spec.x, spec.y}, radius = 1, type = "splitter", force = player.force}[1]
    if not s then error('"contam: no splitter at ' .. spec.x .. ',' .. spec.y .. '"') end
    s.splitter_filter = spec.item and {name = spec.item} or nil
    s.splitter_output_priority = spec.side or "left"
    return {splitter = s.name, x = s.position.x, y = s.position.y, filter = spec.item, side = s.splitter_output_priority}
end

storage.actions.contam = function(player_index, op, spec_hex)
    local player = storage.agent_characters[player_index]
    local function unhex(h) return (h:gsub("%x%x", function(c) return string.char(tonumber(c, 16)) end)) end
    local f = A[op]
    if not f then error('"contam: unknown op ' .. tostring(op) .. '"') end
    return ch(f(player, helpers.json_to_table(unhex(spec_hex or "")) or {}))
end
