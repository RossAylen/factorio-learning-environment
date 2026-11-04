-- auto_research: the labs never run out of research. Keeps the game's research queue at >= 3
-- entries: first from storage.research_priority (the planner's list), then techs whose every
-- pack the factory produced in the last 10 minutes, cheapest first (ties by name). Runs when
-- research finishes and every 600 ticks. Deterministic; registered through the scenario
-- dispatchers so a joining client runs the same code.
local AR_MIN, AR_MAX = 3, 7

local function ar_startable(tech, queued)
    if not (tech and tech.valid) or tech.researched or not tech.enabled then return false end
    local trig = nil
    pcall(function() trig = tech.prototype.research_trigger end)
    if trig then return false end
    local inf = false
    pcall(function() inf = tech.prototype.research_unit_count_formula ~= nil end)
    if inf then return false end
    for _, pre in pairs(tech.prerequisites or {}) do
        if not pre.researched and not queued[pre.name] then return false end
    end
    return true
end

local function ar_refill()
    local force = game.forces.player
    if not force then return {} end
    local q, queued = {}, {}
    for _, t in pairs(force.research_queue or {}) do
        table.insert(q, t.name) queued[t.name] = true
    end
    if #q >= AR_MIN then return q end
    for _, name in ipairs(storage.research_priority or {}) do
        if #q >= AR_MAX then break end
        local tech = force.technologies[name]
        if not queued[name] and ar_startable(tech, queued) then
            table.insert(q, name) queued[name] = true
        end
    end
    if #q < AR_MIN then
        local stats = force.get_item_production_statistics(game.surfaces[1])
        local made = {}
        local function produced(pack)
            if made[pack] == nil then
                local ok, n = pcall(function() return stats.get_flow_count{name = pack, category = "input",
                    precision_index = defines.flow_precision_index.ten_minutes, count = true} end)
                made[pack] = ok and (n or 0) > 0
            end
            return made[pack]
        end
        local cands = {}
        for name, tech in pairs(force.technologies) do
            if not queued[name] and ar_startable(tech, queued) then
                local ok_all, cost = true, 0
                for _, ing in pairs(tech.research_unit_ingredients) do
                    if not produced(ing.name) then ok_all = false break end
                    cost = cost + ing.amount
                end
                if ok_all and #tech.research_unit_ingredients > 0 then
                    table.insert(cands, {name = name, cost = cost * tech.research_unit_count})
                end
            end
        end
        table.sort(cands, function(a, b) if a.cost ~= b.cost then return a.cost < b.cost end return a.name < b.name end)
        for _, c in ipairs(cands) do
            if #q >= AR_MIN then break end
            table.insert(q, c.name) queued[c.name] = true
        end
    end
    pcall(function() force.research_queue = q end)
    storage.research_auto_last = {tick = game.tick, queue = q}
    return q
end

script.on_event(defines.events.on_research_finished, function(ev) ar_refill() end)
script.on_nth_tick(60, function(ev) if ev.tick % 600 == 0 then ar_refill() end end)

-- the planner's list; refills at once. Returns {queue, current}
storage.actions.auto_research = function(player_index, names_hex)
    local function unhex(h) return (h:gsub("%x%x", function(c) return string.char(tonumber(c, 16)) end)) end
    if names_hex and names_hex ~= "" then
        storage.research_priority = helpers.json_to_table(unhex(names_hex)) or {}
    end
    local q = ar_refill()
    local cr = game.forces.player.current_research
    local j = helpers.table_to_json({queue = q, current = cr and cr.name or "", priority = #(storage.research_priority or {})})
    return "ARHEX_" .. (j:gsub(".", function(ch) return string.format("%02x", ch:byte()) end))
end
