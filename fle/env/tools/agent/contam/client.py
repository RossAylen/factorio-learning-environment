import json
from typing import Any, Dict

from fle.env.tools import Tool


class Contam(Tool):
    """contam(op, **spec) - belt contamination: set_lines(lines=[{id, items, tiles}]), events(since=, clear=),
    check_now(), injectors(x=, y=, from=[x, y]), filter_inserters(ins=[[x, y]], items=[...]),
    splitter_filter(x=, y=, item=, side="left"|"right")."""

    def __init__(self, *args):
        super().__init__(*args)

    def __call__(self, op: str, **spec: Any) -> Dict[str, Any]:
        response, _ = self.execute(self.player_index, op, json.dumps(spec).encode().hex())
        if isinstance(response, str) and "CONTHEX_" in response:
            hx = "".join(ch for ch in response.split("CONTHEX_", 1)[1] if ch in "0123456789abcdef")
            out = json.loads(bytes.fromhex(hx).decode())
            for k in ("events", "injectors"):
                if isinstance(out.get(k), dict):
                    out[k] = list(out[k].values())
            return out
        raise Exception(f"contam {op} failed: {response}")
