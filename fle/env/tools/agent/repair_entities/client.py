from typing import Dict

from fle.env.tools import Tool


class RepairEntities(Tool):
    def __init__(self, *args):
        super().__init__(*args)

    def __call__(self, radius: float = 10, scan_radius: float = 0) -> Dict[str, int]:
        """
        Repair every damaged friendly entity within reach of the character, spending repair packs
        from the inventory (one pack restores 300 HP). Walk to the damage first.
        :param radius: search radius around the character (capped at reach distance)
        :param scan_radius: if > 0, only list damaged entities within this radius:
            {"damaged": [[x, y], ...], "count": n}
        :return: {"repaired": n, "hp": hp restored, "still_damaged": n, "packs_left": n}
        """
        response, _ = self.execute(self.player_index, radius, scan_radius)
        if isinstance(response, str):
            raise Exception(f"repair_entities failed: {response}")
        return response
