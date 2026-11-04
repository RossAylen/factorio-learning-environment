import json
from typing import Any, Dict

from fle.env.tools import Tool


class Vitals(Tool):
    """vitals(since=None) -> {alive, x, y, hp, max_hp, tick, evo, me, deaths: [{i (agent), x, y, tick, cause, cx, cy}]}
    deaths: every agent character death since tick `since` (default the last 30 min)."""

    def __init__(self, *args):
        super().__init__(*args)

    def __call__(self, since: int = None) -> Dict[str, Any]:
        response, _ = self.execute(self.player_index, -1 if since is None else int(since))
        if isinstance(response, str) and "VITHEX_" in response:
            hx = "".join(ch for ch in response.split("VITHEX_", 1)[1] if ch in "0123456789abcdef")
            out = json.loads(bytes.fromhex(hx).decode())
            if isinstance(out.get("deaths"), dict):
                out["deaths"] = [out["deaths"][k] for k in sorted(out["deaths"], key=int)]
            return out
        raise Exception(f"vitals failed: {response}")
