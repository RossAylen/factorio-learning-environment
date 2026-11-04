# auto_research

`auto_research(names=None)` sets the research priority list and refills the game research queue. The game keeps the queue at >= 3 entries by itself (on research finished and every 600 ticks): the priority list first, then techs whose packs were produced in the last 10 minutes, cheapest first. play_lib.research_next() uses it.
