# restore_entities

`restore_entities(plan)` re-places missing entities from a plan list ({"n","x","y","d","t","r"}) with items from the inventory and reports what is still short. The runner snapshots the base at every checkpoint (checkpoints/NN.plan.json); play_lib.rebuild() uses it.
