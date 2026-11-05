-- Helper function to unquote strings
local function unquote_string(str)
    if not str then return nil end
    return string.gsub(str, '"', '')
end

local LES_ROLL = {locomotive = true, ["cargo-wagon"] = true, ["fluid-wagon"] = true, ["artillery-wagon"] = true}

-- rail state and circuits (see save_entity_state's ses_extras)
local function les_apply_extras(surface, parts, created)
    local ex = {}
    for _, p in ipairs(parts) do for k, v in pairs(p) do ex[tostring(k)] = v end end
    local new_of = {}
    for k, v in pairs(created) do new_of[tostring(k)] = v.entity end
    local report = {stops = 0, carriages = 0, trains = 0, wires = 0, cb = 0, failed = {}}
    -- 1. train stops
    for k, r in pairs(ex) do
        local e = new_of[k]
        if r.stop and e and e.valid then
            pcall(function() e.backer_name = r.stop.name end)
            pcall(function() if r.stop.limit then e.trains_limit = r.stop.limit end end)
            pcall(function() if r.stop.prio then e.train_stop_priority = r.stop.prio end end)
            report.stops = report.stops + 1
        end
    end
    -- 2. rolling stock: per train, front to back, so the consist couples again
    local trains = {}
    for k, r in pairs(ex) do
        if r.roll then
            local id = tostring(r.roll.train)
            trains[id] = trains[id] or {}
            table.insert(trains[id], {k = k, r = r.roll})
        end
    end
    local function put(inv, list)
        if inv and list then for _, it in ipairs(list) do pcall(function() inv.insert{name = it.name, count = it.count, quality = it.quality} end) end end
    end
    for _, cars in pairs(trains) do
        table.sort(cars, function(a, b) return a.r.idx < b.r.idx end)
        local last = nil
        for _, c in ipairs(cars) do
            local ro = c.r
            local d = math.floor((tonumber(ro.o) or 0) * 16 + 0.5) % 16
            local e = surface.create_entity{name = ro.name, position = {ro.x, ro.y}, direction = d, force = game.forces.player, raise_built = true}
            if e then
                new_of[c.k] = e
                last = e
                report.carriages = report.carriages + 1
                pcall(function() put(e.get_fuel_inventory(), ro.fuel) end)
                if e.type == "cargo-wagon" then pcall(function() put(e.get_inventory(defines.inventory.cargo_wagon), ro.cargo) end) end
                pcall(function() for fname, amt in pairs(ro.fluid or {}) do e.insert_fluid{name = fname, amount = amt} end end)
            else
                report.failed[#report.failed + 1] = ro.name .. "@" .. ro.x .. "," .. ro.y
            end
        end
        local front = cars[1] and cars[1].r
        if last and last.valid and last.train and front then
            local tr = last.train
            pcall(function()
                local sch = tr.get_schedule()
                if front.records then sch.set_records(front.records) end
                if front.interrupts then sch.set_interrupts(front.interrupts) end
                if front.current and front.current > 0 then sch.go_to_station(front.current) end
            end)
            pcall(function() if front.group and front.group ~= "" then tr.group = front.group end end)
            pcall(function() tr.manual_mode = front.manual and true or false end)
            report.trains = report.trains + 1
        end
    end
    -- 3. wires and 4. control behaviour (needs every entity, rolling stock included)
    for k, r in pairs(ex) do
        local e = new_of[k]
        if e and e.valid then
            for _, w in ipairs(r.w or {}) do
                local o = new_of[tostring(w.u)]
                if o and o.valid then
                    pcall(function()
                        if e.get_wire_connector(w.c, true).connect_to(o.get_wire_connector(w.tc, true), false) then
                            report.wires = report.wires + 1
                        end
                    end)
                end
            end
            if r.cb then
                pcall(function()
                    local cb = e.get_or_create_control_behavior()
                    if r.cb.parameters then cb.parameters = r.cb.parameters end
                    if r.cb.sections then
                        for i, sec in ipairs(r.cb.sections) do
                            local s_ = cb.get_section(i) or cb.add_section()
                            if s_ then
                                pcall(function() s_.filters = sec.filters end)
                                pcall(function() if sec.active ~= nil then s_.active = sec.active end end)
                            end
                        end
                    end
                    if r.cb.enabled ~= nil then pcall(function() cb.enabled = r.cb.enabled end) end
                    for f, v in pairs(r.cb.f or {}) do pcall(function() cb[f] = v end) end
                    report.cb = report.cb + 1
                end)
            end
        end
    end
    storage.last_load_extras = report
    return report
end

-- Main deserialization function
storage.actions.load_entity_state = function(player, stored_json_data)
    local player_entity = storage.agent_characters[player]
    local surface = player_entity.surface
    local created_entities = {}
    local stored_data = helpers.json_to_table(stored_json_data)
    local character_states = {}
    local extras_parts = {}
    -- First pass: Create all non-character entities and store character states
    for _, state in pairs(stored_data) do
        local name = unquote_string(state.name)

        if name == "character" then
            table.insert(character_states, state)
        elseif name == "item-on-ground" then
            local item_name = unquote_string(state.type)
            local item_count = tonumber(state.count)

            if prototypes.item[item_name] then
                local entity = surface.create_entity({
                    name = name,
                    position = {
                        x = tonumber(state.position.x),
                        y = tonumber(state.position.y)
                    },
                    stack = {
                        name = item_name,
                        count = item_count
                    },
                    force = game.forces.player
                })
            else
                -- game.print("Warning: Unknown item type " .. item_name)
            end
        elseif name == "__extras__" then
            local d = state.data
            if type(d) == "string" and string.sub(d, 1, 6) == "EXHEX_" then
                local h = string.sub(d, 7)
                d = helpers.json_to_table((h:gsub("%x%x", function(c) return string.char(tonumber(c, 16)) end)))
            end
            if type(d) == "table" then extras_parts[#extras_parts + 1] = d end
        elseif LES_ROLL[unquote_string(state.type or "")] then
            -- rolling stock is placed after the rails, from the extras (orientation + consist order)
        elseif state.type == "simple-entity-with-owner" then
            -- Do nothing, we don't want to load in placeholder entities if they were somehow persisted!
        else
            local spec = {
                name = name,
                position = {
                    x = tonumber(state.position.x),
                    y = tonumber(state.position.y)
                },
                direction = tonumber(state.direction),
                force = game.forces.player,
                raise_built = true
            }
            if state.belt_to_ground_type then
                spec.type = unquote_string(state.belt_to_ground_type)
            end
            local entity = surface.create_entity(spec)

            if entity then
                created_entities[state.entity_number] = {
                    entity = entity,
                    state = state
                }
            end
        end
    end

    -- Handle characters separately
    for _, character_state in ipairs(character_states) do
        -- Store old character position if it exists
        local old_position = nil
        local agent_index = character_state.agent_index
        local old_character = nil

        -- If we have a valid agent_index, get the old character from storage.agent_characters
        if agent_index and agent_index > 0 and storage.agent_characters[agent_index] then
            old_character = storage.agent_characters[agent_index]
            if old_character then
                old_position = old_character.position
                old_character.destroy()
            end
        end

        -- Create new character at the stored position or old position
        local position = {
            x = tonumber(character_state.position.x),
            y = tonumber(character_state.position.y)
        }
        if not surface.can_place_entity{name="character", position=position} then
            position = old_position or {x=0, y=0}
        end

        local new_character = surface.create_entity({
            name = "character",
            position = position,
            direction = tonumber(character_state.direction),
            force = game.forces.player,
        })

        if new_character then
            -- Update storage.agent_characters if we have a valid agent_index
            if agent_index and agent_index > 0 then
                storage.agent_characters[agent_index] = new_character
            end

            -- Restore character color if it exists
            if character_state.color then
                new_character.color = {
                    r = tonumber(character_state.color.r),
                    g = tonumber(character_state.color.g),
                    b = tonumber(character_state.color.b),
                    a = tonumber(character_state.color.a)
                }
            end

            -- Restore character inventory
            if character_state.inventory then
                local main_inventory = new_character.get_inventory(defines.inventory.character_main)
                if main_inventory then
                    for item_name, count in pairs(character_state.inventory) do
                        -- Remove quotes if they exist
                        item_name = unquote_string(item_name)
                        if item_name and item_name ~= "" then
                            if prototypes.item[item_name] then
                                main_inventory.insert({
                                    name = item_name,
                                    count = tonumber(count)
                                })
                            else
                                -- game.print("Warning: Unknown item " .. item_name)
                            end
                        end
                    end
                else
                    -- game.print("Warning: Could not get character main inventory")
                end
            end

            -- Add character to created_entities for inventory restoration
            created_entities[character_state.entity_number] = {
                entity = new_character,
                state = character_state
            }
        end
    end

    -- Second pass: Restore states
    for unit_number, data in pairs(created_entities) do
        local entity = data.entity
        local state = data.state
        local entity_type = entity.type

        -- game.print("Processing entity: " .. entity.name .. " (type: " .. entity_type .. ")")

        -- Restore inventories based on entity type
        for inv_name, contents in pairs(state.inventories or {}) do
            local inventory = nil

            -- Only try to access inventories that match the entity type (Factorio 2.0: unified crafter_* defines)
            if inv_name == "chest" and entity_type == "container" then
                inventory = entity.get_inventory(defines.inventory.chest)
            elseif inv_name == "crafter_input" and (entity_type == "furnace" or entity_type == "assembling-machine" or entity_type == "rocket-silo") then
                inventory = entity.get_inventory(defines.inventory.crafter_input)
            elseif inv_name == "crafter_output" and (entity_type == "furnace" or entity_type == "assembling-machine" or entity_type == "rocket-silo") then
                inventory = entity.get_inventory(defines.inventory.crafter_output)
            elseif inv_name == "fuel" and entity.burner then
                inventory = entity.get_inventory(defines.inventory.fuel)
            elseif inv_name == "burnt_result" and entity.burner then
                inventory = entity.get_inventory(defines.inventory.burnt_result)
            elseif inv_name == "turret_ammo" and entity_type == "ammo-turret" then
                inventory = entity.get_inventory(defines.inventory.turret_ammo)
            elseif inv_name == "lab_input" and entity_type == "lab" then
                inventory = entity.get_inventory(defines.inventory.lab_input)
            end

            if inventory then
                -- game.print("Found valid inventory for " .. inv_name)
                for quoted_item_name, count in pairs(contents) do
                    local item_name = unquote_string(quoted_item_name)
                    if item_name and item_name ~= "" then
                        if prototypes.item[item_name] then
                            -- game.print("Inserting " .. count .. " " .. item_name)
                            inventory.insert({
                                name = item_name,
                                count = tonumber(count)
                            })
                        else
                            -- game.print("Warning: Unknown item " .. item_name)
                        end
                    else
                        -- game.print("Warning: Empty item name in " .. inv_name)
                    end
                end
            else
                -- game.print("No valid inventory found for " .. inv_name)
            end
        end

        -- Restore burner
        if state.burner and entity.burner then
            if state.burner.currently_burning then
                local burning_name = unquote_string(state.burner.currently_burning)
                if prototypes.item[burning_name] then  -- Verify burning item exists
                    entity.burner.currently_burning = prototypes.item[burning_name]
                    entity.burner.remaining_burning_fuel = tonumber(state.burner.remaining_burning_fuel)
                    entity.burner.heat = tonumber(state.burner.heat)
                else
                    -- game.print("Warning: Unknown burning item " .. burning_name)
                end
            end
        end

        -- Restore recipe - only for entities that can have recipes
        if state.recipe then
            -- Only try to set recipe on appropriate entity types
            if (entity.type == "assembling-machine" or
                entity.type == "furnace" or
                entity.type == "rocket-silo") and
               entity.get_recipe then  -- Double check entity supports recipes

                local recipe_name = unquote_string(state.recipe.name)
                if prototypes.recipe[recipe_name] then
                    -- game.print("Setting recipe " .. recipe_name .. " on " .. entity.name)
                    pcall(function()
                        entity.set_recipe(recipe_name)
                    end)
                else
                    -- game.print("Warning: Unknown recipe " .. recipe_name)
                end
            else
                -- game.print("Warning: Skipping recipe for incompatible entity type: " .. entity.type)
            end
        end

        -- Restore transport belt contents
        if entity_type == "transport-belt" and state.transport_lines then
            -- game.print("Has transport_lines field: " .. tostring(state.transport_lines ~= nil))
            -- Handle front line (line 1)
            local line1 = entity.get_transport_line(1)

            if state.transport_lines["1"] then
                -- game.print("Transport line 1")
                for item_name, count in pairs(state.transport_lines["1"]) do
                    local name = unquote_string(item_name)
                    local item_count = tonumber(count)
                    if prototypes.item[name] then
                       for i = 1, item_count do
                            -- Space items evenly along the belt
                            local position = (i - 1) / item_count
                            line1.insert_at(position, {
                                name = name,
                                count = 1
                            })
                        end
                    end
                end
            end

            -- Handle back line (line 2)
            local line2 = entity.get_transport_line(2)
            if state.transport_lines["2"] then
                -- game.print("Transport line 2")
                for item_name, count in pairs(state.transport_lines["2"]) do
                    local name = unquote_string(item_name)
                    local item_count = tonumber(count)
                    if prototypes.item[name] then
                        for i = 1, item_count do
                            -- Space items evenly along the belt
                            local position = (i - 1) / item_count
                            line2.insert_at(position, {
                                name = name,
                                count = 1
                            })
                        end
                    end
                end
            end
        end

        -- Restore energy and active state
        if state.energy then
            entity.energy = tonumber(state.energy)
        end
        if state.active ~= nil then
            storage.set_active(entity, state.active)
        end
    end

    if #extras_parts > 0 then pcall(les_apply_extras, surface, extras_parts, created_entities) end
    return true
end
