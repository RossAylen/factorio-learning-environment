import json
from typing import Any, Dict

from fle.env.tools import Tool


class AuditRead(Tool):
    def __init__(self, *args):
        super().__init__(*args)

    def __call__(self, x0: float, y0: float, x1: float, y1: float, limit: int = 800) -> Dict[str, Any]:
        """
        For every machine in the area (assemblers, furnaces, labs, ammo turrets, boilers): its
        recipe, status, and for each required input (recipe ingredients; labs: the current
        research's packs; turrets: ammo; boilers: fuel) whether a feeding inserter's source can
        deliver it (belt networks are traced upstream to what feeds them).
        :return: {"machines": [{x, y, n, t, s, r, en, sp, p: [products], no_taker,
                  inp: [[item, ok (1 yes / 0 no / 2 via lab chain), why, amount, src?]]}],
                  "research": name, "truncated": bool}
        """
        response, _ = self.execute(self.player_index, x0, y0, x1, y1, limit)
        if isinstance(response, str) and "AUDHEX_" in response:
            hx = "".join(ch for ch in response.split("AUDHEX_", 1)[1] if ch in "0123456789abcdef")
            out = json.loads(bytes.fromhex(hx).decode())
            ms = out.get("machines")
            if isinstance(ms, dict):
                out["machines"] = list(ms.values())
            for m in out.get("machines", []):
                for k in ("inp", "p"):
                    if isinstance(m.get(k), dict):
                        m[k] = list(m[k].values())
            return out
        raise Exception(f"audit_read failed: {response}")
