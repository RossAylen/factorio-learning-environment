import json
from typing import Any, Dict

from fle.env.tools import Tool


class CraftQueue(Tool):
    def __init__(self, *args):
        super().__init__(*args)

    def __call__(self) -> Dict[str, Any]:
        """
        The character's hand-crafting queue. In slow (real-time) mode craft_item returns before
        long crafts finish; this says what is still being made.
        :return: {"size": n queue entries, "items": {recipe name: count still to craft}}
        """
        response, _ = self.execute(self.player_index)
        if isinstance(response, str) and "CQHEX_" in response:
            hx = "".join(ch for ch in response.split("CQHEX_", 1)[1] if ch in "0123456789abcdef")
            return json.loads(bytes.fromhex(hx).decode())
        raise Exception(f"craft_queue failed: {response}")
