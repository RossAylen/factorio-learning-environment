import json
from typing import Any, Dict

from fle.env.tools import Tool


class Bots(Tool):
    """bots(op, **spec) - construction robots (Factorio 2.x):
    bots("ghost_bp", bp=<blueprint string>, x=, y=, d=0) -> {ghosts}   (the game pastes it: recipes, wires, settings)
    bots("ghost", entities=[{"n", "x", "y", "d", "recipe"?}]) -> {ghosts}
    bots("deconstruct", x0=, y0=, x1=, y1=, names=[...]?, cancel=False) -> {ordered}
    bots("upgrade", x0=, y0=, x1=, y1=, map={"transport-belt": "fast-transport-belt"}) -> {ordered}
    bots("network", x=, y=, x0=, y0=, x1=, y1=) -> {covered, robots, robots_free, roboports, charging,
        stock, ghosts, need, missing, to_deconstruct}   (area optional)
    """

    def __init__(self, *args):
        super().__init__(*args)

    def __call__(self, op: str, **spec: Any) -> Dict[str, Any]:
        h = json.dumps(spec).encode().hex()
        response, _ = self.execute(self.player_index, op, h)
        if isinstance(response, str) and "BOTSHEX_" in response:
            hx = "".join(ch for ch in response.split("BOTSHEX_", 1)[1] if ch in "0123456789abcdef")
            return json.loads(bytes.fromhex(hx).decode())
        raise Exception(f"bots {op} failed: {response}")
