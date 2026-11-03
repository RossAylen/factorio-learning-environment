import json
from typing import Any, Dict, List

from fle.env.tools import Tool


class Events(Tool):
    def __init__(self, *args):
        super().__init__(*args)

    def __call__(self, drain: bool = True) -> List[Dict[str, Any]]:
        """
        What happened since the last drain, oldest first. Each event is a dict with "k":
          "died": one of our entities was destroyed - {n, x, y, d, t (underground type), r (recipe), cause}
          "damaged": one of ours took damage (max once per 10 s per entity) - {n, x, y, hp, cause}
          "research": a technology finished - {n}
          "attack_group": an enemy group finished gathering and will attack - {x, y, size}
          "enemy_structure_killed": a nest or worm died - {n, x, y}
        :param drain: clear the queue after reading
        """
        response, _ = self.execute(self.player_index, bool(drain))
        if isinstance(response, str) and "EVHEX_" in response:
            h = "".join(ch for ch in response.split("EVHEX_", 1)[1] if ch in "0123456789abcdef")
            data = json.loads(bytes.fromhex(h).decode())
            ev = data.get("events") or []
            if isinstance(ev, dict):
                ev = [ev[k] for k in sorted(ev, key=lambda k: int(k))]
            return ev
        raise Exception(f"events failed: {response}")
