from fle.env.entities import Position
from fle.env.tools import Tool


class Where(Tool):
    def __init__(self, *args):
        super().__init__(*args)

    def __call__(self, step_out: bool = False) -> Position:
        """
        The character's real position, read from the game (the namespace's player_location can be
        stale). step_out=True first moves a character that stands inside a building to the
        nearest free spot (<= 3 tiles).
        """
        response, _ = self.execute(self.player_index, 1 if step_out else 0)
        if not isinstance(response, dict):
            raise Exception(f"where failed: {response}")
        pos = Position(x=response["x"], y=response["y"])
        self.game_state.player_location = pos
        return pos
