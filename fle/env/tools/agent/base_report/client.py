import json
from typing import Any, Dict, List

from fle.env.tools import Tool


class BaseReport(Tool):
    def __init__(self, *args):
        super().__init__(*args)

    def __call__(self, points: List[Dict[str, Any]], items: List[str] = ()) -> Dict[str, Any]:
        """
        Read what a player sees in the production, power and alert screens and on the map.
        :param points: [{"name", "x", "y", "r"}] sites to inspect
        :param items: item names for per-minute production/consumption
        :return: {"sites": [{name, statuses{type:status: n}, enemies, pollution, damaged, turrets,
                 turrets_low_ammo}], "production": {item: {made_per_min, used_per_min}},
                 "power": {generated_mw, consumed_mw, engines{status: n}},
                 "threat": {evolution, nests_within_150, units_within_150}}
        """
        ph = json.dumps(list(points)).encode().hex()
        ih = json.dumps(list(items)).encode().hex()
        response, _ = self.execute(self.player_index, ph, ih)
        if isinstance(response, str) and "BASEHEX_" in response:
            h = "".join(ch for ch in response.split("BASEHEX_", 1)[1] if ch in "0123456789abcdef")
            return json.loads(bytes.fromhex(h).decode())
        raise Exception(f"base_report failed: {response}")
