-- walk_memory: the route the character last walked (move_to remembers it) - read it, or walk
-- back along it. op "last" -> sampled points; op "back" -> points queued for walking back.
storage.actions.walk_memory = function(player_index, op, n)
    if op == "back" then return storage.actions.walk_back(player_index, n) end
    return storage.actions.last_path(player_index, n)
end
