import json
from typing import Any, Dict, Optional

from fle.env.entities import Position
from fle.env.tools import Tool


class Nests(Tool):
    def __init__(self, *args):
        super().__init__(*args)

    def __call__(self, position: Optional[Position] = None, radius: float = 200, limit: int = 60) -> Dict[str, Any]:
        """
        Enemy spawners and worms within `radius` of `position` (default the character), nearest
        first, with the pollution at each (polluted nests send the attacks), plus how far the
        pollution cloud reaches from `position`.
        :return: {"nests": [{x, y, name, type, d, pollution}], "total", "polluted", "cloud_radius"}
        """
        if position is None:
            position = self.game_state.player_location
        response, _ = self.execute(self.player_index, position.x, position.y, radius, limit)
        if isinstance(response, str) and "NESTHEX_" in response:
            hx = "".join(ch for ch in response.split("NESTHEX_", 1)[1] if ch in "0123456789abcdef")
            out = json.loads(bytes.fromhex(hx).decode())
            if isinstance(out.get("nests"), dict):
                out["nests"] = list(out["nests"].values())
            return out
        raise Exception(f"nests failed: {response}")
