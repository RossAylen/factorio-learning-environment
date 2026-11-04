# set_research_queue

`set_research_queue(names)` hands the game a research queue (up to 7). When a tech finishes, the game starts the next one by itself, with no script awake. Already-researched techs are dropped; not-enabled, trigger techs and techs with unmet prerequisites are skipped with a reason. Returns {"queue", "current", "skipped", "error"}. play_lib.research_next() uses it.
