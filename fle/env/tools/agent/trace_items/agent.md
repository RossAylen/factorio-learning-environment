# trace_items

`trace_items(source, target)` checks whether items can travel from `source` to `target`
the way the game has things connected: belts (direction, head-on blocks), underground belt pairs
(the real in-game pairing), splitters, inserter pickup/drop targets and mining-drill drops.

```python
t = trace_items(iron_drill, furnace)
if not t:
    print(t.dead_ends)   # e.g. "underground-belt@(3.5,41.5)[input] has no exit (unpaired)"
print(t.path)            # drill drop -> belts -> inserter pickup -> inserter drop -> furnace
```

Returns an `ItemTrace` (truthy when connected) with `path`, `dead_ends`, `reached` (machines the
items can get to), `items_on_belts` (what is on the traced belts now). Lanes are not modelled.
