import json
from typing import Any, Dict, List

from fle.env.tools import Tool


class RestoreEntities(Tool):
    def __init__(self, *args):
        super().__init__(*args)

    def __call__(self, plan: List[Dict[str, Any]], dry_run: bool = False) -> Dict[str, Any]:
        """
        Re-place the entities of `plan` that are missing from the map (destroyed by enemies, say),
        using items from the inventory. Plan entries: {"n": name, "x": x, "y": y, "d": direction,
        "t": "input"/"output" for underground belts, "r": recipe}.
        :return: {"placed", "present", "blocked", "short": {item: count still needed}}
        """
        blob = json.dumps(plan).encode().hex()
        response, _ = self.execute(self.player_index, blob, bool(dry_run))
        if isinstance(response, str) and "RESTOREHEX_" in response:
            h = "".join(ch for ch in response.split("RESTOREHEX_", 1)[1] if ch in "0123456789abcdef")
            out = json.loads(bytes.fromhex(h).decode())
            short = out.get("short") or []
            if isinstance(short, dict):
                short = list(short.values())
            out["short"] = {s["item"]: s["count"] for s in short}
            return out
        raise Exception(f"restore_entities failed: {response}")
