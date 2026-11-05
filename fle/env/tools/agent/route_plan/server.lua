-- route_plan: the belt/pipe router's plan from A to B, nothing placed (see connect_entities ug_route)
storage.actions.route_plan = function(player_index, sx, sy, tx, ty, types_csv)
    local ok, res = pcall(storage.route_plan, player_index, tonumber(sx), tonumber(sy), tonumber(tx), tonumber(ty), types_csv)
    local out = ok and {ok = true, pieces = res} or {ok = false, error = tostring(res)}
    local j = helpers.table_to_json(out)
    return "RPHEX_" .. (j:gsub(".", function(ch) return string.format("%02x", ch:byte()) end))
end
