import json
from typing import Any, Dict

from fle.env.tools import Tool


class FlowRead(Tool):
    """flow_read("graph", x0=, y0=, x1=, y1=) -> {machines, inserters, belts}; flow_read("recipes", items=[...]) -> {recipes, speeds}"""

    def __init__(self, *args):
        super().__init__(*args)

    def __call__(self, op: str, **spec: Any) -> Dict[str, Any]:
        response, _ = self.execute(self.player_index, op, json.dumps(spec).encode().hex())
        if isinstance(response, str) and "FLOWHEX_" in response:
            hx = "".join(ch for ch in response.split("FLOWHEX_", 1)[1] if ch in "0123456789abcdef")
            out = json.loads(bytes.fromhex(hx).decode())
            for k in ("machines", "inserters", "belts"):
                if isinstance(out.get(k), dict):
                    out[k] = list(out[k].values())
            return out
        raise Exception(f"flow_read {op} failed: {response}")
