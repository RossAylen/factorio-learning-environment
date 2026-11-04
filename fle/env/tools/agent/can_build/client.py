import json
from typing import Any, Dict, List

from fle.env.tools import Tool


class CanBuild(Tool):
    def __init__(self, *args):
        super().__init__(*args)

    def __call__(self, entities: List[Dict[str, Any]], limit: int = 30) -> Dict[str, Any]:
        """
        Would these entities fit? One read for a whole plan (a blueprint at an origin, a row's
        next slices). Entities already standing there with the same name and position count as ok.
        :param entities: [{"name": "lab", "x": 10.5, "y": 3.5, "d": 0}] absolute centres,
                         d = real game direction (0 N, 4 E, 8 S, 12 W)
        :return: {"ok": n, "n_blocked": n, "already": n, "blockers": {name|tree|rock|tile:X: n},
                  "blocked": [{i, name, x, y, by: [{name, x, y, own}], why}]}
        """
        ents = [{"name": e["name"], "x": float(e["x"]), "y": float(e["y"]), "d": int(e.get("d", 0) or 0)}
                for e in entities]
        h = json.dumps(ents).encode().hex()
        response, _ = self.execute(self.player_index, h, limit)
        if isinstance(response, str) and "CANBHEX_" in response:
            hx = "".join(ch for ch in response.split("CANBHEX_", 1)[1] if ch in "0123456789abcdef")
            out = json.loads(bytes.fromhex(hx).decode())
            out.setdefault("already", 0)
            return out
        raise Exception(f"can_build failed: {response}")
