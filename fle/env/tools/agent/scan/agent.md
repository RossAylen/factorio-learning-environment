# scan

`scan(names, position=None, radius=300)` is a lean read of our entities by name: position, status, chest contents, furnace output, turret ammo, fuel, drill drop tile. Milliseconds where get_entities over a big area takes seconds. play_lib helpers (fetch, collect_all, refuel, maintain, depots, poles, defence_check) use it.
