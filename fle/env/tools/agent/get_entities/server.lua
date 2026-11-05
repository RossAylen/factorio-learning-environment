storage.actions.get_entities = function(player_index, radius, entity_names_json, position_x, position_y)
    -- Ensure we have a valid character, recreating if necessary
    local player = storage.utils.ensure_valid_character(player_index)

    local position
    if position_x and position_y then
        position = {x = tonumber(position_x), y = tonumber(position_y)}
    else
        position = player.position
    end

    radius = tonumber(radius) or 5
    local entity_names = helpers.json_to_table(entity_names_json) or {}
    local area = {
        {position.x - radius, position.y - radius},
        {position.x + radius, position.y + radius}
    }

    local filter = {}
    if entity_names and #entity_names > 0 then
        filter = {name = entity_names}
    end

    local entities

    if #entity_names > 0 then
        -- name = ..., not filter = {...}: find_entities_filtered has no 'filter' key, so every
        -- entity in the area was serialised and the client threw most away (85 s for "labs, r=150")
        local valid = {}
        for _, n in ipairs(entity_names) do if prototypes.entity[n] then valid[#valid + 1] = n end end
        if #valid == 0 then return dump({}) end
        entities = player.surface.find_entities_filtered{area = area, force = player.force, name = valid}
    else
        entities = player.surface.find_entities_filtered{area = area, force = player.force}
    end

    local result = {}
    for _, entity in ipairs(entities) do
        -- Wrap the entire entity processing in pcall to catch any LuaEntity invalid errors
        local process_success, process_error = pcall(function()
            -- Double-check validity right before accessing any properties
            if not entity.valid then
                return -- Skip silently
            end

            -- Cache the name check separately to avoid race conditions
            local entity_name = entity.name
            if entity_name == 'character' then
                return -- Skip character entities
            end

            -- Now serialize the entity
            local success, serialized = pcall(function()
                -- Final validity check before serialization
                if not entity.valid then
                    return nil
                end
                return storage.utils.serialize_entity(entity)
            end)

            if success and serialized then
                table.insert(result, serialized)
            end
            -- Silently skip failed entities instead of printing warnings
        end)
        -- Silently continue on any error - don't let one bad entity break the whole call
    end
    return dump(result)
end