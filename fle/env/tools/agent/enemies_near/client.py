from typing import Dict, Union

from fle.env.entities import Entity, Position
from fle.env.tools import Tool


class EnemiesNear(Tool):
    def __init__(self, *args):
        super().__init__(*args)

    def __call__(self, position: Union[Position, Entity, None] = None, radius: float = 40) -> Dict:
        """
        Count enemy units, spawners and worms within `radius` of `position` (default: the character).
        :return: {"units", "spawners", "worms", "nearest_x", "nearest_y", "nearest_dist" (-1 if none), "evolution"}
        """
        if position is None:
            position = self.get_player_location() if hasattr(self, "get_player_location") else Position(x=0, y=0)
        if isinstance(position, Entity):
            position = position.position
        response, _ = self.execute(self.player_index, position.x, position.y, radius)
        if isinstance(response, str):
            raise Exception(f"enemies_near failed: {response}")
        return response
