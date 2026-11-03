-- trace_items: can items get from one entity to another by belts, undergrounds, splitters,
-- inserters and drills? Breadth-first over the item-movement graph as the game sees it.
local TRACE_SKIP = {
    ['character'] = true, ['resource'] = true, ['item-entity'] = true, ['corpse'] = true,
    ['character-corpse'] = true, ['tree'] = true, ['simple-entity'] = true, ['fish'] = true,
    ['highlight-box'] = true, ['speech-bubble'] = true, ['flying-text'] = true,
}
local TRACE_DV = {[0] = {0, -1}, [4] = {1, 0}, [8] = {0, 1}, [12] = {-1, 0}}
local BELTISH = {['transport-belt'] = true, ['underground-belt'] = true, ['splitter'] = true,
                 ['loader'] = true, ['loader-1x1'] = true, ['linked-belt'] = true}

local function trace_desc(e)
    local s = e.name .. " at " .. e.position.x .. " " .. e.position.y
    if e.type == "underground-belt" then s = s .. " " .. e.belt_to_ground_type end
    return s
end

storage.actions.trace_items = function(player_index, sx, sy, tx, ty, max_nodes)
    local player = storage.agent_characters[player_index]
    local surface = player.surface
    max_nodes = tonumber(max_nodes) or 5000

    local function ent_at(x, y)
        for _, e in pairs(surface.find_entities_filtered{position = {x, y}}) do
            if not TRACE_SKIP[e.type] then return e end
        end
        return nil
    end
    local src = ent_at(sx, sy)
    if not src then error("\"trace_items: no entity at the source (" .. sx .. ", " .. sy .. ")\"") end
    local tgt = ent_at(tx, ty)
    if not tgt then error("\"trace_items: no entity at the target (" .. tx .. ", " .. ty .. ")\"") end

    local function key(e) return e.unit_number or (e.name .. e.position.x .. "," .. e.position.y) end
    local dead_ends, notes = {}, {}

    -- does belt-like entity n accept items coming from a belt piece at (fx,fy) moving in dir d?
    local function accepts(n, d)
        if not BELTISH[n.type] then return false end
        local nd = n.direction
        if (nd + 8) % 16 == d then return false end   -- head-on
        if n.type == "splitter" then return nd == d end
        if n.type == "underground-belt" and n.belt_to_ground_type == "output" then
            return nd ~= d   -- only side-loading onto an exit (its back is the tunnel)
        end
        return true
    end

    local function forward(e, out)
        local d = TRACE_DV[e.direction]
        if not d then return end
        local x, y = e.position.x + d[1], e.position.y + d[2]
        local n = ent_at(x, y)
        if n and accepts(n, e.direction) then
            table.insert(out, {n, "belt"})
        elseif n and BELTISH[n.type] then
            table.insert(dead_ends, trace_desc(e) .. " runs into " .. trace_desc(n) .. " the wrong way")
        else
            table.insert(dead_ends, trace_desc(e) .. " ends - next tile " .. x .. " " .. y ..
                         (n and (" holds " .. n.name) or " is empty"))
        end
    end

    local function nexts(e)
        local out = {}
        local t = e.type
        if t == "transport-belt" then
            forward(e, out)
        elseif t == "underground-belt" then
            if e.belt_to_ground_type == "input" then
                local nb = e.underground_belt_neighbour
                if nb then
                    table.insert(out, {nb, "underground"})
                else
                    table.insert(dead_ends, trace_desc(e) .. " has no exit - unpaired")
                end
            else
                forward(e, out)
            end
        elseif t == "splitter" then
            local d = TRACE_DV[e.direction]
            local px, py = -d[2] * 0.5, d[1] * 0.5   -- half a tile to each side
            for _, s in pairs({1, -1}) do
                local x, y = e.position.x + s * px + d[1], e.position.y + s * py + d[2]
                local n = ent_at(x, y)
                if n and accepts(n, e.direction) then table.insert(out, {n, "splitter"}) end
            end
        elseif t == "inserter" or t == "mining-drill" then
            local ok, dt = pcall(function() return e.drop_target end)
            if ok and dt then
                table.insert(out, {dt, t == "inserter" and "inserter drop" or "drill drop"})
            else
                local dp = e.drop_position
                local n = dp and ent_at(dp.x, dp.y)
                if n then
                    table.insert(out, {n, "drop"})
                else
                    table.insert(dead_ends, trace_desc(e) .. " drops on the ground")
                end
            end
        end
        -- inserters that pick up from e
        if t ~= "inserter" then
            local bb = e.bounding_box
            for _, ins in pairs(surface.find_entities_filtered{
                    area = {{bb.left_top.x - 3, bb.left_top.y - 3}, {bb.right_bottom.x + 3, bb.right_bottom.y + 3}},
                    type = "inserter"}) do
                local ok, pt = pcall(function() return ins.pickup_target end)
                if ok and pt == e then table.insert(out, {ins, "inserter pickup"}) end
            end
        end
        return out
    end

    local parent, how, order = {}, {}, {}
    local q, head = {src}, 1
    parent[key(src)] = false
    local found = false
    while head <= #q and #order < max_nodes do
        local e = q[head]; head = head + 1
        table.insert(order, e)
        if e == tgt then found = true break end
        for _, nx in pairs(nexts(e)) do
            local n = nx[1]
            if n.valid and parent[key(n)] == nil then
                parent[key(n)] = e
                how[key(n)] = nx[2]
                table.insert(q, n)
            end
        end
    end

    local path, tiles = {}, {}
    if found then
        local e0 = tgt
        while e0 do
            if BELTISH[e0.type] then table.insert(tiles, 1, {e0.position.x, e0.position.y, e0.name}) end
            e0 = parent[key(e0)]
        end
        local e = tgt
        while e do
            table.insert(path, 1, (how[key(e)] and (how[key(e)] .. " to ") or "") .. trace_desc(e))
            e = parent[key(e)]
        end
        -- compress long runs of plain belts
        local packed, run = {}, 0
        for i, s in ipairs(path) do
            if string.find(s, "^belt to transport%-belt") and i < #path then
                run = run + 1
            else
                if run > 0 then table.insert(packed, run .. " belts") run = 0 end
                table.insert(packed, s)
            end
        end
        path = packed
    end
    -- machines reached (not belts): useful when the target was not reached
    local reached = {}
    for _, e in ipairs(order) do
        if not BELTISH[e.type] and e.type ~= "inserter" and e ~= src then table.insert(reached, trace_desc(e)) end
    end
    local items = {}
    for _, e in ipairs(order) do
        if BELTISH[e.type] then
            for i = 1, e.get_max_transport_line_index() do
                for _, it in pairs(e.get_transport_line(i).get_contents()) do
                    items[it.name] = (items[it.name] or 0) + it.count
                end
            end
        end
    end
    local seen_dead = {}
    local dead = {}
    for _, d in ipairs(dead_ends) do
        if not seen_dead[d] then seen_dead[d] = true table.insert(dead, d) end
    end
    -- JSON as hex: FLE's Lua->Python response parser mangles nested string tables
    local result = {connected = found, path = path, tiles = tiles, dead_ends = dead, reached = reached,
                    visited = #order, items_on_belts = items,
                    source = trace_desc(src), target = trace_desc(tgt)}
    local json = helpers.table_to_json(result)
    return "TRACEHEX_" .. (json:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end
