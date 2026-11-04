# ore_sites

`ore_sites(resource, w, h, x, y, drills, radius=40, trees_ok=False, limit=8)` scans a field once and returns integer origins (nearest first) where a w x h mining layout fits with every drill's mining area on pure `resource` and nothing in the way, plus counts of rejected origins by reason. play_lib.mine_row/place_mine use it before trying to build.
