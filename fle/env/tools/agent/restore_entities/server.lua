-- restore_entities: re-place entities from a plan (e.g. a base snapshot) that are missing,
-- using items from the character's inventory, exactly like place_entity would.
-- plan entries (hex JSON list): {n=name, x, y, d=direction, t=input/output, r=recipe,
--   sf/sp/si = splitter filter / output / input priority, f = inserter filters (fm = whitelist/blacklist)}
storage.actions.restore_entities = function(player_index, plan_hex, dry_run)
    local player = storage.agent_characters[player_index]
    local surface = player.surface
    local json = plan_hex:gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end)
    local plan = helpers.json_to_table(json) or {}
    local placed, present, blocked, short = 0, 0, 0, {}
    local last = player.position
    for _, p in ipairs(plan) do
        local proto = prototypes.entity[p.n]
        if proto then
            local here = surface.find_entities_filtered{position = {p.x, p.y}, name = p.n, force = player.force}
            if #here > 0 then
                present = present + 1
            else
                local item = proto.items_to_place_this and proto.items_to_place_this[1]
                local iname = item and (item.name or item)
                if not iname then
                    blocked = blocked + 1
                elseif player.get_item_count(iname) < 1 then
                    short[iname] = (short[iname] or 0) + 1
                elseif not dry_run then
                    local spec = {name = p.n, position = {p.x, p.y}, direction = p.d or 0, force = player.force,
                                  move_stuck_players = true}
                    if p.t then spec.type = p.t end
                    -- clear trees/rocks that grew in? (rare) and items on the ground
                    for _, o in pairs(surface.find_entities_filtered{position = {p.x, p.y}, radius = 0.7,
                                                                       type = {"item-entity", "corpse"}}) do
                        if o.valid and o.type == "item-entity" then o.destroy() end
                    end
                    if surface.can_place_entity{name = p.n, position = {p.x, p.y}, direction = p.d or 0,
                                                force = player.force} then
                        local e = surface.create_entity(spec)
                        if e then
                            player.remove_item({name = iname, count = 1})
                            if p.r and e.type == "assembling-machine" then pcall(function() e.set_recipe(p.r) end) end
                            if e.type == "splitter" then
                                pcall(function()
                                    if p.sf then if not pcall(function() e.splitter_filter = {name = p.sf} end) then e.splitter_filter = p.sf end end
                                    if p.sp then e.splitter_output_priority = p.sp end
                                    if p.si then e.splitter_input_priority = p.si end
                                end)
                            end
                            if p.f and e.type == "inserter" then
                                pcall(function()
                                    e.use_filters = true
                                    if p.fm then e.inserter_filter_mode = p.fm end
                                    for i, nm in ipairs(p.f) do if i <= e.filter_slot_count then e.set_filter(i, nm) end end
                                end)
                            end
                            placed = placed + 1
                            storage.elapsed_ticks = storage.elapsed_ticks +
                                storage.utils.calculate_movement_ticks(player, last, {x = p.x, y = p.y})
                            last = {x = p.x, y = p.y}
                        else
                            blocked = blocked + 1
                        end
                    else
                        blocked = blocked + 1
                    end
                end
            end
        end
    end
    local short_list = {}
    for k, v in pairs(short) do table.insert(short_list, {item = k, count = v}) end
    local out = {placed = placed, present = present, blocked = blocked, short = short_list}
    local j = helpers.table_to_json(out)
    return "RESTOREHEX_" .. (j:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end
