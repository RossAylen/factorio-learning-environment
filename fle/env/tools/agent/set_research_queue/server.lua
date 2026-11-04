-- set_research_queue: hand the game a research queue (Factorio 2.x keeps researching the next
-- entry by itself when one finishes, with no script awake). Techs already researched, not
-- enabled, trigger techs (researched by doing something, not by labs) and techs whose
-- prerequisites are neither researched nor earlier in the queue are skipped with a reason.
storage.actions.set_research_queue = function(player_index, names_hex)
    local player = storage.agent_characters[player_index]
    local force = player.force
    local function unhex(h) return (h:gsub("%x%x", function(c) return string.char(tonumber(c, 16)) end)) end
    local names = helpers.json_to_table(unhex(names_hex)) or {}
    local q, inq, skipped = {}, {}, {}
    for _, name in ipairs(names) do
        local tech = force.technologies[name]
        local why = nil
        if not tech then why = "unknown"
        elseif tech.researched then why = nil  -- done: silently dropped
        elseif not tech.enabled then why = "not enabled"
        else
            local trig = nil
            pcall(function() trig = tech.prototype.research_trigger end)
            if trig then why = "trigger tech (" .. tostring(trig.type) .. "): do it, labs cannot" end
            if not why then
                local miss = {}
                for _, pre in pairs(tech.prerequisites or {}) do
                    if not pre.researched and not inq[pre.name] then table.insert(miss, pre.name) end
                end
                if #miss > 0 then why = "needs " .. table.concat(miss, ", ") end
            end
        end
        if tech and not tech.researched then
            if why then table.insert(skipped, {name = name, why = why})
            elseif #q < 7 then table.insert(q, name) inq[name] = true end
        end
    end
    local ok, err = pcall(function() force.research_queue = q end)
    local now = {}
    pcall(function() for _, t in pairs(force.research_queue or {}) do table.insert(now, t.name) end end)
    local out = {queue = now, skipped = skipped, current = force.current_research and force.current_research.name or "",
                 error = (not ok) and tostring(err) or ""}
    local j = helpers.table_to_json(out)
    return "RQHEX_" .. (j:gsub(".", function(ch) return string.format("%02x", ch:byte()) end))
end
