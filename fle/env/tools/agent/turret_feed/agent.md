# turret_feed

`turret_feed(area=None, low=1, limit=40)` explains why turrets are (nearly) out of ammo: for each turret with fewer than `low` magazines it gives the inserter that feeds it, the inserter's status, and the ammo on its pickup. Reasons: no_inserter, inserter_unpowered, inserter_no_fuel, inserter_disabled, inserter_picks_from_nothing, chest_empty, belt_empty, feeding. play_lib.defence_check(explain=True) and ammo_doctor() build on it.
