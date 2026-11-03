# events

`events(drain=True)` returns what happened since the last call: our entities destroyed (with name/position/direction/underground type/recipe to rebuild them), damaged, research finished, enemy attack groups formed, enemy structures killed. play_lib.pulse() reacts to them; every sleep in play_lib runs pulse() in between.
