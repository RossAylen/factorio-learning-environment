import json
from typing import Any, Dict

from fle.env.tools import Tool


class Alarm(Tool):
    """alarm(op, **spec) - silent circuit alarms: contamination(tiles=[[x,y]], allowed=[items], text=, icon=), low(x=, y=, n=, text=, icon=, kind=) for a chest/accumulator/train stop, list(active_only=), remove(id=)."""

    def __init__(self, *args):
        super().__init__(*args)

    def __call__(self, op: str, **spec: Any) -> Dict[str, Any]:
        response, _ = self.execute(self.player_index, op, json.dumps(spec).encode().hex())
        if isinstance(response, str) and "ALRMHEX_" in response:
            hx = "".join(ch for ch in response.split("ALRMHEX_", 1)[1] if ch in "0123456789abcdef")
            out = json.loads(bytes.fromhex(hx).decode())
            for k in ("alarms", "units"):
                if isinstance(out.get(k), dict):
                    out[k] = list(out[k].values())
            return out
        raise Exception(f"alarm {op} failed: {response}")
