import json
from typing import Any, Dict

from fle.env.entities import Position
from fle.env.tools import Tool


class Corpses(Tool):
    """corpses(op="list", position=None, radius=3000) -> {corpses: [{x, y, items}]} (character corpses holding items)
    corpses("mine", Position(x, y)) -> {moved, left}: the items into this character (stand within 10 tiles)."""

    def __init__(self, *args):
        super().__init__(*args)

    def __call__(self, op: str = "list", position: Position = None, radius: float = 3000) -> Dict[str, Any]:
        if position is None:
            position = self.game_state.player_location if op != "list" else Position(x=0, y=0)
        response, _ = self.execute(self.player_index, op, position.x, position.y, radius)
        if isinstance(response, str) and "CORPHEX_" in response:
            hx = "".join(ch for ch in response.split("CORPHEX_", 1)[1] if ch in "0123456789abcdef")
            out = json.loads(bytes.fromhex(hx).decode())
            if isinstance(out.get("corpses"), dict):
                out["corpses"] = list(out["corpses"].values())
            return out
        raise Exception(f"corpses {op} failed: {response}")
