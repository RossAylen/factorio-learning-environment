import json
from typing import Dict, List, Sequence

from fle.env.tools import Tool


class MineNatural(Tool):
    def __init__(self, *args):
        super().__init__(*args)

    def __call__(self, positions: Sequence) -> Dict[str, int]:
        """
        Mine the trees and rocks at `positions` ([(x, y)] or Positions) that are within reach
        (walk near them first). Returns {"mined", "far" (out of reach), "none" (nothing there)}.
        """
        pts = [[p.x, p.y] if hasattr(p, "x") else [p[0], p[1]] for p in positions]
        response, _ = self.execute(self.player_index, json.dumps(pts).encode().hex())
        if not isinstance(response, dict):
            raise Exception(f"mine_natural failed: {response}")
        return response
