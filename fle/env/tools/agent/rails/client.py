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
    rails("schedule", x=, y=, train_id=0 (exact; else the locomotive nearest x,y - ambiguous -> error with ids), records=[{"station": "A", "wait_conditions": [{"type": "time", "ticks": 300}]}],
          interrupts=[{"name", "conditions": [...], "targets": [records], "inside_interrupt": False}],
          group="Iron", auto=True)   (WaitCondition tables verbatim; compare_type defaults to "and")
    rails("stop_config", x=, y=, limit=1 (-1 none, 0 closed), priority=50, enable=True) -> stop info
    rails("signal", x=, y=, d=travel_dir, chain=False) -> {x, y, dir, rails}  (at a straight rail END)
    rails("remove", x=, y=, radius=20) -> counts (rail entities back into the inventory)
    rails("consist", x=, y=, d=, spec="1-2", fuel="coal", fuel_count=50) -> {train, carriages}
    """

    def __init__(self, *args):
        super().__init__(*args)

    def __call__(self, op: str, pieces: Optional[List[Dict]] = None, x: float = 0, y: float = 0, radius: float = 60,
                 name: str = "", d: int = 0, fuel: str = "", fuel_count: int = 0, records: Optional[List[Dict]] = None,
                 auto: bool = True, reach: float = 10, limit: Optional[int] = None, priority: Optional[int] = None,
                 enable: Optional[bool] = None, interrupts: Optional[List[Dict]] = None, group: str = "",
                 chain: bool = False, spec: str = "1-1", train_id: Optional[int] = 0) -> Any:
        if train_id is None:
            raise ValueError("rails: train_id=None - no train id (did rails('read') find the train? its 'trains' list was empty)")
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
        elif op == "stop_name":
            r, _ = self.execute(self.player_index, "train_stop_name", x, y, name)
            out = _dec(r)
            return out.get("name") if isinstance(out, dict) else out
        elif op == "schedule":
            spec_ = {"auto": bool(auto)}
            if records is not None:
                spec_["records"] = list(records)
            if interrupts is not None:
                spec_["interrupts"] = list(interrupts)
            if group:
                spec_["group"] = group
            h = json.dumps(spec_).encode().hex()
            r, _ = self.execute(self.player_index, "rail_schedule2", x, y, h, int(train_id or 0))
        elif op == "stop_config":
            r, _ = self.execute(self.player_index, "rail_stop_config", x, y,
                                -2 if limit is None else (-1 if limit < 0 else int(limit)),
                                -2 if priority is None else int(priority),
                                -2 if enable is None else (1 if enable else 0))
        elif op == "signal":
            r, _ = self.execute(self.player_index, "rail_signal", x, y, d, 1 if chain else 0)
            return r
        elif op == "remove":
            r, _ = self.execute(self.player_index, "rail_remove", x, y, radius)
        elif op == "consist":
            r, _ = self.execute(self.player_index, "rail_consist", x, y, d, spec, fuel, fuel_count)
        else:
            raise ValueError(f"rails: unknown op {op}")
        return _dec(r)
