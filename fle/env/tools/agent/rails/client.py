import json
from typing import Any, Dict, List, Optional

from fle.env.tools import Tool


def _dec(response, tag="RAILHEX_"):
    if isinstance(response, str) and tag in response:
        hx = "".join(ch for ch in response.split(tag, 1)[1] if ch in "0123456789abcdef")
        out = json.loads(bytes.fromhex(hx).decode())
        for k, v in list(out.items()):
            if isinstance(v, dict) and all(str(x).isdigit() for x in v):
                out[k] = [v[x] for x in sorted(v, key=int)]
        return out
    raise Exception(f"rails failed: {response}")


class Rails(Tool):
    """rails(op, ...) - Factorio 2.x rail building and trains:
    rails("place", pieces=[{"n": "straight-rail", "x", "y", "d"}], reach=10) -> {placed, already, failed}
    rails("read", x=, y=, radius=60) -> {rails, open_ends[{x,y,d}], stops[{name,x,y,d,rail}], trains[...], signals}
    rails("train", name="locomotive", x=, y=, d=0, fuel="coal", fuel_count=50) -> {x, y, train, fueled}
    rails("stop", x=, y=, d=, name="A") -> {x, y, name, rail}   (train stop, d = travel direction)
    rails("stop_name", x=, y=, name="A") -> name
    rails("schedule", x=, y=, records=[{"station": "A", "wait": [{"type": "time", "ticks": 300}]}], auto=True)
    """

    def __init__(self, *args):
        super().__init__(*args)

    def __call__(self, op: str, pieces: Optional[List[Dict]] = None, x: float = 0, y: float = 0, radius: float = 60,
                 name: str = "", d: int = 0, fuel: str = "", fuel_count: int = 0, records: Optional[List[Dict]] = None,
                 auto: bool = True, reach: float = 10) -> Any:
        if op == "place":
            h = json.dumps(list(pieces or [])).encode().hex()
            r, _ = self.execute(self.player_index, "rail_place", h, reach)
        elif op == "read":
            r, _ = self.execute(self.player_index, "rail_read", x, y, radius)
        elif op == "train":
            r, _ = self.execute(self.player_index, "train_place", name, x, y, d, fuel, fuel_count)
            if isinstance(r, dict):
                return r
        elif op == "stop":
            r, _ = self.execute(self.player_index, "rail_stop", x, y, d, name)
            return r
        elif op == "stop_name":
            r, _ = self.execute(self.player_index, "train_stop_name", x, y, name)
            return r
        elif op == "schedule":
            h = json.dumps(list(records or [])).encode().hex()
            r, _ = self.execute(self.player_index, "train_schedule", x, y, h, 1 if auto else 0)
        else:
            raise ValueError(f"rails: unknown op {op}")
        return _dec(r)
