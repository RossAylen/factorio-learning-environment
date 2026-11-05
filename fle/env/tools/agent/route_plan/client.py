import json
from typing import Any, Dict, List

from fle.env.entities import Position
from fle.env.tools import Tool


class RoutePlan(Tool):
    """route_plan(src, dst, types=["transport-belt", "underground-belt"]) -> {ok, pieces: [{x, y, d, n, r, e}], error}
    The belt/pipe router's route from src to dst without placing anything (r = surface/entrance/exit,
    d = real direction, e = already there)."""

    def __init__(self, *args):
        super().__init__(*args)

    def __call__(self, src: Position, dst: Position, types: List[str] = None) -> Dict[str, Any]:
        types = types or ["transport-belt", "underground-belt"]
        types = sorted(types, key=lambda n: ("ground" in n or "underground" in n))
        response, _ = self.execute(self.player_index, src.x, src.y, dst.x, dst.y, ",".join(types))
        if isinstance(response, str) and "RPHEX_" in response:
            hx = "".join(ch for ch in response.split("RPHEX_", 1)[1] if ch in "0123456789abcdef")
            out = json.loads(bytes.fromhex(hx).decode())
            p = out.get("pieces")
            if isinstance(p, dict):
                out["pieces"] = [p[k] for k in sorted(p, key=int)]
            return out
        raise Exception(f"route_plan failed: {response}")
