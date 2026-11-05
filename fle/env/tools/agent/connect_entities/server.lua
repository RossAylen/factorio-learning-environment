-- connect_entities

local MAX_SERIALIZATION_ITERATIONS = 1000  -- Maximum iterations for serializing belt groups
local MAX_PLACEMENT_ATTEMPTS = 50  -- Maximum attempts to find placeable positions
local MAX_PATH_LENGTH = 1000  -- Maximum number of path points to process
local MAX_STRAIGHT_SECTIONS = 100
local MAX_UNDERGROUND_SEGMENTS = 50

-- Wire reach values for different electric pole types
local wire_reach = {
    ['small-electric-pole'] = 4,
    ['medium-electric-pole'] = 9,
    ['big-electric-pole'] = 30,
    ['substation'] = 18
}

local default_connect_types = {
    ['pipe-to-ground'] = 'pipe',
    ['underground-belt'] = 'transport-belt',
    ['express-underground-belt'] = 'express-transport-belt',
    ['fast-underground-belt'] = 'fast-transport-belt',
}

local underground_ranges = {
    ['pipe-to-ground'] = 8,
    ['underground-belt'] = 4,
    ['fast-underground-belt'] = 4,
    ['express-underground-belt'] = 4
}

local function is_within_pole_range(position, pole)
    local dx = position.x - pole.position.x
    local dy = position.y - pole.position.y
    local wire_reach = wire_reach[pole.name] or 4
    return (dx * dx + dy * dy) <= wire_reach * wire_reach
end

local function get_electric_network_at_position(position)
    -- Get all electric poles near the position
    local nearby_poles = game.surfaces[1].find_entities_filtered{
        position = position,
        radius = 9, -- Maximum pole reach is 9 for medium poles
        type = "electric-pole"
    }

    -- Check if any pole's wire reaches this position
    for _, pole in pairs(nearby_poles) do
        if is_within_pole_range(position, pole) then
            return pole.electric_network_id
        end
    end
    return nil
end

local function are_positions_in_same_network(pos1, pos2)
    local network1 = get_electric_network_at_position(pos1)
    local network2 = get_electric_network_at_position(pos2)
    return network1 and network2 and network1 == network2
end

local function is_position_saturated(position, reach)
    -- Get nearby poles
    local nearby_poles = game.surfaces[1].find_entities_filtered{
        position = position,
        radius = 9,
        type = "electric-pole"
    }

    -- Check each corner of a 1x1 tile centered on the position
    local corners = {
        {x = position.x - reach/2, y = position.y - reach/2},
        {x = position.x - reach/2, y = position.y + reach/2},
        {x = position.x + reach/2, y = position.y + reach/2},
        {x = position.x + reach/2, y = position.y - reach/2}
    }

    -- For each corner, check if it's within range of any existing pole
    for _, corner in pairs(corners) do
        local corner_covered = false
        for _, pole in pairs(nearby_poles) do
            if is_within_pole_range(corner, pole) then
                corner_covered = true
                break
            end
        end
        if not corner_covered then
            return false -- Found an uncovered corner
        end
    end

    return true -- All corners are covered
end


function get_step_size(connection_type)
    return wire_reach[connection_type] or 1
end

function math.round(x)
    return x >= 0 and math.floor(x + 0.5) or math.ceil(x - 0.5)
end

local function has_valid_fluidbox(entity)
    -- Factorio 2.0: fluidbox methods are on the LuaFluidBox object, not individual elements
    -- Also: get_fluid_system_id -> get_fluid_segment_id
    return storage.fb(entity) and #storage.fb(entity) > 0 and storage.fb(entity)[1] and storage.fb(entity).get_fluid_segment_id
end

local function are_fluidboxes_connected(entity1, entity2)
    if has_valid_fluidbox(entity1) and has_valid_fluidbox(entity2) then
        -- Factorio 2.0: get_fluid_system_id -> get_fluid_segment_id
        return storage.fb(entity1).get_fluid_segment_id(1) == storage.fb(entity2).get_fluid_segment_id(1)
    end
    return false
end

-- Calculate maximum possible underground sections based on inventory
local function calculate_max_underground_sections(player, underground_type)
    local available_count = 0
    for _, inv in pairs({defines.inventory.character_main}) do
        if player.get_inventory(inv) then
            available_count = available_count + player.get_inventory(inv).get_item_count(underground_type)
        end
    end
    -- Each underground section requires 2 entities (entrance and exit)
    return math.floor(available_count / 2)
end

-- Helper function to check if an entity type is an underground variant
local function is_underground_type(entity_type)
    return underground_ranges[entity_type] ~= nil
end

-- Modified split_section_into_underground_segments to respect inventory limits
local function split_section_into_underground_segments(section, path, range, max_segments)
    local segments = {}

    -- Add margin of 1 at start and end of section
    local effective_start = section.start_index + 1
    local effective_end = section.end_index - 1

    -- Check if section is still long enough after adding margins
    if effective_end - effective_start < 2 then
        return segments  -- Return empty segments if section is too short
    end

    local current_start = effective_start
    local segment_count = 0
    local iteration_count = 0
    local MAX_ITERATIONS = math.min(section.length * 2, MAX_UNDERGROUND_SEGMENTS) -- Prevent excessive iterations


    while current_start + 1 < effective_end and segment_count < max_segments do
        iteration_count = iteration_count + 1
        if iteration_count > MAX_ITERATIONS then
            -- game.print("Warning: Maximum iterations reached while splitting underground segments")
            break
        end
        -- Calculate end index for this segment
        local end_index = math.min(current_start + range, effective_end)

        -- Only create segment if there's at least 1 tile gap between entrance and exit
        if end_index > current_start then
            table.insert(segments, {
                entrance_index = current_start,
                exit_index = end_index,
                direction = section.direction
            })

            segment_count = segment_count + 1

            -- Move to position after the exit for next iteration
            current_start = end_index + 1
        else
            -- If we can't create a valid segment, move forward
            current_start = current_start + 1
        end
    end


    return segments
end

-- Find straight sections in path suitable for underground entities
local function find_straight_sections(path, min_length)
    local sections = {}
    local current_section = {
        start_index = 1,
        direction = nil,
        length = 0
    }

    for i = 1, #path - 1 do --Always start slightly into the path, and away from the end to prevent connection issues.
        local current_pos = path[i].position
        local next_pos = path[i + 1].position
        local dx = next_pos.x - current_pos.x
        local dy = next_pos.y - current_pos.y
        local current_direction = {dx = dx, dy = dy}

        -- Normalize direction
        if math.abs(dx) > math.abs(dy) then
            current_direction = {dx = dx/math.abs(dx), dy = 0}
        else
            current_direction = {dx = 0, dy = dy/math.abs(dy)}
        end

        if not current_section.direction then
            current_section.direction = current_direction
        end

        -- Check if we're still going in the same direction
        if current_section.direction.dx == current_direction.dx and
           current_section.direction.dy == current_direction.dy then
            current_section.length = current_section.length + 1
        else
            -- Direction changed, check if previous section was long enough
            if current_section.length >= min_length then
                table.insert(sections, {
                    start_index = current_section.start_index,
                    end_index = i,
                    direction = current_section.direction,
                    length = current_section.length
                })
            end
            -- Start new section
            current_section = {
                start_index = i,
                direction = current_direction,
                length = 1
            }
        end
    end

    -- Check final section
    if current_section.length >= min_length then
        table.insert(sections, {
            start_index = current_section.start_index,
            end_index = #path,
            direction = current_section.direction,
            length = current_section.length
        })
    end

    return sections
end

-- Helper function to serialize a belt group using proper BFS
local function serialize_belt_group(entity)
    if not entity or not entity.valid or entity.type ~= "transport-belt" then
        return nil
    end

    local serialized = {}
    local visited = {}
    local queue = {entity}
    local max_search = 500 -- Prevent infinite loops
    local search_count = 0

    while #queue > 0 and search_count < max_search do
        search_count = search_count + 1
        local current_belt = table.remove(queue, 1)
        
        if not current_belt or not current_belt.valid then
            goto continue
        end
        
        local belt_id = current_belt.unit_number
        if visited[belt_id] then
            goto continue
        end
        visited[belt_id] = true
        
        -- Serialize this belt
        table.insert(serialized, storage.utils.serialize_entity(current_belt))
        
        -- Add all neighboring belts to queue (both inputs and outputs)
        if current_belt.belt_neighbours then
            -- Add output belts
            if current_belt.belt_neighbours.outputs then
                for _, output_belt in pairs(current_belt.belt_neighbours.outputs) do
                    if output_belt and output_belt.valid and not visited[output_belt.unit_number] then
                        table.insert(queue, output_belt)
                    end
                end
            end
            -- Add input belts  
            if current_belt.belt_neighbours.inputs then
                for _, input_belt in pairs(current_belt.belt_neighbours.inputs) do
                    if input_belt and input_belt.valid and not visited[input_belt.unit_number] then
                        table.insert(queue, input_belt)
                    end
                end
            end
        end
        
        ::continue::
    end
    
    return serialized
end


local function are_poles_connected(entity1, entity2)
    if not (entity1 and entity2) then return false end
    if not (entity1.electric_network_id and entity2.electric_network_id) then return false end
    return entity1.electric_network_id == entity2.electric_network_id
end

local function is_placeable(position)
    local invalid_tiles = {
        ["water"] = true,
        ["deepwater"] = true,
        ["water-green"] = true,
        ["deepwater-green"] = true,
        ["water-shallow"] = true,
        ["water-mud"] = true,
    }

    local entities = game.surfaces[1].find_entities_filtered{
        position = position,
        -- Factorio 2.0: collision_mask expects a collision layer name string
        collision_mask = "player"
    }
    if #entities == 1 then
        if entities[1].name == "character" then
            return not invalid_tiles[game.surfaces[1].get_tile(position.x, position.y).name]
        end
    end
    return #entities == 0 and not invalid_tiles[game.surfaces[1].get_tile(position.x, position.y).name]
end

local function find_placeable_neighbor(pos, previous_pos)
    local directions = {
        {dx = 0, dy = -1},  -- up
        {dx = 1, dy = 0},   -- right
        {dx = 0, dy = 1},   -- down
        {dx = -1, dy = 0}   -- left
    }

    if previous_pos then
        local desired_dx = pos.x - previous_pos.x
        local desired_dy = pos.y - previous_pos.y
        table.sort(directions, function(a, b)
            local a_score = math.abs(a.dx - desired_dx) + math.abs(a.dy - desired_dy)
            local b_score = math.abs(b.dx - desired_dx) + math.abs(b.dy - desired_dy)
            return a_score < b_score
        end)
    end

    for _, dir in ipairs(directions) do
        local test_pos = {x = pos.x + dir.dx, y = pos.y + dir.dy}
        if is_placeable(test_pos) then
            return test_pos
        end
    end
    return nil
end


local function interpolate_manhattan(pos1, pos2)
    local interpolated = {}
    local dx = pos2.x - pos1.x
    local dy = pos2.y - pos1.y
    local manhattan_distance = math.abs(dx) + math.abs(dy)
    -- game.print("Distance3 "..manhattan_distance)
    if manhattan_distance > 2 then
        local steps = math.max(math.abs(dx), math.abs(dy))
        local x_step = math.floor((dx / steps)*2)/2
        local y_step = math.floor((dy / steps)*2)/2

        for i = 1, steps - 1 do
            local new_pos_x = {x = pos1.x + math.round(x_step * i), y = pos1.y}
            if is_placeable(new_pos_x) then
                table.insert(interpolated, {position = new_pos_x})
            else
                local neighbor = find_placeable_neighbor(new_pos_x, pos1)
                if neighbor then
                    table.insert(interpolated, {position = neighbor})
                end
            end

            local new_pos_y = {x = pos1.x + math.round(x_step * i), y = pos1.y + math.round(y_step * i)}
            if is_placeable(new_pos_y) then
                table.insert(interpolated, {position = new_pos_y})
            else
                local neighbor = find_placeable_neighbor(new_pos_y, pos1)
                if neighbor then
                    table.insert(interpolated, {position = neighbor})
                end
            end
        end
        --elseif math.abs(dx) == 1 and math.abs(dy) == 1 then
        --    local mid_pos = {x = pos2.x, y = pos1.y}
        --    if is_placeable(mid_pos) then
        --        table.insert(interpolated, {position = mid_pos})
        --    else
        --        mid_pos = {x = pos1.x, y = pos2.y}
        --        if is_placeable(mid_pos) then
        --            table.insert(interpolated, {position = mid_pos})
        --        else
        --            mid_pos = find_placeable_neighbor(mid_pos, pos1)
        --            if mid_pos then
        --                table.insert(interpolated, {position = mid_pos})
        --            end
        --        end
        --    end
        --end
        elseif math.abs(dx) == 1 and math.abs(dy) == 1 then --and math.abs(dx) <= 1.5 and math.abs(dy) <= 1.5 then
            -- Try first horizontal then vertical movement
            local mid_pos = {x = pos2.x, y = pos1.y}
            if is_placeable(mid_pos) then
                table.insert(interpolated, {position = mid_pos})
            else
                -- Try vertical then horizontal movement
                mid_pos = {x = pos1.x, y = pos2.y}
                if is_placeable(mid_pos) then
                    table.insert(interpolated, {position = mid_pos})
                else
                    -- If neither orthogonal position works, try to find a neighbor
                    local neighbor = find_placeable_neighbor(mid_pos, pos1)
                    if neighbor then
                        table.insert(interpolated, {position = neighbor})
                    end
                end
            end

    end

    return interpolated
end



local function place_at_position(player, connection_type, current_position, dir, serialized_entities, dry_run, counter_state, is_underground_exit)

    local is_electric_pole = wire_reach[connection_type] ~= nil
    local placement_position = current_position
    local existing_entity = nil

    for _, entity in pairs(serialized_entities) do
        if entity.position.x == placement_position.x and entity.position.y == placement_position.y then
            return
        end
    end

    if is_electric_pole then
        if is_position_saturated(current_position, wire_reach[connection_type]) then

            return -- No need to place another pole
        end

        placement_position = game.surfaces[1].find_non_colliding_position(connection_type, current_position, 2, 0.1)
        if not placement_position then
            error("Cannot find suitable position to place " .. connection_type)
        end
    else
        local entities = game.surfaces[1].find_entities_filtered{
            position = current_position,
            type = {"beam", "resource", "player"},
            invert=true

        }
        for _, entity in pairs(entities) do
            if entity.name == connection_type then
                existing_entity = entity
                break
            end
        end
    end

    if existing_entity then
        -- game.print("Existing entity "..existing_entity.name)
        -- Get the existing network ID before any modifications
        --local existing_network_id = has_valid_fluidbox(existing_entity) and storage.fb(existing_entity)[1].get_fluid_system_id()

        -- Update direction if needed
        if existing_entity.name ~= connection_type then
            if existing_entity.direction ~= dir then
                existing_entity.direction = dir
            end
        end

        -- For pipes, merge networks
        if connection_type == 'pipe' then
            for _, serialized in ipairs(serialized_entities) do
                local entity = game.surfaces[1].find_entity(connection_type, serialized.position)
                if entity and has_valid_fluidbox(entity) then
                    existing_entity.connect_neighbour(entity)
                end
            end
        end

        -- Update or add to serialized list
        for i, serialized in ipairs(serialized_entities) do
            if serialized.position.x == current_position.x and serialized.position.y == current_position.y then
                serialized_entities[i] = storage.utils.serialize_entity(existing_entity)
                return existing_entity
            end
        end
        table.insert(serialized_entities, storage.utils.serialize_entity(existing_entity))
        return existing_entity

    else
        -- For underground entities, we need to set the correct type (input/output)
        local entity_variant = {
            name = connection_type,
            position = placement_position,
            direction = dir,
            force = player.force,
            type = is_underground_exit and "output" or "input",
            move_stuck_players=true
        }
        -- We can just teleport away here to avoid collision as we dont adhere by distance rules in connect_entities
        player.teleport({placement_position.x+2, placement_position.y+2})
        local can_place
        if connection_type == 'pipe' or connection_type == 'pipe-to-ground' or connection_type == 'underground-pipe' then
            -- Use permissive surface check for pipe placement to allow tight spaces
            can_place = game.surfaces[1].can_place_entity({
                name = connection_type,
                position = placement_position,
                direction = dir,
                force = player.force
            })
        else
            can_place = storage.utils.can_place_entity(player, connection_type, placement_position, dir)
        end

        --local can_place = storage.utils.avoid_entity(1, connection_type, placement_position, dir)
        --if not can_build then
        --    error("Cannot place the entity at the specified position: x="..position.x..", y="..position.y)
        --end
        --local player_position = player.position
       -- player.teleport({placement_position.x, placement_position.y})
        --local can_place = storage.actions.can_place_entity(1, connection_type, dir, placement_position.x, placement_position.y)--game.surfaces[1].can_place_entity(entity_variant)
        --player.teleport(player_position)

        --local can_place = storage.utils.avoid_entity(1, connection_type, placement_position, dir)
        rendering.draw_circle{only_in_alt_mode=true, width = 0.25, color = {r = 0, g = 1, b = 0}, surface = player.surface, radius = 0.5, filled = false, target = placement_position, time_to_live = 12000}

        if dry_run and can_place == false then
            -- Define the area where the entity will be placed
            local target_area = {
                {x = placement_position.x - 1 / 2, y = placement_position.y - 1 / 2},
                {x = placement_position.x + 1 / 2, y = placement_position.y + 1 / 2}
            }

            -- Check for collision with other entities
            local entities = player.surface.find_entities_filtered{area = target_area, force = player.force}
            for _, entity in pairs(entities) do
                -- game.print("1 "..entity.name)
            end

            error("Cannot connect due to placement blockage 1.")
        end


        -- Place entity
        if can_place and not dry_run then
            --storage.utils.avoid_entity(player.index, connection_type, placement_position, dir)

            local placed_entity = game.surfaces[1].create_entity(entity_variant)
            if placed_entity then
                player.remove_item({name = connection_type, count = 1})
                counter_state.place_counter = counter_state.place_counter + 1
                table.insert(serialized_entities, storage.utils.serialize_entity(placed_entity))
                return placed_entity
            end
        
        elseif can_place and dry_run then
            counter_state.place_counter = counter_state.place_counter + 1
            return nil

        else
            -- game.print("Avoiding entity at " .. placement_position.x.. ", " .. placement_position.y)
            -- storage.utils.avoid_entity(player.index, connection_type, placement_position, dir)

            -- error("Cannot place entity")
            --local entities = player.surface.find_entities_filtered{position=placement_position, radius=0.5, type = {"beam", "resource", "player"}, invert=true}
            --local can_place = #entities == 0
            --if can_place then
            --    local tile = player.surface.get_tile(placement_position.x, placement_position.y)
            --    if is_water_tile(tile.name) then
            --        can_place = false
            --    end
            --end
            --
            --if can_place then
            --    local placed_entity = player.surface.create_entity({
            --        name = connection_type,
            --        position = placement_position,
            --        direction = dir,
            --        force = player.force
            --    })
            --
            --    if placed_entity then
            --        player.remove_item({name = connection_type, count = 1})
            --        counter_state.place_counter = counter_state.place_counter + 1
            --        table.insert(serialized_entities, storage.utils.serialize_entity(placed_entity))
            --        return placed_entity
            --    end
            --
            --end
        end
    end

    -- Check inventory
    local has_item = false
    for _, inv in pairs({defines.inventory.character_main}) do
        if player.get_inventory(inv) then
            local count = player.get_inventory(inv).get_item_count(connection_type)
            if count > 0 then
                has_item = true
                break
            end
        end
    end
    if not has_item then
        error("You do not have the required item in their inventory.")
    end

    -- We can just teleport away here to avoid collision as we dont adhere by distance rules in connect_entities
    player.teleport({placement_position.x+2, placement_position.y+2})
    local can_place
    if connection_type == 'pipe' or connection_type == 'pipe-to-ground' or connection_type == 'underground-pipe' then
        -- Use permissive surface check for pipe placement to allow tight spaces
        can_place = game.surfaces[1].can_place_entity({
            name = connection_type,
            position = placement_position,
            direction = dir,
            force = player.force
        })
    else
        can_place = storage.utils.can_place_entity(player, connection_type, placement_position, dir)
    end
    --local player_position = player.position
    --player.teleport({placement_position.x, placement_position.y})
    --local can_place = storage.actions.can_place_entity(1, connection_type, dir, placement_position.x, placement_position.y)--game.surfaces[1].can_place_entity(entity_variant)
    --player.teleport(player_position)

    --local can_place = storage.utils.avoid_entity(1, connection_type, placement_position, dir)
    rendering.draw_circle{only_in_alt_mode=true, width = 0.25, color = {r = 0, g = 1, b = 0}, surface = player.surface, radius = 0.5, filled = false, target = placement_position, time_to_live = 12000}

    if dry_run and can_place == false then
        local target_area = {
                {x = placement_position.x - 1 / 2, y = placement_position.y - 1 / 2},
                {x = placement_position.x + 1 / 2, y = placement_position.y + 1 / 2}
            }

        -- Check for collision with other entities
        local entities = player.surface.find_entities_filtered{area = target_area, force = player.force}
        for _, entity in pairs(entities) do
            -- game.print("1: "..entity.name)
        end

        error("Cannot connect due to placement blockage.")
    end


    -- Place entity
    if can_place and not dry_run then
        --storage.utils.avoid_entity(player.index, connection_type, placement_position, dir)

        local placed_entity = game.surfaces[1].create_entity({
            name = connection_type,
            position = placement_position,
            direction = dir,
            force = player.force,
            move_stuck_players=true
        })

        if placed_entity then
            player.remove_item({name = connection_type, count = 1})
            counter_state.place_counter = counter_state.place_counter + 1
            table.insert(serialized_entities, storage.utils.serialize_entity(placed_entity))
            return placed_entity
        end
    
    elseif can_place and dry_run then
        counter_state.place_counter = counter_state.place_counter + 1
        return nil

    else
        -- game.print("Avoiding entity at " .. placement_position.x.. ", " .. placement_position.y)
        -- storage.utils.avoid_entity(player.index, connection_type, placement_position, dir)

        -- error("Cannot place entity")
        --local entities = player.surface.find_entities_filtered{position=placement_position, radius=0.5, type = {"beam", "resource", "player"}, invert=true}
        --local can_place = #entities == 0
        --if can_place then
        --    local tile = player.surface.get_tile(placement_position.x, placement_position.y)
        --    if is_water_tile(tile.name) then
        --        can_place = false
        --    end
        --end
        --
        --if can_place then
        --    local placed_entity = player.surface.create_entity({
        --        name = connection_type,
        --        position = placement_position,
        --        direction = dir,
        --        force = player.force
        --    })
        --
        --    if placed_entity then
        --        player.remove_item({name = connection_type, count = 1})
        --        counter_state.place_counter = counter_state.place_counter + 1
        --        table.insert(serialized_entities, storage.utils.serialize_entity(placed_entity))
        --        return placed_entity
        --    end
        --
        --end
    end
end

local function table_contains(tbl, element)
    for _, value in ipairs(tbl) do
        if value == element then
            return true
        end
    end
    return false
end

local function connect_entities(player_index, source_x, source_y, target_x, target_y, path_handle, connection_types, dry_run)
    local counter_state = {place_counter = 0}
    local player = storage.agent_characters[player_index]
    local last_placed_entity = nil

    local start_position = {x = math.floor(source_x*2)/2, y = math.floor(source_y*2)/2}
    local end_position = {x = target_x, y = target_y}


    local raw_path = storage.paths[path_handle]

    if not raw_path or type(raw_path) ~= "table" or #raw_path == 0 then
        error("Invalid path: " .. serpent.line(path))
    end

    local path = storage.utils.normalise_path(raw_path, start_position, end_position)

    if #path == 0 then
        error(string.format(
            "\"Could not connect entities from (%.1f, %.1f) to (%.1f, %.1f): no placeable positions in normalized path\"",
            source_x,
            source_y,
            target_x,
            target_y
        ))
    end

    -- Get default and underground connection types
    local default_connection_type = default_connect_types[connection_types[1]] or connection_types[1]
    local underground_type = nil
    for _, type in ipairs(connection_types) do
        if is_underground_type(type) then
            underground_type = type
            break
        end
    end

    --rendering.clear()

    rendering.draw_circle{only_in_alt_mode=true, width = 1, color = {r = 1, g = 0, b = 0}, surface = player.surface, radius = 0.5, filled = false, target = start_position, time_to_live = 60000}
    rendering.draw_circle{only_in_alt_mode=true, width = 1, color = {r = 0, g = 1, b = 0}, surface = player.surface, radius = 0.5, filled = false, target = end_position, time_to_live = 60000}

    for i = 1, #path - 1 do
        rendering.draw_line{only_in_alt_mode=true, surface = player.surface, from = path[i].position, to =  path[i + 1].position, color = {1, 0, 1}, width = 2,  dash_length=0.25, gap_length = 0.25}
    end
    for i = 1, #raw_path - 1 do
        rendering.draw_line{only_in_alt_mode=true, surface = player.surface, from = raw_path[i].position, to =  raw_path[i + 1].position, color = {1, 1, 0}, width = 0,  dash_length=0.2, gap_length = 0.2}
    end


    local last_position = start_position
    local step_size = wire_reach[default_connection_type] or 1
    local is_electric_pole = wire_reach[default_connection_type] ~= nil


    for i = 1, #path-1, step_size do
        storage.elapsed_ticks = storage.elapsed_ticks + storage.utils.calculate_movement_ticks(player, last_position, path[i].position)
        last_position = path[i].position
    end

    local serialized_entities = {}

    -- Get source and target entities
    local source_entity = storage.utils.get_closest_entity(player, {x = source_x, y = source_y})
    local target_entity = storage.utils.get_closest_entity(player, {x = target_x, y = target_y})


    if #connection_types == 1 and connection_types[1] == 'pipe-to-ground' then
        
        -- Calculate the direction from start to end.
        -- Factorio 2.0: get_direction returns 0, 4, 8, 12 - pass directly to get_entity_direction
        local dir = storage.utils.get_direction(start_position, end_position)
        local entrance_dir = storage.utils.get_entity_direction(underground_type, dir)

        -- Place the underground entrance at the start position.
        place_at_position(player, underground_type, start_position, entrance_dir,
                          serialized_entities, dry_run, counter_state, false)

        local exit_dir
        if underground_type == "pipe-to-ground" then
          -- For pipe-to-ground, rotate the direction 180° for the exit.
          -- Factorio 2.0: rotate 180° by adding 8 and mod 16
          exit_dir = storage.utils.get_entity_direction(underground_type, (dir + 8) % 16)
        else
          exit_dir = storage.utils.get_entity_direction(underground_type, dir)
        end
        
        -- Place the underground exit at the end position.
        place_at_position(player, underground_type, end_position, exit_dir,
                          serialized_entities, dry_run, counter_state, true)
        
        return {
          entities = serialized_entities,
          connected = true,
          number_of_entities = counter_state.place_counter
        }
    end


    if underground_type then
        -- Calculate maximum possible underground sections based on inventory
        local max_underground_sections = calculate_max_underground_sections(player, underground_type)

        -- Find straight sections suitable for underground entities
        local range = underground_ranges[underground_type]
        local straight_sections = find_straight_sections(path, 4)

        -- Track remaining underground sections we can create
        local remaining_sections = max_underground_sections




        local current_index = 1
        for _, section in ipairs(straight_sections) do

            if remaining_sections <= 0 then
                break
            end

            local MAX_INDEX_PLACEMENT = 200
            -- Place regular entities up to the section
            while current_index < section.start_index do
                local current_pos = path[current_index].position
                local next_pos = path[current_index + 1].position
                -- Factorio 2.0: get_direction returns 0/4/8/12 - pass directly
                local dir = storage.utils.get_direction(current_pos, next_pos)
                place_at_position(player, default_connection_type, current_pos,
                        storage.utils.get_entity_direction(default_connection_type, dir),
                        serialized_entities, dry_run, counter_state, false)
                current_index = current_index + 1
                if current_index > MAX_INDEX_PLACEMENT then
                    break
                end
            end

            -- Place initial surface entity for direction change
            local margin_pos = path[section.start_index].position
            local margin_next_pos = path[section.start_index + 1].position
            local margin_dir = storage.utils.get_direction(margin_pos, margin_next_pos)
            -- Factorio 2.0: get_direction returns 0/4/8/12 - pass directly
            place_at_position(player, default_connection_type, margin_pos,
                    storage.utils.get_entity_direction(default_connection_type, margin_dir),
                    serialized_entities, dry_run, counter_state, false)

            -- Split the section into multiple underground segments, limited by remaining_sections
            local segments = split_section_into_underground_segments(section, path, range, remaining_sections)

            -- Update remaining_sections count
            remaining_sections = remaining_sections - #segments

            for i, segment in ipairs(segments) do
                -- Place underground entrance
                local entrance_pos = path[segment.entrance_index].position
                local exit_pos = path[segment.exit_index].position
                local dir = storage.utils.get_direction(entrance_pos, exit_pos)

                -- Factorio 2.0: get_direction returns 0/4/8/12 - pass directly
                local entity_dir = storage.utils.get_entity_direction(underground_type, dir)

                place_at_position(player, underground_type, entrance_pos,
                        entity_dir,
                        serialized_entities, dry_run, counter_state, false)

                -- Adjust direction for pipe-to-ground exit (rotate 180°)
                if underground_type == 'pipe-to-ground' then
                    entity_dir = storage.utils.get_entity_direction(underground_type, (dir + 8) % 16)
                end

                place_at_position(player, underground_type, exit_pos,
                        entity_dir,
                        serialized_entities, dry_run, counter_state, true)

                -- Update current_index to after the exit
                current_index = segment.exit_index + 1
            end
            -- Place final surface entity for direction change if we had segments
            if #segments > 0 then
                local final_margin_pos = path[section.end_index].position
                local final_prev_pos = path[section.end_index - 1].position
                local final_dir = storage.utils.get_direction(final_prev_pos, final_margin_pos)
                -- Factorio 2.0: get_direction returns 0/4/8/12 - pass directly
                place_at_position(player, default_connection_type, final_margin_pos,
                        storage.utils.get_entity_direction(default_connection_type, final_dir),
                        serialized_entities, dry_run, counter_state, false)
            end

            -- If we've used all available underground sections, use regular entities for the rest
            if remaining_sections <= 0 then
                break
            end

        end

        -- Place remaining regular entities to finish the connection
        while current_index < #path do
            local current_pos = path[current_index].position
            local next_pos = path[current_index + 1].position
            -- Factorio 2.0: get_direction returns 0/4/8/12 - pass directly
            local dir = storage.utils.get_direction(current_pos, next_pos)
            place_at_position(player, default_connection_type, current_pos,
                    storage.utils.get_entity_direction(default_connection_type, dir),
                    serialized_entities, dry_run, counter_state, false)
            current_index = current_index + 1
        end

        -- After underground segment placement
        if current_index == #path and not path[#path].has_entity then
            local final_pos = path[#path].position
            local prev_pos = path[#path-1].position
            -- Factorio 2.0: get_direction returns 0/4/8/12 - pass directly
            local dir = storage.utils.get_direction(prev_pos, final_pos)
            place_at_position(player, default_connection_type, final_pos,
                    storage.utils.get_entity_direction(default_connection_type, dir),
                    serialized_entities, dry_run, counter_state, false)
        end
    else
        -- Handle source belt orientation if it exists
        if not is_electric_pole and not table_contains(connection_types, 'pipe') then
            local source_pos = {x = source_x, y = source_y}
            local entities = game.surfaces[1].find_entities_filtered{
                position = source_pos,
                name = connection_types,
                force = "player"
            }

            if #entities > 0 and #path > 1 then
                -- Calculate initial direction based on first two points in path
                local initial_dir = storage.utils.get_direction(path[1].position, path[2].position)
                --local entity_dir = storage.utils.get_entity_direction('pipe', initial_dir/2)

                -- Update source belt direction if needed
                local source_belt = entities[1]
                if source_belt and source_belt.valid and source_belt.direction ~= initial_dir then
                    source_belt.direction = initial_dir
                    table.insert(serialized_entities, storage.utils.serialize_entity(source_belt))
                end
            end
        end

        if is_electric_pole then
            -- Place poles until we achieve connectivity
            local last_pole = source_entity

            for i = 1, #path, step_size do
                local current_pos = path[i].position
                local dir = storage.utils.get_direction(current_pos, path[math.min(i + step_size, #path)].position)
                -- Factorio 2.0: get_direction returns 0/4/8/12 - pass directly
                local entity_dir = storage.utils.get_entity_direction(default_connection_type, dir)

                -- Place the pole
                local placed_entity = place_at_position(player, default_connection_type, current_pos, entity_dir, serialized_entities, dry_run, counter_state)

                if not dry_run then
                    -- Get the newly placed pole
                    local current_pole = placed_entity or storage.utils.get_closest_entity(player, current_pos)

                    -- Check if we've achieved connectivity to the target
                    if are_poles_connected(current_pole, target_entity) then
                        break  -- Stop placing poles once we have connectivity
                    end

                    last_pole = current_pole
                end
            end

            -- If we haven't achieved connectivity yet, place one final pole at the target
            if not dry_run and last_pole and target_entity and not are_poles_connected(last_pole, target_entity) then
                local final_dir = storage.utils.get_direction(path[#path].position, end_position)
                -- game.print("Placing final pole at "..serpent.line(end_position))
                -- Factorio 2.0: get_direction returns 0/4/8/12 - pass directly
                place_at_position(player, default_connection_type, end_position,
                        storage.utils.get_entity_direction(default_connection_type, final_dir),
                        serialized_entities, dry_run, counter_state)
            end
        else
            if table_contains(connection_types, 'pipe') then
                place_at_position(player, 'pipe', start_position, 0, serialized_entities, dry_run, counter_state)
            end

            for i = 1, #path-1, step_size do
                local dir = storage.utils.get_direction(path[i].position, path[math.min(i + step_size, #path)].position)
                -- Factorio 2.0: get_direction returns 0/4/8/12 - pass directly
                local placed = place_at_position(player, default_connection_type, path[i].position,
                        storage.utils.get_entity_direction(default_connection_type, dir),
                        serialized_entities, dry_run, counter_state)
                if placed then
                    last_placed_entity = placed
                end
            end

            -- Handle final placement
            if table_contains(connection_types, 'pipe') then
                local preemptive_target = {
                    x = (target_x + path[#path].position.x)/2,
                    y = (target_y + path[#path].position.y)/2
                }

                -- Place intermediate and final pipes
                place_at_position(player, 'pipe', path[#path].position,
                        storage.utils.get_direction(path[#path].position, preemptive_target),
                        serialized_entities, dry_run, counter_state)

                place_at_position(player, 'pipe', preemptive_target,
                        storage.utils.get_direction(path[#path].position, preemptive_target),
                        serialized_entities, dry_run, counter_state)

                place_at_position(player, 'pipe', end_position,
                        storage.utils.get_direction(preemptive_target, end_position),
                        serialized_entities, dry_run, counter_state)
            else
                local last_path_index = #path
                local second_to_last_index = math.max(1, last_path_index - 1)
                local final_dir = storage.utils.get_direction(
                        path[second_to_last_index].position,
                        path[last_path_index].position
                )

                -- Factorio 2.0: get_direction returns 0/4/8/12 - pass directly
                local final_entity = place_at_position(player, default_connection_type, end_position,
                        storage.utils.get_entity_direction(default_connection_type, final_dir),
                        serialized_entities, dry_run, counter_state)
                        

                if final_entity then
                    last_placed_entity = final_entity
                end

                -- After all belts are placed, serialize the entire belt group if we're not in dry run
                if not dry_run and last_placed_entity and last_placed_entity.valid and default_connection_type:find("belt") then
                    -- Clear the existing serialized entities (which only contain individual placements)
                    local individual_count = #serialized_entities
                    serialized_entities = {}
                    
                    -- Find the full belt network by checking from source position
                    local source_belt = game.surfaces[1].find_entity(default_connection_type, start_position)
                    local group_data = nil
                    
                    if source_belt and source_belt.valid then
                        group_data = serialize_belt_group(source_belt)
                    else
                        group_data = serialize_belt_group(last_placed_entity)
                    end
                    
                    if group_data then
                        for _, serialized in ipairs(group_data) do
                            table.insert(serialized_entities, serialized)
                        end
                    else
                        -- Restore individual entities if group serialization failed
                        for i = 1, individual_count do
                            serialized_entities[i] = serialized_entities[i]
                        end
                    end
                end
            end
        end
    end

    -- Check final connectivity
    local is_connected = false
    if source_entity and target_entity then
        if is_electric_pole then
            is_connected = are_poles_connected(source_entity, target_entity)
        else
            is_connected = are_fluidboxes_connected(source_entity, target_entity)
        end
    end

    -- game.print("Connection status: " .. tostring(is_connected))


    return {
        entities = serialized_entities,
        connected = is_connected,
        number_of_entities = counter_state.place_counter
    }
end

storage.utils.normalise_path = function(original_path, start_position, end_position)
    local path = {}
    local seen = {}  -- To track seen positions
    if original_path == nil or #original_path < 1 or original_path == "not_found" then
        error("Failed to find a path.")
    end
    if math.ceil(start_position.x) == start_position.x then
        start_position.x = start_position.x + 0.5
        --start_position.y = start_position.y + 0.5
    end
    if math.ceil(start_position.y) == start_position.y then
        start_position.y = start_position.y + 0.5
    end

    if math.ceil(end_position.x) == end_position.x or math.ceil(end_position.y) == end_position.y then
        end_position.x = end_position.x + 0.5
        end_position.y = end_position.y + 0.5
    end

    --game.print(serpent.block(original_path))
    --for i = 1, #original_path do
    --    game.print(serpent.line(original_path[i]))
    --end

    if math.ceil(original_path[1].position.x) == original_path[1].position.x or math.ceil(original_path[1].position.y) == original_path[1].position.y then
        original_path[1].position.x = original_path[1].position.x + 0.5
        original_path[1].position.y = original_path[1].position.y + 0.5
    end

    -- Helper function to add unique positions
    local function add_unique(pos, prev_pos)
        local key = pos.x .. "," .. pos.y
        if not seen[key] then
            if is_placeable(pos) then
                table.insert(path, {position = pos})
                seen[key] = true
                return pos
            else
                local alt_pos = find_placeable_neighbor(pos, prev_pos)
                if alt_pos then
                    local alt_key = alt_pos.x .. "," .. alt_pos.y
                    if not seen[alt_key] then
                        table.insert(path, {position = alt_pos})
                        seen[alt_key] = true
                        return alt_pos
                    end
                end
            end
        end
        return nil
    end

    -- Add start position first
    local previous_pos = add_unique(start_position, nil) or start_position

    -- Process each segment of the path
    local current_pos = previous_pos
    for i = 1, #original_path do
        local target_pos = original_path[i].position
        local interpolated = interpolate_manhattan(current_pos, target_pos)

        -- Add interpolated positions
        for _, point in ipairs(interpolated) do
            local new_pos = add_unique(point.position, current_pos)
            if new_pos then
                current_pos = new_pos
            end
        end

        -- Add the target position
        local new_pos = add_unique(target_pos, current_pos)
        if new_pos then
            current_pos = new_pos
        end
    end

    -- Finally interpolate to end position if it's different from the last position
    if current_pos.x ~= end_position.x or current_pos.y ~= end_position.y then
        local interpolated = interpolate_manhattan(current_pos, end_position)
        for _, point in ipairs(interpolated) do
            local new_pos = add_unique(point.position, current_pos)
            if new_pos then
                current_pos = new_pos
            end
        end
        add_unique(end_position, current_pos)
    end

    return path
end

-- Helper function to check if two positions are adjacent
local function are_positions_adjacent(pos1, pos2)
    local dx = math.abs(pos1.x - pos2.x)
    local dy = math.abs(pos1.y - pos2.y)
    return (dx <= 1 and dy <= 1) and not (dx == 0 and dy == 0)
end

-- Helper function to validate belt direction compatibility
local function are_belt_directions_compatible(dir1, dir2, pos1, pos2)
    -- Convert positions to vectors
    local dx = pos2.x - pos1.x
    local dy = pos2.y - pos1.y

    -- Check if the belts are pointing in compatible directions
    -- This is a simplified check - you may need to adjust based on your specific needs
    if dir1 == dir2 then
        -- Same direction - check if it matches position delta
        local expected_dir = storage.utils.get_direction(pos1, pos2)
        return dir1 == expected_dir
    else
        -- Different directions - check if they form a valid turn
        -- Add more sophisticated turn validation if needed
        return are_positions_adjacent(pos1, pos2)
    end
end


-- Helper function to check if two positions are connected by belts
local function are_positions_belt_connected(start_pos, end_pos, connection_type)
    -- Find belt at start position - try multiple belt types if connection_type is nil
    local belt_types = {"transport-belt", "fast-transport-belt", "express-transport-belt"}
    if connection_type then
        belt_types = {connection_type}
    end
    
    local start_belt = nil
    for _, belt_type in ipairs(belt_types) do
        start_belt = game.surfaces[1].find_entity(belt_type, start_pos)
        if start_belt then
            break
        end
    end
    
    if not start_belt then
        return false
    end
    
    -- Use BFS to find if there's a path to end position
    local visited = {}
    local queue = {start_belt}
    local max_search = 200 -- Prevent infinite loops
    local search_count = 0
    
    while #queue > 0 and search_count < max_search do
        search_count = search_count + 1
        local current_belt = table.remove(queue, 1)
        
        if not current_belt or not current_belt.valid then
            goto continue
        end
        
        local pos_key = current_belt.position.x .. "," .. current_belt.position.y
        if visited[pos_key] then
            goto continue
        end
        visited[pos_key] = true
        
        -- Check if we reached the target
        local dx = math.abs(current_belt.position.x - end_pos.x)
        local dy = math.abs(current_belt.position.y - end_pos.y)
        if dx < 0.1 and dy < 0.1 then
            return true
        end
        
        -- Add neighboring belts to queue
        if current_belt.belt_neighbours then
            -- Add output belts
            if current_belt.belt_neighbours.outputs then
                for _, output_belt in pairs(current_belt.belt_neighbours.outputs) do
                    if output_belt and output_belt.valid then
                        table.insert(queue, output_belt)
                    end
                end
            end
            -- Add input belts  
            if current_belt.belt_neighbours.inputs then
                for _, input_belt in pairs(current_belt.belt_neighbours.inputs) do
                    if input_belt and input_belt.valid then
                        table.insert(queue, input_belt)
                    end
                end
            end
        end
        
        ::continue::
    end
    
    return false
end

-- Helper function to check if two positions are connected by electric poles
local function are_positions_pole_connected(start_pos, end_pos, connection_type)
    -- Find pole at start position - try multiple pole types if connection_type is nil
    local pole_types = {"small-electric-pole", "medium-electric-pole", "big-electric-pole", "substation"}
    if connection_type then
        pole_types = {connection_type}
    end
    
    local start_pole = nil
    for _, pole_type in ipairs(pole_types) do
        start_pole = game.surfaces[1].find_entity(pole_type, start_pos)
        if start_pole then
            break
        end
    end
    
    if not start_pole then
        return false
    end
    
    -- Use electric network ID for faster checking
    if start_pole.electric_network_id then
        local end_pole = nil
        for _, pole_type in ipairs(pole_types) do
            end_pole = game.surfaces[1].find_entity(pole_type, end_pos)
            if end_pole then
                break
            end
        end
        
        if end_pole and end_pole.electric_network_id then
            return start_pole.electric_network_id == end_pole.electric_network_id
        end
    end
    
    return false
end

-- Helper function to check if two positions are connected by pipes
local function are_positions_pipe_connected(start_pos, end_pos, connection_type)
    -- Find pipe at start position - try multiple pipe types if connection_type is nil
    local pipe_types = {"pipe", "pipe-to-ground"}
    if connection_type then
        pipe_types = {connection_type}
    end
    
    local start_pipe = nil
    for _, pipe_type in ipairs(pipe_types) do
        start_pipe = game.surfaces[1].find_entity(pipe_type, start_pos)
        if start_pipe then
            break
        end
    end
    
    if not start_pipe then
        return false
    end
    
    -- Use fluid system ID for checking pipe connections
    if has_valid_fluidbox(start_pipe) then
        local end_pipe = nil
        for _, pipe_type in ipairs(pipe_types) do
            end_pipe = game.surfaces[1].find_entity(pipe_type, end_pos)
            if end_pipe then
                break
            end
        end
        
        if end_pipe and has_valid_fluidbox(end_pipe) then
            -- Factorio 2.0: get_fluid_system_id -> get_fluid_segment_id
            return storage.fb(start_pipe).get_fluid_segment_id(1) == storage.fb(end_pipe).get_fluid_segment_id(1)
        end
    end

    return false
end

-- Helper function to serialize pipe group from a starting pipe using improved BFS
local function serialize_pipe_group(entity)
    if not entity or not entity.valid or (entity.type ~= "pipe" and entity.type ~= "pipe-to-ground") then
        return nil
    end

    if not has_valid_fluidbox(entity) then
        return nil
    end

    local serialized = {}
    local visited = {}
    local queue = {entity}
    local max_search = 200
    local search_count = 0
    -- Factorio 2.0: get_fluid_system_id -> get_fluid_segment_id
    local system_id = storage.fb(entity).get_fluid_segment_id(1)

    while #queue > 0 and search_count < max_search do
        search_count = search_count + 1
        local current_pipe = table.remove(queue, 1)

        if not current_pipe or not current_pipe.valid then
            goto continue
        end

        local pipe_id = current_pipe.unit_number
        if visited[pipe_id] then
            goto continue
        end
        visited[pipe_id] = true

        -- Serialize current pipe
        table.insert(serialized, storage.utils.serialize_entity(current_pipe))

        -- Find all connected pipes in the same fluid system
        local all_pipes = game.surfaces[1].find_entities_filtered{
            position = current_pipe.position,
            radius = 10,
            type = {"pipe", "pipe-to-ground"}
        }

        for _, pipe in pairs(all_pipes) do
            if pipe.valid and has_valid_fluidbox(pipe) and not visited[pipe.unit_number] then
                -- Factorio 2.0: get_fluid_system_id -> get_fluid_segment_id
                if storage.fb(pipe).get_fluid_segment_id(1) == system_id then
                    table.insert(queue, pipe)
                end
            end
        end
        
        ::continue::
    end
    
    return serialized
end

-- Helper function to serialize pole group from a starting pole using improved logic
local function serialize_pole_group(entity)
    if not entity or not entity.valid or entity.type ~= "electric-pole" then
        return nil
    end
    
    local serialized = {}
    local visited = {}
    
    if entity.electric_network_id then
        -- Find all poles in the same electric network within a reasonable search area
        -- This prevents searching the entire map for very large networks
        local search_areas = {
            {position = entity.position, radius = 50},  -- Close area first
            {position = entity.position, radius = 100}, -- Medium area if needed
        }
        
        local network_id = entity.electric_network_id
        
        for _, area in ipairs(search_areas) do
            local nearby_poles = game.surfaces[1].find_entities_filtered{
                position = area.position,
                radius = area.radius,
                type = "electric-pole"
            }
            
            for _, pole in pairs(nearby_poles) do
                if pole.valid and pole.electric_network_id == network_id then
                    local pole_id = pole.unit_number
                    if not visited[pole_id] then
                        visited[pole_id] = true
                        table.insert(serialized, storage.utils.serialize_entity(pole))
                    end
                end
            end
            
            -- If we found poles in the first area, we likely have the full local network
            if #serialized > 1 then
                break
            end
        end
    end
    
    return serialized
end

-- Function to validate belt connectivity
local function validate_belt_connectivity(path)
    if not path or #path < 2 then
        return false, "Invalid path length"
    end

    -- Check each segment of the path
    for i = 1, #path - 1 do
        local current_pos = path[i].position
        local next_pos = path[i + 1].position

        -- Check if positions are adjacent or properly spaced
        if not are_positions_adjacent(current_pos, next_pos) then
            return false, "Could not create a belt at position " ..
                   current_pos.x .. "," .. current_pos.y
        end

        -- Calculate directions for current and next position
        local current_dir = storage.utils.get_direction(current_pos, next_pos)
        local next_dir = i < #path - 1 and
                        storage.utils.get_direction(next_pos, path[i + 2].position) or
                        current_dir

        -- Check direction compatibility
        if not are_belt_directions_compatible(current_dir, next_dir, current_pos, next_pos) then
            return false, "Invalid belt turn detected at position " ..
                   current_pos.x .. "," .. current_pos.y
        end

        -- Check if position is placeable - BUT allow existing belts of the same type
        local entities_at_pos = game.surfaces[1].find_entities_filtered{
            position = current_pos,
            radius = 0.1
        }
        
        for _, existing_entity in pairs(entities_at_pos) do
            if existing_entity and existing_entity.valid then
                -- If there's already a belt of the same type, that's okay
                -- Also ignore character entities and resource entities (they don't block belt placement)
                if not existing_entity.name:find("belt") and 
                   existing_entity.name ~= "character" and
                   existing_entity.type ~= "resource" then
                    return false, "Cannot place belt at position " ..
                           current_pos.x .. "," .. current_pos.y .. " (blocked by " .. existing_entity.name .. ")"
                end
            end
        end
    end

    -- Check final position - same logic for existing belts
    local final_pos = path[#path].position
    local final_entities = game.surfaces[1].find_entities_filtered{
        position = final_pos,
        radius = 0.1
    }
    
    for _, existing_final in pairs(final_entities) do
        if existing_final and existing_final.valid then
            -- Ignore character entities, existing belts, and resource entities
            if not existing_final.name:find("belt") and 
               existing_final.name ~= "character" and
               existing_final.type ~= "resource" then
                return false, "Cannot place belt at final position (blocked by " .. existing_final.name .. ")"
            end
        end
    end

    return true, nil
end

-- Modify the connect_entities function to include validation
local function connect_entities_with_validation(player_index, source_x, source_y, target_x, target_y, path_handle, connection_types, dry_run)
    local path = storage.paths[path_handle]
    if path == nil then
        error("No path found")
    end
    
    -- Check for existing connections first
    
    for _,connection_type in pairs(connection_types) do
        if wire_reach[connection_type] then
            -- Check if positions are already connected by electric poles
            if are_positions_pole_connected(
                {x = source_x, y = source_y},
                {x = target_x, y = target_y},
                connection_type
            ) then
                -- Positions are already connected - return existing pole group
                local start_pole = nil
                local pole_types = {"small-electric-pole", "medium-electric-pole", "big-electric-pole", "substation"}
                for _, pole_type in ipairs(pole_types) do
                    start_pole = game.surfaces[1].find_entity(pole_type, {x = source_x, y = source_y})
                    if start_pole then
                        break
                    end
                end
                
                if start_pole then
                    local group_data = serialize_pole_group(start_pole)
                    if group_data then
                        return {
                            entities = group_data,
                            connected = true,
                            number_of_entities = 0
                        }
                    end
                end
                -- Fallback: return empty connection result (existing connection)
                return {
                    entities = {},
                    connected = true,
                    number_of_entities = 0
                }
            end
        elseif connection_type == "pipe" or connection_type == "pipe-to-ground" then
            -- Check if positions are already connected by pipes
            if are_positions_pipe_connected(
                {x = source_x, y = source_y},
                {x = target_x, y = target_y},
                connection_type
            ) then
                -- Positions are already connected - return existing pipe group
                local start_pipe = nil
                local pipe_types = {"pipe", "pipe-to-ground"}
                for _, pipe_type in ipairs(pipe_types) do
                    start_pipe = game.surfaces[1].find_entity(pipe_type, {x = source_x, y = source_y})
                    if start_pipe then
                        break
                    end
                end
                
                if start_pipe then
                    local group_data = serialize_pipe_group(start_pipe)
                    if group_data then
                        return {
                            entities = group_data,
                            connected = true,
                            number_of_entities = 0
                        }
                    end
                end
                -- Fallback: return empty connection result (existing connection)
                return {
                    entities = {},
                    connected = true,
                    number_of_entities = 0
                }
            end
        elseif connection_type:find("belt") then
            -- Check if positions are already FULLY connected by belts
            if are_positions_belt_connected(
                {x = source_x, y = source_y},
                {x = target_x, y = target_y},
                connection_type
            ) then
                -- Positions are already connected - return existing group
                
                -- Positions are already connected - return existing belt group
                local start_belt = game.surfaces[1].find_entity(connection_type, {x = source_x, y = source_y})
                if start_belt then
                    local group_data = serialize_belt_group(start_belt)
                    if group_data then
                        return {
                            entities = group_data,
                            connected = true,
                            number_of_entities = 0
                        }
                    end
                end
                -- Fallback: return empty connection result (existing connection)
                return {
                    entities = {},
                    connected = true,
                    number_of_entities = 0
                }
            end
            
            -- Normalize path first
            local normalized_path = storage.utils.normalise_path(path,
                    {x = source_x, y = source_y},
                    {x = target_x, y = target_y})

            -- Validate connectivity
            local is_valid, error_message = validate_belt_connectivity(normalized_path)
            if not is_valid then
                error(error_message)
            end
            break
        end
    end

    -- If validation passes or it's not a belt, proceed with normal connection
    return connect_entities(player_index, source_x, source_y, target_x, target_y,
                          path_handle, connection_types, dry_run)
end



-- ===================================================================================
-- Underground-aware router (pipes + pipe-to-ground, belts + underground belts).
--
-- The old route took a surface A* path and afterwards swapped straight runs for
-- underground pairs. That cannot cross obstacles (the surface path already went around
-- them) and it laid pairs with wrong directions / overlapping spans, so fluid never
-- arrived. This router searches the tile grid directly: from any tile the path can step
-- to a neighbour (a surface piece) or place an entrance and jump up to the prototype's
-- max underground distance in the travel direction, over anything, to a free exit tile.
-- After placement every pair is verified in game (pipes are flipped once if needed).
-- Called by storage.actions.connect_entities when path_handle < 0.
-- ===================================================================================

local UG_FALLBACK_RANGE = {
    ['pipe-to-ground'] = 10,
    ['underground-belt'] = 5,
    ['fast-underground-belt'] = 7,
    ['express-underground-belt'] = 9,
}
local UG_SURFACE = {
    ['pipe-to-ground'] = 'pipe',
    ['underground-belt'] = 'transport-belt',
    ['fast-underground-belt'] = 'fast-transport-belt',
    ['express-underground-belt'] = 'express-transport-belt',
}
local UG_IGNORE_TYPES = {
    ['resource'] = true, ['character'] = true, ['corpse'] = true, ['character-corpse'] = true,
    ['particle'] = true, ['projectile'] = true, ['fire'] = true, ['stream'] = true, ['beam'] = true,
    ['smoke-with-trigger'] = true, ['explosion'] = true, ['highlight-box'] = true,
    ['speech-bubble'] = true, ['sticker'] = true, ['item-request-proxy'] = true, ['item-entity'] = true,
}
local FLUID_TYPES = {
    ['pipe'] = true, ['pipe-to-ground'] = true, ['pump'] = true, ['offshore-pump'] = true,
    ['storage-tank'] = true,
}
-- N, E, S, W as {dx, dy, defines.direction}
local UG_DIRS = { {0, -1, 0}, {1, 0, 4}, {0, 1, 8}, {-1, 0, 12} }
local UG_OPP = {3, 4, 1, 2}

local function ug_max_distance(ug)
    local ok, d = pcall(function()
        local proto = prototypes.entity[ug]
        if ug == 'pipe-to-ground' then
            for _, fb in pairs(proto.fluidbox_prototypes) do
                for _, pc in pairs(fb.pipe_connections) do
                    if pc.connection_type == 'underground' and pc.max_underground_distance then
                        return pc.max_underground_distance
                    end
                end
            end
            return nil
        end
        return proto.max_underground_distance
    end)
    if ok and d and d > 1 then return d end
    return UG_FALLBACK_RANGE[ug] or 4
end


-- Tile occupancy shared by every route profile: false = blocked (water, out of map, any real
-- entity), "clear" = tree or rock (passable; the character mines it before placing), true = free.
local function route_tile_checker(surface)
    local cache = {}
    return function(x, y)
        local k = x .. "," .. y
        local v = cache[k]
        if v ~= nil then return v end
        v = true
        local tile = surface.get_tile(x, y)
        if not tile or not tile.valid then
            v = false
        else
            local ok, wet = pcall(function() return tile.collides_with("water_tile") end)
            if (ok and wet) or (not ok and string.find(tile.name, "water")) or tile.name == "out-of-map" then
                v = false
            end
        end
        if v then
            local ents = surface.find_entities_filtered{area = {{x - 0.45, y - 0.45}, {x + 0.45, y + 0.45}}}
            for _, e in pairs(ents) do
                if not UG_IGNORE_TYPES[e.type] then
                    if e.type == "tree" or (e.type == "simple-entity" and string.find(e.name, "rock")) then
                        v = "clear"
                    else
                        v = false
                        break
                    end
                end
            end
        end
        cache[k] = v
        return v
    end
end

local function route_clear_obstacles(player, surface, x, y)
    for _, obstacle in pairs(surface.find_entities_filtered{
            area = {{x - 0.45, y - 0.45}, {x + 0.45, y + 0.45}}, type = {"tree", "simple-entity"}}) do
        if obstacle.valid and (obstacle.type == "tree" or string.find(obstacle.name, "rock")) then
            if not player.mine_entity(obstacle, true) and obstacle.valid then obstacle.destroy() end
        end
    end
end

-- binary min-heap of {f, key}
local function heap_push(h, f, key)
    local n = #h + 1
    h[n] = {f, key}
    while n > 1 do
        local p = math.floor(n / 2)
        if h[p][1] <= h[n][1] then break end
        h[p], h[n] = h[n], h[p]
        n = p
    end
end
local function heap_pop(h)
    local top = h[1]
    local last = table.remove(h)
    if #h > 0 then
        h[1] = last
        local n, size = 1, #h
        while true do
            local l, r, m = 2 * n, 2 * n + 1, n
            if l <= size and h[l][1] < h[m][1] then m = l end
            if r <= size and h[r][1] < h[m][1] then m = r end
            if m == n then break end
            h[m], h[n] = h[n], h[m]
            n = m
        end
    end
    return top
end

local function ug_route(player_index, source_x, source_y, target_x, target_y, connection_types, dry_run, plan)
    local player = storage.agent_characters[player_index]
    local surface = player.surface
    -- profile: surface piece, optional underground piece (jumps up to its prototype range)
    local ug, surf = nil, nil
    for _, t in ipairs(connection_types) do
        if UG_SURFACE[t] then ug = t else surf = t end
    end
    surf = surf or UG_SURFACE[ug]
    local is_pipe = (surf == 'pipe')
    local maxd = ug and ug_max_distance(ug) or 0

    local sx, sy = math.floor(source_x) + 0.5, math.floor(source_y) + 0.5
    local tx, ty = math.floor(target_x) + 0.5, math.floor(target_y) + 0.5
    local function key(x, y) return x .. "," .. y end
    local skey, tkey = key(sx, sy), key(tx, ty)

    local tile_free = route_tile_checker(surface)
    for _, pt in ipairs({{sx, sy}, {tx, ty}}) do
        local tile = surface.get_tile(pt[1], pt[2])
        local ok, wet = pcall(function() return tile.collides_with("water_tile") end)
        if (ok and wet) or tile.name == "out-of-map" then
            error("\"Cannot route to/from (" .. pt[1] .. ", " .. pt[2] .. "): the tile is " .. tile.name .. "\"")
        end
    end
    local function passable(x, y)
        local k = key(x, y)
        return k == skey or k == tkey or tile_free(x, y) ~= false
    end
    local function clear_cost(x, y)
        return (tile_free(x, y) == "clear") and 3 or 0
    end

    -- pipes: a surface pipe next to a foreign fluid entity would join its network
    local adj_cache = {}
    local function fluid_penalty(x, y)
        if not is_pipe then return 0 end
        local k = key(x, y)
        if math.max(math.abs(x - sx), math.abs(y - sy)) <= 2 or math.max(math.abs(x - tx), math.abs(y - ty)) <= 2 then
            return 0
        end
        local v = adj_cache[k]
        if v ~= nil then return v end
        v = 0
        local ents = surface.find_entities_filtered{area = {{x - 1.4, y - 1.4}, {x + 1.4, y + 1.4}}}
        for _, e in pairs(ents) do
            if FLUID_TYPES[e.type] then
                local dx, dy = math.abs(e.position.x - x), math.abs(e.position.y - y)
                if (dx < 0.6 and dy < 1.6) or (dy < 0.6 and dx < 1.6) then v = 40 break end
            end
        end
        adj_cache[k] = v
        return v
    end

    -- belts: a tile that an existing belt points into would side-load that belt onto the new line
    local DIRV = {[0] = {0, -1}, [4] = {1, 0}, [8] = {0, 1}, [12] = {-1, 0}}
    local feed_cache = {}
    local function belt_penalty(x, y)
        if is_pipe then return 0 end
        if math.max(math.abs(x - sx), math.abs(y - sy)) <= 1 or math.max(math.abs(x - tx), math.abs(y - ty)) <= 1 then
            return 0
        end
        local k = key(x, y)
        local v = feed_cache[k]
        if v ~= nil then return v end
        v = 0
        for _, e in pairs(surface.find_entities_filtered{area = {{x - 1.5, y - 1.5}, {x + 1.5, y + 1.5}},
                                                         type = {"transport-belt", "underground-belt"}}) do
            local dv = DIRV[e.direction]
            local outputs = e.type == "transport-belt" or e.belt_to_ground_type == "output"
            if dv and outputs and math.abs(e.position.x + dv[1] - x) < 0.1 and math.abs(e.position.y + dv[2] - y) < 0.1 then
                v = 1000   -- effectively forbidden: it would merge two lines
                break
            end
        end
        feed_cache[k] = v
        return v
    end

    -- an underground of the same kind on the same axis between entrance and exit would steal the pairing
    local function span_clear(x, y, d, k2)
        local dx, dy, dir = UG_DIRS[d][1], UG_DIRS[d][2], UG_DIRS[d][3]
        for i = 1, k2 - 1 do
            local ents = surface.find_entities_filtered{position = {x + dx * i, y + dy * i}, name = ug}
            for _, e in pairs(ents) do
                if (e.direction % 8) == (dir % 8) then return false end
            end
        end
        return true
    end

    -- an entrance/exit placed within reach of a FOREIGN underground of the same kind on the same
    -- axis (e.g. inside another line's underground span) steals or joins its pairing and mixes
    -- the two lines: keep every new underground piece clear of them (both ways along the axis)
    local ug_ok_cache = {}
    local function ug_tile_ok(x, y, d)
        local axis = UG_DIRS[d][3] % 8
        local ck = x .. "," .. y .. "," .. axis
        local v = ug_ok_cache[ck]
        if v ~= nil then return v end
        v = true
        local dx, dy = UG_DIRS[d][1], UG_DIRS[d][2]
        for i = 1, maxd + 1 do
            for _, sgn in ipairs({1, -1}) do
                for _, e in pairs(surface.find_entities_filtered{position = {x + sgn * dx * i, y + sgn * dy * i}, name = ug}) do
                    if (e.direction % 8) == axis then v = false end
                end
            end
            if not v then break end
        end
        ug_ok_cache[ck] = v
        return v
    end

    local function jump_cost(k2)
        if is_pipe then return 2 + 0.3 * k2 end
        return 2 + k2   -- an underground hop costs about what its tiles would: preferred over detours
    end

    -- search box
    local margin = 40
    local minx, maxx = math.min(sx, tx) - margin, math.max(sx, tx) + margin
    local miny, maxy = math.min(sy, ty) - margin, math.max(sy, ty) + margin
    local function in_box(x, y) return x >= minx and x <= maxx and y >= miny and y <= maxy end
    -- Few turns: every turn costs TURN_COST tiles, and the heuristic adds the turns that are
    -- unavoidable (not lined up with the goal on either axis -> at least one more turn).
    local TURN_COST = 5
    local function h(x, y, a)
        local dx, dy = tx - x, ty - y
        local base = math.abs(dx) + math.abs(dy)
        if dx ~= 0 and dy ~= 0 then return base + TURN_COST end
        if a and a ~= 0 and base > 0 then
            -- lined up, but heading the wrong way still needs a turn
            local ux, uy = UG_DIRS[a][1], UG_DIRS[a][2]
            if ux * dx + uy * dy <= 0 then return base + TURN_COST end
        end
        return base
    end

    -- state: x, y, a (arrival dir 0..4, 0 = start), kind (0 surface tile, 1 underground exit)
    local function skey4(x, y, a, kind) return x .. "," .. y .. "," .. a .. "," .. kind end
    local states, g, parent, closed = {}, {}, {}, {}
    local open = {}
    local s0 = skey4(sx, sy, 0, 0)
    states[s0] = {sx, sy, 0, 0}
    g[s0] = 0
    heap_push(open, h(sx, sy, 0), s0)

    local function relax(from, x, y, a, kind, cost, move)
        local k = skey4(x, y, a, kind)
        if closed[k] then return end
        local ng = g[from] + cost
        if g[k] == nil or ng < g[k] then
            g[k] = ng
            states[k] = {x, y, a, kind}
            parent[k] = {from, move}
            heap_push(open, ng + h(x, y, a), k)
        end
    end

    -- fail fast when an end is walled in (a tiny free region around it and no way out); the
    -- full search would grind through 100k+ expansions in a packed base before giving up
    local function free_region(x0, y0, limit)
        local seen, q, n = {[x0 .. "," .. y0] = true}, {{x0, y0}}, 0
        while #q > 0 and n < limit do
            local c = table.remove(q)
            n = n + 1
            for d = 1, 4 do
                local nx, ny = c[1] + UG_DIRS[d][1], c[2] + UG_DIRS[d][2]
                local key = nx .. "," .. ny
                if not seen[key] and in_box(nx, ny) and (passable(nx, ny) or (nx == sx and ny == sy) or (nx == tx and ny == ty)) then
                    seen[key] = true
                    q[#q + 1] = {nx, ny}
                end
            end
        end
        return n
    end
    for _, e in ipairs({{tx, ty, "target"}, {sx, sy, "start"}}) do
        local n = free_region(e[1], e[2], 8)
        if n < (ug and 2 or 4) then   -- with undergrounds an end needs at least one free neighbour
            error("\"Failed to find a path (router) from (" .. sx .. ", " .. sy .. ") to (" .. tx .. ", " .. ty ..
                  ") after 0 expansions: the " .. e[3] .. " is walled in (" .. n .. " free tiles around it)\"")
        end
    end

    local goal = nil
    local expansions, MAX_EXPANSIONS = 0, 150000
    while #open > 0 do
        local top = heap_pop(open)
        local cur = top[2]
        if not closed[cur] then
            closed[cur] = true
            expansions = expansions + 1
            if expansions > MAX_EXPANSIONS then break end
            local st = states[cur]
            local x, y, a, kind = st[1], st[2], st[3], st[4]
            if kind == 0 and x == tx and y == ty then goal = cur break end
            if kind == 1 then
                local nx, ny = x + UG_DIRS[a][1], y + UG_DIRS[a][2]
                if in_box(nx, ny) and passable(nx, ny) then
                    relax(cur, nx, ny, a, 0, 1 + fluid_penalty(nx, ny) + belt_penalty(nx, ny) + clear_cost(nx, ny), 'surface')
                end
            else
                for d = 1, 4 do
                    if a == 0 or d ~= UG_OPP[a] then
                        local nx, ny = x + UG_DIRS[d][1], y + UG_DIRS[d][2]
                        if in_box(nx, ny) and passable(nx, ny) then
                            local turn = (a ~= 0 and d ~= a) and TURN_COST or 0
                            relax(cur, nx, ny, d, 0, 1 + turn + fluid_penalty(nx, ny) + belt_penalty(nx, ny) + clear_cost(nx, ny), 'surface')
                        end
                    end
                end
                -- entrance here (not on the start or goal tile: those must be surface pieces)
                if ug and a ~= 0 and not (x == sx and y == sy) and not (x == tx and y == ty) then
                    local dx, dy = UG_DIRS[a][1], UG_DIRS[a][2]
                    for k2 = 2, maxd do
                        local ex, ey = x + dx * k2, y + dy * k2
                        if not in_box(ex, ey) then break end
                        if not (ex == tx and ey == ty) and not (ex == sx and ey == sy) and tile_free(ex, ey) ~= false
                           and span_clear(x, y, a, k2) and (is_pipe or (ug_tile_ok(x, y, a) and ug_tile_ok(ex, ey, a))) then
                            relax(cur, ex, ey, a, 1, jump_cost(k2) + clear_cost(ex, ey), 'jump')
                        end
                    end
                end
            end
        end
    end
    if not goal then
        error("\"Failed to find a path (router) from (" .. sx .. ", " .. sy .. ") to (" ..
              tx .. ", " .. ty .. ") after " .. expansions .. " expansions\"")
    end

    -- rebuild: list of states from start to goal, with the move that left each one
    local chain = {}
    local k = goal
    while k do
        table.insert(chain, 1, k)
        k = parent[k] and parent[k][1] or nil
    end
    local pieces = {}
    for i, sk in ipairs(chain) do
        local st = states[sk]
        local x, y, a, kind = st[1], st[2], st[3], st[4]
        local nxt = chain[i + 1]
        local move_out = nxt and parent[nxt][2] or nil
        local out_dir = nxt and states[nxt][3] or a
        if out_dir == 0 then out_dir = 1 end
        if kind == 1 then
            local dir = UG_DIRS[a][3]
            table.insert(pieces, {x = x, y = y, name = ug, role = 'exit',
                                  dir = dir})
        elseif move_out == 'jump' then
            local dir = UG_DIRS[a][3]
            if is_pipe then dir = UG_DIRS[UG_OPP[a]][3] end   -- a pipe-to-ground faces its above-ground side
            table.insert(pieces, {x = x, y = y, name = ug, role = 'entrance', dir = dir})
        else
            table.insert(pieces, {x = x, y = y, name = surf, role = 'surface',
                                  dir = is_pipe and 0 or UG_DIRS[out_dir][3]})
        end
    end

    -- what actually needs placing (start/goal may already hold our piece, or be inside an entity)
    local need = {}
    local to_place = {}
    for _, p in ipairs(pieces) do
        local pk = key(p.x, p.y)
        local existing = surface.find_entities_filtered{position = {p.x, p.y}, name = p.name}
        if #existing > 0 then
            p.existing = existing[1]
        elseif (pk == skey or pk == tkey) and tile_free(p.x, p.y) == false then
            p.skip = true
        else
            need[p.name] = (need[p.name] or 0) + 1
            table.insert(to_place, p)
        end
    end
    local total = #to_place

    if plan then   -- the planned pieces, nothing placed
        local out = {}
        for _, p in ipairs(pieces) do
            out[#out + 1] = {x = p.x, y = p.y, d = p.dir, n = p.name, r = p.role, e = p.existing and true or nil}
        end
        return out
    end
    if dry_run then
        return {entities = {}, connected = true, number_of_entities = total}
    end

    for name, n in pairs(need) do
        local have = player.get_item_count(name)
        if have < n then
            error("\"You do not have enough " .. name .. " in you inventory to complete this connection. Required number - " ..
                  n .. ", Available in inventory - " .. have .. "\"")
        end
    end

    -- walking time, like the old router
    local last = player.position
    for _, p in ipairs(pieces) do
        storage.elapsed_ticks = storage.elapsed_ticks + storage.utils.calculate_movement_ticks(player, last, {x = p.x, y = p.y})
        last = {x = p.x, y = p.y}
    end

    local placed = {}
    local counter = 0
    for _, p in ipairs(pieces) do
        if p.existing then
            p.entity = p.existing
        elseif not p.skip then
            player.teleport({p.x + 2, p.y + 2})
            route_clear_obstacles(player, surface, p.x, p.y)
            local spec = {name = p.name, position = {p.x, p.y}, direction = p.dir, force = player.force,
                          move_stuck_players = true}
            if p.name == ug and not is_pipe then
                spec.type = (p.role == 'entrance') and 'input' or 'output'
            end
            if not surface.can_place_entity{name = p.name, position = {p.x, p.y}, direction = p.dir, force = player.force} then
                error("\"Cannot connect due to placement blockage at (" .. p.x .. ", " .. p.y .. ") for " .. p.name ..
                      " (placed " .. counter .. " of " .. total .. ")\"")
            end
            local e = surface.create_entity(spec)
            if not e then
                error("\"create_entity failed for " .. p.name .. " at (" .. p.x .. ", " .. p.y .. ")\"")
            end
            player.remove_item({name = p.name, count = 1})
            counter = counter + 1
            p.entity = e
            table.insert(placed, e)
        end
    end

    -- verify every underground pair; pipes get one flip of both ends if the guess was wrong
    local function paired(a, b)
        if not (a and b and a.valid and b.valid) then return false end
        if a.type == 'underground-belt' then return storage.neighbours(a) == b end
        local ok, nb = pcall(function() return storage.neighbours(a) end)
        if not ok or not nb then return false end
        for _, group in pairs(nb) do
            if type(group) == 'table' then
                for _, e in pairs(group) do if e == b then return true end end
            elseif group == b then
                return true
            end
        end
        return false
    end
    local bad = 0
    for i, p in ipairs(pieces) do
        if p.role == 'entrance' then
            local q = pieces[i + 1]
            local ok = paired(p.entity, q and q.entity)
            if not ok and is_pipe and p.entity and q and q.entity then
                p.entity.direction = (p.entity.direction + 8) % 16
                q.entity.direction = (q.entity.direction + 8) % 16
                ok = paired(p.entity, q.entity)
                if not ok then
                    p.entity.direction = (p.entity.direction + 8) % 16
                    q.entity.direction = (q.entity.direction + 8) % 16
                end
            end
            if not ok then bad = bad + 1 end
        end
    end

    local connected = (bad == 0)
    if is_pipe and connected then
        local first, lastp = nil, nil
        for _, p in ipairs(pieces) do
            if p.entity and p.entity.valid then
                first = first or p.entity
                lastp = p.entity
            end
        end
        if first and lastp then
            local ok, same = pcall(function()
                return storage.fb(first).get_fluid_segment_id(1) == storage.fb(lastp).get_fluid_segment_id(1)
            end)
            if ok then connected = same end
        end
    end
    if bad > 0 then
        error("\"Underground router: " .. bad .. " underground pair(s) did not link after placement\"")
    end

    local serialized = {}
    if not is_pipe and #placed > 0 then
        local group = serialize_belt_group(placed[1])
        if group then serialized = group end
    end
    if #serialized == 0 then
        for _, p in ipairs(pieces) do
            if p.entity and p.entity.valid then
                table.insert(serialized, storage.utils.serialize_entity(p.entity))
            end
        end
    end
    return {entities = serialized, connected = connected, number_of_entities = counter}
end


-- ===================================================================================
-- Pole profile: the same A* over tiles, but every move is a hop of up to the pole's wire
-- reach (no surface pieces). A route starts at the source pole (or, for a non-pole source,
-- within the supply area of it) and ends when a pole reaches the target pole by wire, or
-- covers the target entity with its supply area. Fewest poles first.
-- ===================================================================================
local function pole_route(player_index, source_x, source_y, target_x, target_y, pole, dry_run)
    local player = storage.agent_characters[player_index]
    local surface = player.surface
    local proto = prototypes.entity[pole]
    local reach = 7.5
    pcall(function() reach = proto.get_max_wire_distance() end)
    if not reach or reach <= 0 then pcall(function() reach = proto.max_wire_distance end) end
    local supply = 2.5
    pcall(function() supply = proto.get_supply_area_distance() end)
    if not supply then pcall(function() supply = proto.supply_area_distance end) end
    local tile_free = route_tile_checker(surface)

    local function pole_at(x, y)
        local ps = surface.find_entities_filtered{position = {x, y}, radius = 0.6, type = "electric-pole"}
        return ps[1]
    end
    local src_pole, tgt_pole = pole_at(source_x, source_y), pole_at(target_x, target_y)
    if src_pole and tgt_pole and src_pole.electric_network_id == tgt_pole.electric_network_id then
        return {entities = {}, connected = true, number_of_entities = 0}
    end
    local tgt_ent = nil
    if not tgt_pole then
        for _, e in pairs(surface.find_entities_filtered{position = {target_x, target_y}, radius = 0.6}) do
            if not UG_IGNORE_TYPES[e.type] then tgt_ent = e break end
        end
    end
    -- half size of the target entity (supply area must touch it)
    local thw, thh = 0.5, 0.5
    if tgt_ent then
        local bb = tgt_ent.bounding_box
        thw = (bb.right_bottom.x - bb.left_top.x) / 2
        thh = (bb.right_bottom.y - bb.left_top.y) / 2
    end
    local function dist(ax, ay, bx, by) return math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2) end
    local function at_goal(x, y)
        if tgt_pole then return dist(x, y, tgt_pole.position.x, tgt_pole.position.y) <= reach end
        return math.abs(x - target_x) < supply + thw and math.abs(y - target_y) < supply + thh
    end
    local goal_r = tgt_pole and reach or supply
    local function h(x, y)
        local d = dist(x, y, target_x, target_y) - goal_r
        if d <= 0 then return 0 end
        return math.ceil(d / reach)
    end
    -- first hop: within wire reach of the source pole, else within the supply area of the source
    local first_limit_ok
    if src_pole then
        first_limit_ok = function(x, y) return dist(x, y, src_pole.position.x, src_pole.position.y) <= reach end
    else
        local shw, shh = 0.5, 0.5
        for _, e in pairs(surface.find_entities_filtered{position = {source_x, source_y}, radius = 0.6}) do
            if not UG_IGNORE_TYPES[e.type] then
                local bb = e.bounding_box
                shw = (bb.right_bottom.x - bb.left_top.x) / 2
                shh = (bb.right_bottom.y - bb.left_top.y) / 2
                break
            end
        end
        first_limit_ok = function(x, y)
            return math.abs(x - source_x) < supply + shw and math.abs(y - source_y) < supply + shh
        end
    end
    local margin = 30
    local minx, maxx = math.min(source_x, target_x) - margin, math.max(source_x, target_x) + margin
    local miny, maxy = math.min(source_y, target_y) - margin, math.max(source_y, target_y) + margin

    local function candidates(x, y, first)
        local out = {}
        local R = math.floor(first and (supply + 2) or reach)
        for dx = -R, R do
            for dy = -R, R do
                local d = math.sqrt(dx * dx + dy * dy)
                -- far ring (progress) plus the line towards the target
                if d >= R - 2.5 and d <= R + 0.01 then table.insert(out, {x + dx, y + dy}) end
            end
        end
        local d = dist(x, y, target_x, target_y)
        if d > 0 then
            for step = 1, R do
                table.insert(out, {math.floor(x + (target_x - x) * step / d) + 0.5,
                                   math.floor(y + (target_y - y) * step / d) + 0.5})
            end
        end
        local ok = {}
        for _, c in pairs(out) do
            local cx, cy = c[1], c[2]
            if cx >= minx and cx <= maxx and cy >= miny and cy <= maxy and tile_free(cx, cy) ~= false then
                if first then
                    if first_limit_ok(cx, cy) then table.insert(ok, c) end
                elseif dist(x, y, cx, cy) <= reach then
                    table.insert(ok, c)
                end
            end
        end
        return ok
    end

    local g, parent, closed, open = {}, {}, {}, {}
    local START = "start"
    local pos = {[START] = {math.floor(source_x) + 0.5, math.floor(source_y) + 0.5}}
    g[START] = 0
    heap_push(open, 0, START)
    local goal, expansions = nil, 0
    while #open > 0 do
        local cur = heap_pop(open)[2]
        if not closed[cur] then
            closed[cur] = true
            expansions = expansions + 1
            if expansions > 20000 then break end
            local x, y = pos[cur][1], pos[cur][2]
            if cur ~= START and at_goal(x, y) then goal = cur break end
            for _, c in pairs(candidates(x, y, cur == START)) do
                local k = c[1] .. "," .. c[2]
                if not closed[k] then
                    local ng = g[cur] + 1 + ((tile_free(c[1], c[2]) == "clear") and 0.3 or 0)
                                 + 0.001 * dist(c[1], c[2], target_x, target_y)
                    if g[k] == nil or ng < g[k] then
                        g[k] = ng
                        pos[k] = c
                        parent[k] = cur
                        heap_push(open, ng + h(c[1], c[2]), k)
                    end
                end
            end
        end
    end
    if not goal then
        error("\"Failed to find a pole route from (" .. source_x .. ", " .. source_y .. ") to (" ..
              target_x .. ", " .. target_y .. ") after " .. expansions .. " expansions\"")
    end
    local chain = {}
    local k = goal
    while k and k ~= START do table.insert(chain, 1, pos[k]); k = parent[k] end
    if dry_run then return {entities = {}, connected = true, number_of_entities = #chain} end
    local have = player.get_item_count(pole)
    if have < #chain then
        error("\"You do not have enough " .. pole .. " in you inventory to complete this connection. Required number - " ..
              #chain .. ", Available in inventory - " .. have .. "\"")
    end
    local last = player.position
    for _, c in ipairs(chain) do
        storage.elapsed_ticks = storage.elapsed_ticks + storage.utils.calculate_movement_ticks(player, last, {x = c[1], y = c[2]})
        last = {x = c[1], y = c[2]}
    end
    local function wire(a, b)
        if not (a and b and a.valid and b.valid) then return end
        pcall(function()
            local ca = a.get_wire_connector(defines.wire_connector_id.pole_copper, true)
            local cb = b.get_wire_connector(defines.wire_connector_id.pole_copper, true)
            ca.connect_to(cb, false)
        end)
    end
    local prev = src_pole
    local placed, out = {}, {}
    for _, c in ipairs(chain) do
        player.teleport({c[1] + 2, c[2] + 2})
        route_clear_obstacles(player, surface, c[1], c[2])
        if not surface.can_place_entity{name = pole, position = c, force = player.force} then
            error("\"Cannot connect due to placement blockage at (" .. c[1] .. ", " .. c[2] .. ") for " .. pole .. "\"")
        end
        local e = surface.create_entity{name = pole, position = c, force = player.force, move_stuck_players = true}
        if not e then error("\"create_entity failed for " .. pole .. "\"") end
        player.remove_item({name = pole, count = 1})
        wire(prev, e)
        prev = e
        table.insert(placed, e)
        table.insert(out, storage.utils.serialize_entity(e))
    end
    wire(prev, tgt_pole)
    return {entities = out, connected = true, number_of_entities = #placed}
end

-- Using the new shortest_path function.
storage.actions.connect_entities = function(player_index, source_x, source_y, target_x, target_y, path_handle, connection_type_string, dry_run, number_of_connection_entities)

    local connection_types = {}
    for item in string.gmatch(connection_type_string, "([^,]+)") do
        -- game.print(item)
        table.insert(connection_types, item)
    end
    -- path_handle < 0: the underground-aware router does its own search (see ug_route)
    -- path_handle < 0: the tile router does its own search (ug_route: pipes and belts with
    -- optional undergrounds, -1; pole_route: poles, -2)
    if tonumber(path_handle) and tonumber(path_handle) == -2 then
        return pole_route(player_index, source_x, source_y, target_x, target_y, connection_types[1], dry_run)
    end
    if tonumber(path_handle) and tonumber(path_handle) < 0 then
        return ug_route(player_index, source_x, source_y, target_x, target_y, connection_types, dry_run)
    end
    --First do a dry run
    local result = connect_entities_with_validation(player_index, source_x, source_y, target_x, target_y, path_handle, connection_types, true)
    -- then do an actual run if dry run is false
    if not dry_run then
        -- Check if the player has enough entities in their inventory
        local required_count = result.number_of_entities
        -- game.print("Required count: " .. required_count)
        -- game.print("Available count: " .. number_of_connection_entities)
        if number_of_connection_entities < required_count then
            error("\"You do not have enough " .. connection_type_string .. " in you inventory to complete this connection. Required number - " .. required_count .. ", Available in inventory - " .. number_of_connection_entities.."\"")
        end
        result = connect_entities_with_validation(player_index, source_x, source_y, target_x, target_y, path_handle, connection_types, false)
    end

    return result
end


-- route planning without placing (belt_link plans every leg first): pieces [{x, y, d, n, r (role), e (exists)}]
storage.route_plan = function(player_index, sx, sy, tx, ty, types_csv)
    local types = {}
    for item in string.gmatch(types_csv, "([^,]+)") do table.insert(types, item) end
    return ug_route(player_index, sx, sy, tx, ty, types, true, true)
end
