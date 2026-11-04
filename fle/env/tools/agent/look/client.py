import json
from typing import Any, Dict, List, Optional, Union

from fle.env.entities import Entity, Position
from fle.env.tools import Tool


class Look(Tool):
    def __init__(self, *args):
        super().__init__(*args)

    def __call__(self, position: Union[Position, Entity, None] = None, radius: float = 8,
                 names: Optional[List[str]] = None, all_types: bool = False) -> Dict[str, Any]:
        """
        What a player sees hovering over everything within `radius` of `position`: our entities
        grouped by name + status, up to 4 examples each with a short detail (recipe, contents,
        ammo, mined resource, fuel, fluid). Belts, pipes and poles are skipped unless `names`
        lists them or all_types=True.
        :return: {"total": n, "groups": [{name, status, n, ex: [{x, y, d}]}]}
        """
        if position is None:
            position = self.get_player_location() if hasattr(self, "get_player_location") else Position(x=0, y=0)
        if isinstance(position, Entity):
            position = position.position
        nh = json.dumps(list(names or [])).encode().hex()
        response, _ = self.execute(self.player_index, position.x, position.y, radius, nh, bool(all_types))
        if isinstance(response, str) and "LOOKHEX_" in response:
            hx = "".join(ch for ch in response.split("LOOKHEX_", 1)[1] if ch in "0123456789abcdef")
            return json.loads(bytes.fromhex(hx).decode())
        raise Exception(f"look failed: {response}")
