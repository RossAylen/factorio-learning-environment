import json
from typing import Any, Dict, Optional, Sequence

from fle.env.tools import Tool


class TurretFeed(Tool):
    def __init__(self, *args):
        super().__init__(*args)

    def __call__(self, area: Optional[Sequence[float]] = None, low: int = 1, limit: int = 40) -> Dict[str, Any]:
        """
        Why are turrets out of ammo? For every ammo turret in `area` ((x0, y0, x1, y1); None = all)
        with fewer than `low` magazines, follow its feed one hop back: the inserter that drops into
        it, its status, and the ammo on its pickup (belt or chest).
        :return: {"turrets": n, "ok": n, "reasons": {reason: n}, "low": [{x, y, ammo, reason,
                 ins_x, ins_y, ins_status, src, src_x, src_y, src_ammo}]}
                 reasons: no_inserter, inserter_unpowered, inserter_no_fuel, inserter_disabled,
                 inserter_picks_from_nothing, chest_empty, belt_empty, feeding (ammo is on its way)
        """
        a = {}
        if area is not None:
            x0, y0, x1, y1 = area
            a = {"x0": min(x0, x1), "y0": min(y0, y1), "x1": max(x0, x1), "y1": max(y0, y1)}
        ah = json.dumps(a).encode().hex()
        response, _ = self.execute(self.player_index, ah, low, limit)
        if isinstance(response, str) and "FEEDHEX_" in response:
            h = "".join(ch for ch in response.split("FEEDHEX_", 1)[1] if ch in "0123456789abcdef")
            return json.loads(bytes.fromhex(h).decode())
        raise Exception(f"turret_feed failed: {response}")
