# can_build

`can_build(entities, limit=30)` checks a whole plan in one read: for each {"name", "x", "y", "d"} (absolute centre, real game direction) can it be placed, and if not, what is in the way (entity names/positions, trees, rocks, water tiles). Same entity already there counts as ok. play_lib.fits(bp, origin) and grow() build on it.
