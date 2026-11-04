import json
from typing import Any, Dict, List, Optional

from fle.env.entities import Position
from fle.env.tools import Tool


class Scan(Tool):
    def __init__(self, *args):
        super().__init__(*args)

    def __call__(self, names: List[Any], position: Optional[Position] = None, radius: float = 300,
                 limit: int = 3000) -> List[Dict[str, Any]]:
        """
        Lean read of our entities named `names` (Prototypes or names) within `radius` of
        `position` (default the character): [{n, x, y, s (status), inv (chest contents),
        out (furnace output), ammo (turret), fuel, dx/dy (drill drop tile)}]. Milliseconds,
        where get_entities over the same area can take seconds.
        """
        if position is None:
            position = self.game_state.player_location
        nm = [n.value[0] if hasattr(n, "value") and isinstance(n.value, tuple) else str(n) for n in names]
        response, _ = self.execute(self.player_index, json.dumps(nm).encode().hex(), position.x, position.y, radius, limit)
        if isinstance(response, str) and "SCANHEX_" in response:
            hx = "".join(ch for ch in response.split("SCANHEX_", 1)[1] if ch in "0123456789abcdef")
            out = json.loads(bytes.fromhex(hx).decode())
            return list(out.values()) if isinstance(out, dict) else out
        raise Exception(f"scan failed: {response}")
