import json
from typing import Any, Dict

from fle.env.tools import Tool


class FreeMap(Tool):
    def __init__(self, *args):
        super().__init__(*args)

    def __call__(self, x0: float, y0: float, x1: float, y1: float, cell: int = 4) -> Dict[str, Any]:
        """
        What occupies each `cell` x `cell` square of the rectangle (x0, y0)-(x1, y1), in one read.
        :return: {"x0", "y0", "cell", "rows": [str per row, north first], "counts": {char: n}}
                 chars: '.' free, 'o' free on ore, 't' trees/rocks only (clear_trees), '#' our
                 entities, 'w' water, 'E' enemy buildings
        """
        response, _ = self.execute(self.player_index, x0, y0, x1, y1, cell)
        if isinstance(response, str) and "FREEHEX_" in response:
            h = "".join(ch for ch in response.split("FREEHEX_", 1)[1] if ch in "0123456789abcdef")
            return json.loads(bytes.fromhex(h).decode())
        raise Exception(f"free_map failed: {response}")
