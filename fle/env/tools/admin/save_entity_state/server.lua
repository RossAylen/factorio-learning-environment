-- Helper to ensure all numbers are serializable
local function serialize_number(num)
    if num == math.huge then
        return "inf"
    elseif num == -math.huge then
        return "-inf"
    else
        return tostring(num)
    end
end

-- Helper to serialize position to fixed format
local function serialize_position(pos)
    return {
        x = serialize_number(pos.x),
        y = serialize_number(pos.y)
    }
end


-- extras the per-entity state does not carry (rail state and circuits): train stops (name, limit,
-- priority), rolling stock (train, place in the consist, orientation, fuel, cargo, fluid; schedule,
-- interrupts, group and mode on the front carriage), circuit/copper wires and control behaviour.
-- Returned as one pseudo-entity {name = "__extras__", data = {[unit] = {...}}}.
local SES_ROLL = {locomotive = true, ["cargo-wagon"] = true, ["fluid-wagon"] = true, ["artillery-wagon"] = true}
local SES_CB_FIELDS = {"circuit_enable_disable", "circuit_condition", "connect_to_logistic_network", "logistic_condition",
    "read_contents", "read_contents_mode", "set_trains_limit", "trains_limit_signal", "send_to_train", "read_from_train",
    "read_stopped_train", "stopped_train_signal", "read_trains_count", "trains_count_signal", "enable_disable",
    "circuit_read_hand_contents", "circuit_hand_read_mode", "circuit_set_stack_size", "stack_control_input_signal",
    "read_charge", "output_signal", "circuit_set_filters", "use_colors", "red_output_signal", "orange_output_signal",
    "green_output_signal", "close_signal", "read_signal", "resource_read_mode", "circuit_read_resources"}
local function ses_contents(inv)
    if not inv then return nil end
    local out = {}
    for _, it in pairs(inv.get_contents()) do out[#out + 1] = {name = it.name, count = it.count, quality = it.quality} end
    return #out > 0 and out or nil
end
local function ses_extras(entities)
    local ex = {}
    for _, e in pairs(entities) do
        if e.valid and e.unit_number and e.type ~= "character" then
            local r = {}
            local t = e.type
            if t == "train-stop" then
                local lim = e.trains_limit
                if lim and lim >= 4294967295 then lim = nil end
                r.stop = {name = e.backer_name, limit = lim, prio = e.train_stop_priority}
            end
            if SES_ROLL[t] and e.train then
                local tr = e.train
                local idx = 0
                for i, c in ipairs(tr.carriages) do if c == e then idx = i end end
                local ro = {train = tr.id, idx = idx, n = #tr.carriages, o = e.orientation, name = e.name,
                            x = e.position.x, y = e.position.y}
                pcall(function() ro.fuel = ses_contents(e.get_fuel_inventory()) end)
                if t == "cargo-wagon" then pcall(function() ro.cargo = ses_contents(e.get_inventory(defines.inventory.cargo_wagon)) end) end
                pcall(function() ro.fluid = e.get_fluid_contents() end)
                if idx == 1 then
                    pcall(function()
                        local sch = tr.get_schedule()
                        ro.records = sch.get_records()
                        ro.interrupts = sch.get_interrupts()
                        ro.current = sch.current
                    end)
                    ro.group = tr.group
                    ro.manual = tr.manual_mode
                end
                r.roll = ro
            end
            local ok, cons = pcall(function() return e.get_wire_connectors(false) end)
            if ok and cons then
                for cid, conn in pairs(cons) do
                    for _, w in pairs(conn.connections) do
                        local o = w.target.owner
                        if o and o.valid and o.unit_number then
                            r.w = r.w or {}
                            r.w[#r.w + 1] = {c = cid, u = o.unit_number, tc = w.target.wire_connector_id}
                        end
                    end
                end
            end
            local cb = nil
            pcall(function() cb = e.get_control_behavior() end)
            if cb then
                local c = {}
                if t == "arithmetic-combinator" or t == "decider-combinator" or t == "selector-combinator" then
                    pcall(function() c.parameters = cb.parameters end)
                elseif t == "constant-combinator" then
                    pcall(function()
                        c.enabled = cb.enabled
                        c.sections = {}
                        for i = 1, cb.sections_count do
                            local sec = cb.get_section(i)
                            c.sections[#c.sections + 1] = {filters = sec.filters, active = sec.active}
                        end
                    end)
                end
                for _, f in ipairs(SES_CB_FIELDS) do
                    pcall(function() local v = cb[f] if v ~= nil then c.f = c.f or {} c.f[f] = v end end)
                end
                if next(c) then r.cb = c end
            end
            if next(r) then ex[tostring(e.unit_number)] = r end
        end
    end
    return ex
end

-- Main serialization function
storage.actions.save_entity_state = function(player_index, distance, player_entities, resource_entities, items_on_ground, only)
    local surface = storage.agent_characters[player_index].surface
    local entities
    if only then
        entities = only
        items_on_ground = false
    elseif player_entities then
        entities = surface.find_entities_filtered({area={{-distance, -distance}, {distance, distance}}, force=storage.agent_characters[player_index].force})
    else
        if resource_entities then
            entities = surface.find_entities({{-distance, -distance}, {distance, distance}})
        else
            entities = surface.find_entities_filtered({area={{-distance, -distance}, {distance, distance}}, force=storage.agent_characters[player_index].force})
        end
    end

    -- Always get items on ground if requested
    if items_on_ground then
        local ground_items = surface.find_entities_filtered({
            area = {{-distance, -distance}, {distance, distance}},
            name = "item-on-ground"
        })
        -- Merge the arrays
        for _, item in pairs(ground_items) do
            table.insert(entities, item)
        end
    end

    local entity_states = {}
    local entity_array = {}
    for _, entity in pairs(entities) do

        -- Serialize inventories by type (Factorio 2.0: unified crafter_* defines)
        local inventory_defines = {
            chest = defines.inventory.chest,
            crafter_input = defines.inventory.crafter_input,      -- was furnace_source/assembling_machine_input
            crafter_output = defines.inventory.crafter_output,    -- was furnace_result/assembling_machine_output
            fuel = defines.inventory.fuel,
            burnt_result = defines.inventory.burnt_result,
            turret_ammo = defines.inventory.turret_ammo,
            lab_input = defines.inventory.lab_input,
            lab_modules = defines.inventory.lab_modules,
            crafter_modules = defines.inventory.crafter_modules   -- was assembling_machine_modules
        }

        if entity.name == "item-on-ground" then
            -- Capture the item details
            local item = entity.stack
            if item and item.valid then
                local state = {
                    name = '\"item-on-ground\"',
                    type = '"' .. item.name .. '"',
                    count = serialize_number(item.count),
                    position = serialize_position(entity.position),
                }
                table.insert(entity_array, state)
            end
        elseif entity.name ~= "character" then
            local state = {
                name = '"' .. entity.name .. '"',
                position = serialize_position(entity.position),
                direction = entity.direction,
                entity_number = entity.unit_number or -1,
                type = '"' .. entity.type .. '"',
                health = serialize_number(entity.health),
                energy = serialize_number(entity.energy or 0),
                active = entity.active,
                status = storage.utils.entity_status_names(entity.status),
                warnings = {},
                inventories = {}
            }
            -- underground belts / loaders: input or output end (create_entity needs it back)
            if entity.type == "underground-belt" then
                state.belt_to_ground_type = '"' .. entity.belt_to_ground_type .. '"'
            elseif entity.type == "loader" or entity.type == "loader-1x1" then
                state.belt_to_ground_type = '"' .. entity.loader_type .. '"'
            end

            -- Add any warnings
            for _, warning in pairs(storage.utils.get_issues(entity) or {}) do
                table.insert(state.warnings, '"' .. warning .. '"')
            end

            -- Handle dimensions
            local prototype = prototypes.entity[entity.name]
            if prototype then
                local collision_box = prototype.collision_box
                state.dimensions = {
                    width = serialize_number(math.abs(collision_box.right_bottom.x - collision_box.left_top.x)),
                    height = serialize_number(math.abs(collision_box.right_bottom.y - collision_box.left_top.y))
                }
                state.tile_dimensions = {
                    tile_width = serialize_number(prototype.tile_width),
                    tile_height = serialize_number(prototype.tile_height)
                }
            end

            for name, define in pairs(inventory_defines) do
                local inventory = entity.get_inventory(define)
                if inventory then
                    state.inventories[name] = {}
                    -- Get contents with proper item names
                    local contents = storage.utils.get_contents_compat(inventory)
                    for item_name, count in pairs(contents) do
                        if item_name and item_name ~= "" then  -- Ensure valid item name
                            state.inventories[name][tostring(item_name)] = serialize_number(count)
                        end
                    end
                end
            end

            -- Handle fluids
            if storage.fb(entity) then
                state.fluid_box = {}
                for i = 1, #storage.fb(entity) do
                    local fluid = storage.fb(entity)[i]
                    if fluid then
                        table.insert(state.fluid_box, {
                            name = '"' .. fluid.name .. '"',
                            amount = serialize_number(fluid.amount),
                            temperature = serialize_number(fluid.temperature)
                        })
                    end
                end
            end

            -- Handle burner state
            if entity.burner then
                -- Factorio 2.0: currently_burning may be a LuaItemPrototype userdata
                local burning_name = nil
                if entity.burner.currently_burning then
                    -- Try to get the name safely (could be userdata or table)
                    local ok, name = pcall(function()
                        return entity.burner.currently_burning.name
                    end)
                    if ok and name then
                        burning_name = '"' .. tostring(name) .. '"'
                    end
                end
                state.burner = {
                    currently_burning = burning_name,
                    remaining_burning_fuel = serialize_number(entity.burner.remaining_burning_fuel or 0),
                    heat = serialize_number(entity.burner.heat or 0)
                }

                -- Add burner inventory with proper item names
                local burner_inventory = entity.burner.inventory
                if burner_inventory then
                    state.burner.inventory = {}
                    local contents = storage.utils.get_contents_compat(burner_inventory)
                    --game.print("get_contents() results:")
                    for item_name, count in pairs(contents) do
                        if item_name and item_name ~= "" then  -- Ensure valid item name
                            --game.print("Item: '" .. tostring(item_name) .. "' Count: " .. tostring(count))
                            --state.burner.inventory['\"' .. tostring(item_name) .. '\"'] = serialize_number(count)
                            state.burner.inventory[tostring(item_name)] = serialize_number(count)
                        end
                    end
                end
            end

            -- Handle recipe - only for crafting machines and furnaces
            if (entity.type == "assembling-machine" or
                    entity.type == "furnace" or
                    entity.type == "rocket-silo") and
                    entity.get_recipe then
                local recipe = entity.get_recipe()
                if recipe then
                    state.recipe = storage.utils.serialize_recipe(recipe)
                end
            end

            -- Handle specific entity types
            --if entity.type == "transport-belt" then
            --    state.input_position = serialize_position(entity.position)
            --    state.output_position = serialize_position(entity.position)
            --    -- Add belt contents
            --    state.inventory = {}
            --    for name, count in pairs(entity.get_transport_line(1).get_contents()) do
            --        state.inventory[tostring(name)] = serialize_number(count)
            --    end
            if entity.type == "transport-belt" then
                --state.input_position = serialize_position(entity.input_position)
                --state.output_position = serialize_position(entity.output_position)
                state.position = serialize_position(entity.position)

                -- Store contents of each transport line separately
                state.transport_lines = {}

                -- Front line (line 1)
                state.transport_lines[1] = {}
                local contents1 = storage.utils.get_contents_compat(entity.get_transport_line(1))
                for name, count in pairs(contents1) do
                    state.transport_lines[1][tostring(name)] = serialize_number(count)
                end

                -- Back line (line 2)
                state.transport_lines[2] = {}
                local contents2 = storage.utils.get_contents_compat(entity.get_transport_line(2))
                for name, count in pairs(contents2) do
                    state.transport_lines[2][tostring(name)] = serialize_number(count)
                end

                -- Total counts (for backwards compatibility)
                state.inventory = {}
                for name, count in pairs(contents1) do
                    state.inventory[tostring(name)] = serialize_number(count)
                end
                for name, count in pairs(contents2) do
                    local existing = state.inventory[tostring(name)]
                    if existing then
                        state.inventory[tostring(name)] = serialize_number(tonumber(existing) + count)
                    else
                        state.inventory[tostring(name)] = serialize_number(count)
                    end
                end

            elseif entity.type == "inserter" then
                state.pickup_position = serialize_position(entity.pickup_position)
                state.drop_position = serialize_position(entity.drop_position)

            elseif entity.type == "splitter" then
                -- Calculate splitter positions based on orientation
                local x, y = entity.position.x, entity.position.y
                state.input_positions = {}
                state.output_positions = {}
                local lateral_offset = 0.5

                if entity.direction == defines.direction.north then
                    state.input_positions = {
                        serialize_position({x = x - lateral_offset, y = y + 1}),
                        serialize_position({x = x + lateral_offset, y = y + 1})
                    }
                    state.output_positions = {
                        serialize_position({x = x - lateral_offset, y = y - 1}),
                        serialize_position({x = x + lateral_offset, y = y - 1})
                    }
                elseif entity.direction == defines.direction.south then
                    state.input_positions = {
                        serialize_position({x = x + lateral_offset, y = y - 1}),
                        serialize_position({x = x - lateral_offset, y = y - 1})
                    }
                    state.output_positions = {
                        serialize_position({x = x + lateral_offset, y = y + 1}),
                        serialize_position({x = x - lateral_offset, y = y + 1})
                    }
                elseif entity.direction == defines.direction.east then
                    state.input_positions = {
                        serialize_position({x = x - 1, y = y - lateral_offset}),
                        serialize_position({x = x - 1, y = y + lateral_offset})
                    }
                    state.output_positions = {
                        serialize_position({x = x + 1, y = y - lateral_offset}),
                        serialize_position({x = x + 1, y = y + lateral_offset})
                    }
                elseif entity.direction == defines.direction.west then
                    state.input_positions = {
                        serialize_position({x = x + 1, y = y + lateral_offset}),
                        serialize_position({x = x + 1, y = y - lateral_offset})
                    }
                    state.output_positions = {
                        serialize_position({x = x - 1, y = y + lateral_offset}),
                        serialize_position({x = x - 1, y = y - lateral_offset})
                    }
                end

                -- Serialize splitter inventories
                state.inventory = {}
                for i = 1, 2 do
                    state.inventory[i] = {}
                    -- Factorio 2.0: Use compat wrapper for get_contents()
                    local contents = storage.utils.get_contents_compat(entity.get_transport_line(i))
                    for name, count in pairs(contents) do
                        state.inventory[i][tostring(name)] = serialize_number(count)
                    end
                end

            elseif entity.type == "mining-drill" then
                state.drop_position = serialize_position(entity.drop_position)

            elseif entity.type == "boiler" then
                -- Add connection points
                local x, y = entity.position.x, entity.position.y
                if entity.direction == defines.direction.north then
                    state.connection_points = {
                        serialize_position({x = x - 2, y = y + 0.5}),
                        serialize_position({x = x + 2, y = y + 0.5})
                    }
                    state.steam_output_point = serialize_position({x = x, y = y - 2})
                elseif entity.direction == defines.direction.south then
                    state.connection_points = {
                        serialize_position({x = x - 2, y = y - 0.5}),
                        serialize_position({x = x + 2, y = y - 0.5})
                    }
                    state.steam_output_point = serialize_position({x = x, y = y + 2})
                elseif entity.direction == defines.direction.east then
                    state.connection_points = {
                        serialize_position({x = x - 0.5, y = y - 2}),
                        serialize_position({x = x - 0.5, y = y + 2})
                    }
                    state.steam_output_point = serialize_position({x = x + 2, y = y})
                elseif entity.direction == defines.direction.west then
                    state.connection_points = {
                        serialize_position({x = x + 0.5, y = y - 2}),
                        serialize_position({x = x + 0.5, y = y + 2})
                    }
                    state.steam_output_point = serialize_position({x = x - 2, y = y})
                end
            end

            table.insert(entity_array, state)
        else
            -- Find the index of this character in storage.agent_characters
            agent_index = -1
            for idx, agent in pairs(storage.agent_characters) do
                if agent == entity then
                    agent_index = idx
                    break
                end
            end
            local state = {
                name = '"' .. entity.name .. '"',
                position = serialize_position(entity.position),
                direction = entity.direction,
                entity_number = entity.unit_number or -1,
                inventories = {},
                agent_index = agent_index,
                color = {
                    r = serialize_number(entity.color.r),
                    g = serialize_number(entity.color.g),
                    b = serialize_number(entity.color.b),
                    a = serialize_number(entity.color.a)
                }
            }
            -- Get the character's inventory using defines
            local inventory = entity.get_inventory(defines.inventory.character_main)

            if inventory then
                state.inventory = {}
                -- Factorio 2.0: Use compat wrapper for get_contents()
                local contents = storage.utils.get_contents_compat(inventory)
                for item_name, count in pairs(contents) do
                    if item_name and item_name ~= "" then
                        state.inventory[tostring(item_name)] = serialize_number(count)
                    end
                end
            end
            table.insert(entity_array, state)
        end
    end
    local okx, ex = pcall(ses_extras, entities)
    if okx and ex and next(ex) then
        -- hex JSON: the generic Lua->Python parser mangles strings with spaces ('Iron Load') and lists
        local j = helpers.table_to_json(ex)
        table.insert(entity_array, {name = '"__extras__"', type = '"__extras__"',
                                    data = "EXHEX_" .. (j:gsub(".", function(ch) return string.format("%02x", ch:byte()) end))})
    end
    return entity_array
end


-- Chunked snapshot: a whole-map save serialised every entity inside ONE tick (8.6 s on the live
-- base). begin -> the entity list goes to storage, an on_tick handler serialises SES_BATCH entities
-- per tick, poll pages the result out.
local SES_BATCH = 200
storage.actions.save_entity_state_begin = function(player_index, distance, player_entities, resource_entities, items_on_ground)
    local c = storage.agent_characters[player_index]
    local surface = c.surface
    local area = {{-distance, -distance}, {distance, distance}}
    local ents
    if resource_entities and not player_entities then
        ents = surface.find_entities(area)
    else
        ents = surface.find_entities_filtered{area = area, force = c.force}
    end
    if items_on_ground then
        for _, it in pairs(surface.find_entities_filtered{area = area, name = "item-on-ground"}) do table.insert(ents, it) end
    end
    storage.ses_job = {pi = player_index, d = distance, pe = player_entities, re = resource_entities,
                       ents = ents, i = 1, out = {}, done = false, ground = items_on_ground}
    return {total = #ents}
end

script.on_event(defines.events.on_tick, function(ev)
    local j = storage.ses_job
    if not j or j.done then return end
    local slice = {}
    local n = 0
    while j.i <= #j.ents and n < SES_BATCH do
        local e = j.ents[j.i]
        j.i = j.i + 1
        if e and e.valid then slice[#slice + 1] = e n = n + 1 end
    end
    if #slice > 0 then
        local ok, part = pcall(storage.actions.save_entity_state, j.pi, j.d, j.pe, j.re, false, slice)
        if ok and part then
            for _, st in ipairs(part) do j.out[#j.out + 1] = st end
        end
    end
    if j.i > #j.ents then j.done = true j.ents = nil end
end)

-- page through the result: {done, total, n, items (page of up to `size`)}
storage.actions.save_entity_state_poll = function(player_index, page, size)
    local j = storage.ses_job
    if not j then return {done = true, n = 0, items = {}} end
    if not j.done or tonumber(page) == -1 then return {done = j.done, n = #j.out, items = {}} end
    page, size = tonumber(page) or 0, tonumber(size) or 500
    local items = {}
    for k = page * size + 1, math.min(#j.out, (page + 1) * size) do items[#items + 1] = j.out[k] end
    local last = (page + 1) * size >= #j.out
    if last then storage.ses_job = nil end
    return {done = true, n = #j.out, items = items, last = last}
end
