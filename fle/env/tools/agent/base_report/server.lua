-- base_report: what a player sees in the production / power / alert screens and on the map,
-- around a list of named points. Read only.
-- points (hex JSON): [{"name": "iron_a", "x": .., "y": .., "r": ..}, ...]
storage.actions.base_report = function(player_index, points_hex, items_hex)
    local player = storage.agent_characters[player_index]
    local surface = player.surface
    local force = player.force
    local function unhex(h) return (h:gsub("%x%x", function(c) return string.char(tonumber(c, 16)) end)) end
    local points = helpers.json_to_table(unhex(points_hex)) or {}
    local items = helpers.json_to_table(unhex(items_hex)) or {}
    local st = {}
    for k, v in pairs(defines.entity_status) do st[v] = k end
    local SKIP = {["transport-belt"] = true, ["underground-belt"] = true, ["splitter"] = true,
                  ["pipe"] = true, ["pipe-to-ground"] = true, ["electric-pole"] = true}
    local out = {sites = {}, production = {}, power = {}, threat = {}, tick = game.tick}

    for _, p in ipairs(points) do
        local r = p.r or 20
        local site = {name = p.name, statuses = {}, enemies = 0, pollution = 0, damaged = 0,
                      turrets = 0, turrets_low_ammo = 0, turrets_ammo = 0, chests = {}}
        for _, e in pairs(surface.find_entities_filtered{position = {p.x, p.y}, radius = r, force = force}) do
            if e.valid and not SKIP[e.type] and e.type ~= "character" then
                local s = e.status and st[e.status] or "none"
                local k = e.type .. ":" .. s
                site.statuses[k] = (site.statuses[k] or 0) + 1
            end
            if e.valid and e.health then
                local mh = nil
                pcall(function() mh = e.max_health end)
                if mh and e.health < mh - 0.01 then site.damaged = site.damaged + 1 end
            end
            if e.valid and e.type == "ammo-turret" then
                site.turrets = site.turrets + 1
                local inv = e.get_inventory(defines.inventory.turret_ammo)
                local n = inv and inv.get_item_count() or 0
                site.turrets_ammo = site.turrets_ammo + n
                if n < 5 then site.turrets_low_ammo = site.turrets_low_ammo + 1 end
            end
            if e.valid and e.type == "container" then
                local inv = e.get_inventory(defines.inventory.chest)
                if inv then
                    for _, it in pairs(inv.get_contents()) do
                        site.chests[it.name] = (site.chests[it.name] or 0) + it.count
                    end
                end
            end
        end
        site.enemies = #surface.find_entities_filtered{position = {p.x, p.y}, radius = r + 30, force = "enemy", type = "unit"}
        site.pollution = math.floor(surface.get_pollution({p.x, p.y}))
        table.insert(out.sites, site)
    end

    -- production / consumption per minute (the production screen)
    local stats = force.get_item_production_statistics(surface)
    for _, name in ipairs(items) do
        local ok1, made = pcall(function() return stats.get_flow_count{name = name, category = "input",
            precision_index = defines.flow_precision_index.one_minute, count = false} end)
        local ok2, used = pcall(function() return stats.get_flow_count{name = name, category = "output",
            precision_index = defines.flow_precision_index.one_minute, count = false} end)
        out.production[name] = {made_per_min = ok1 and made or -1, used_per_min = ok2 and used or -1}
    end

    -- power (the electric network screen of any pole)
    local pole = surface.find_entities_filtered{type = "electric-pole", force = force, limit = 1}[1]
    if pole then
        local ok, ns = pcall(function() return pole.electric_network_statistics end)
        local gen, use = 0, 0
        if ok and ns then
            for name, _ in pairs(ns.input_counts) do
                gen = gen + ns.get_flow_count{name = name, category = "input",
                    precision_index = defines.flow_precision_index.one_minute, count = false}
            end
            for name, _ in pairs(ns.output_counts) do
                use = use + ns.get_flow_count{name = name, category = "output",
                    precision_index = defines.flow_precision_index.one_minute, count = false}
            end
        end
        out.power.generated_mw = gen * 60 / 1e6
        out.power.consumed_mw = use * 60 / 1e6
    end
    local eng = {}
    for _, e in pairs(surface.find_entities_filtered{type = "generator", force = force}) do
        local s = e.status and st[e.status] or "none"
        eng[s] = (eng[s] or 0) + 1
    end
    out.power.engines = eng

    -- threat (alerts + map)
    out.threat.evolution = force and game.forces.enemy.get_evolution_factor(surface) or 0
    local cx, cy = 0, 0
    if #points > 0 then
        for _, p in ipairs(points) do cx = cx + p.x cy = cy + p.y end
        cx, cy = cx / #points, cy / #points
    end
    out.threat.nests_within_150 = #surface.find_entities_filtered{position = {cx, cy}, radius = 150,
        force = "enemy", type = "unit-spawner"}
    out.threat.units_within_150 = #surface.find_entities_filtered{position = {cx, cy}, radius = 150,
        force = "enemy", type = "unit"}
    local j = helpers.table_to_json(out)
    return "BASEHEX_" .. (j:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end
