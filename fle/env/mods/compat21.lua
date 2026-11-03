--- compat21.lua
--- Compatibility shims so FLE runs on Factorio 2.0 and 2.1 alike. Loaded right after
--- lualib_util, before every other init script and tool.
---
--- 2.1 removed LuaEntity::fluidbox / LuaFluidBox (fluid access moved onto LuaEntity),
--- LuaEntity::neighbours (split into fluidbox_neighbours, underground_belt_neighbour, ...),
--- the furnace_/assembling_machine_/rocket_silo_ inventory defines (now crafter_*),
--- LuaEntity::active writes (disabled_by_script) and recipe category (categories).

storage.is_factorio_21 = (defines.inventory.crafter_input ~= nil)

-- Inventory defines by their 2.0 names; resolves to the 2.1 crafter_* ids when needed.
local INV_ALIASES = {
    furnace_source = "crafter_input", assembling_machine_input = "crafter_input",
    rocket_silo_input = "crafter_input",
    furnace_result = "crafter_output", assembling_machine_output = "crafter_output",
    rocket_silo_output = "crafter_output",
    furnace_modules = "crafter_modules", assembling_machine_modules = "crafter_modules",
    rocket_silo_modules = "crafter_modules",
    furnace_trash = "crafter_trash", assembling_machine_trash = "crafter_trash",
}
storage.INV = setmetatable({}, {
    __index = function(_, key)
        local id = defines.inventory[key]
        if id == nil and INV_ALIASES[key] then id = defines.inventory[INV_ALIASES[key]] end
        return id
    end,
})

-- LuaFluidBox stand-in for 2.1, built on the LuaEntity fluid methods.
local function fluidbox_proxy(e)
    local proxy = {owner = e, valid = true}
    proxy.get_fluid_segment_id = function(i) return e.get_fluid_segment_id(i) end
    proxy.get_fluid_system_id = proxy.get_fluid_segment_id
    proxy.get_pipe_connections = function(i) return e.get_fluid_box_pipe_connections(i) end
    proxy.get_capacity = function(i) return e.get_fluid_capacity(i) end
    proxy.get_prototype = function(i) return e.get_fluid_box_prototype(i) end
    proxy.get_connections = function(i)
        local out = {}
        for _, rec in pairs(e.get_fluid_box_neighbours(i) or {}) do
            if rec.entity and rec.entity.valid then
                table.insert(out, {owner = rec.entity, index = rec.index, position = rec.entity.position})
            end
        end
        return out
    end
    proxy.get_fluid_segment_contents = function(i)
        local f = e.get_fluid_segment_fluid(i)
        if f then return {[f.name] = f.amount} end
        return {}
    end
    proxy.get_filter = function(i)
        local p = e.get_fluid_filter(i)
        if p then return {name = p.name} end
        return nil
    end
    proxy.set_filter = function(i, filter)
        local name = filter
        if type(filter) == "table" then name = filter.name end
        return e.set_fluid_filter(name, i)
    end
    return setmetatable(proxy, {
        __len = function() return e.fluids_count or 0 end,
        __index = function(_, k)
            if type(k) == "number" then return e.get_fluid(k) end
            return nil
        end,
        __newindex = function(t, k, v)
            if type(k) == "number" then
                if v then e.set_fluid(v, k) else e.clear_fluid(k) end
            else
                rawset(t, k, v)
            end
        end,
    })
end

--- entity.fluidbox on 2.0; an equivalent proxy on 2.1.
storage.fb = function(e)
    if not e or not e.valid then return nil end
    if not storage.is_factorio_21 then return e.fluidbox end
    return fluidbox_proxy(e)
end

--- entity.neighbours on 2.0; the matching 2.1 split-out read otherwise.
storage.neighbours = function(e)
    if not e or not e.valid then return nil end
    if not storage.is_factorio_21 then return e.neighbours end
    local t = e.type
    if t == "underground-belt" then return e.underground_belt_neighbour end
    if t == "linked-belt" then return e.linked_belt_neighbour end
    if t == "wall" or t == "gate" then return e.wall_neighbours end
    if t == "cliff" then return e.cliff_neighbours end
    if t == "heat-pipe" or t == "reactor" or t == "heat-interface" then return e.heat_neighbours end
    if (e.fluids_count or 0) > 0 then return e.fluidbox_neighbours end
    return nil
end

--- Recipe categories as a list (2.0: {category} plus additional_categories).
storage.recipe_categories = function(recipe)
    local ok, cats = pcall(function() return recipe.categories end)
    if ok and cats then return cats end
    local out = {recipe.category}
    local ok2, extra = pcall(function() return recipe.additional_categories end)
    if ok2 and extra then for _, c in pairs(extra) do table.insert(out, c) end end
    return out
end

--- First recipe category (for messages and single-category checks).
storage.recipe_category = function(recipe)
    return storage.recipe_categories(recipe)[1]
end

--- entity.active = flag (2.0) / entity.disabled_by_script = not flag (2.1).
storage.set_active = function(e, flag)
    if storage.is_factorio_21 then
        e.disabled_by_script = not flag
    else
        e.active = flag
    end
end

--- fixed_recipe as a name (2.1 returns a LuaRecipePrototype).
storage.recipe_name = function(r)
    if r == nil then return nil end
    if type(r) == "string" then return r end
    return r.name
end
