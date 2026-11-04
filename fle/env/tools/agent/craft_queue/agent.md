# craft_queue

`craft_queue()` reads the character's hand-crafting queue: {"size", "items": {recipe: count}}. In slow (real-time) mode craft_item can return before the items exist; play_lib.wait_crafted() polls this.
