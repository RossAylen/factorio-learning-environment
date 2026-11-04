import json
from typing import Any, Dict, List, Optional

from fle.env.tools import Tool


class OreSites(Tool):
    def __init__(self, *args):
        super().__init__(*args)

    def __call__(self, resource: str, w: int, h: int, x: float, y: float, drills: List[Dict[str, float]],
                 radius: float = 40, trees_ok: bool = False, limit: int = 8) -> Dict[str, Any]:
        """
        Where does a w x h mining layout fit with EVERY drill's mining area on pure `resource`
        and nothing in the way? One scan around (x, y).
        :param resource: e.g. "iron-ore"
        :param drills: [{"x", "y", "r"}] drill centres relative to the integer left-top origin,
                       r = mining radius (electric drill 2.49)
        :return: {"sites": [{x, y (origin), d (distance), amount, trees}], "found": n,
                  "reasons": {blocked, trees, mixed, no_ore}}  nearest first
        """
        spec = {"resource": resource, "w": int(w), "h": int(h), "x": float(x), "y": float(y),
                "radius": float(radius), "drills": list(drills), "trees_ok": bool(trees_ok), "limit": int(limit)}
        response, _ = self.execute(self.player_index, json.dumps(spec).encode().hex())
        if isinstance(response, str) and "OREHEX_" in response:
            hx = "".join(ch for ch in response.split("OREHEX_", 1)[1] if ch in "0123456789abcdef")
            return json.loads(bytes.fromhex(hx).decode())
        raise Exception(f"ore_sites failed: {response}")
