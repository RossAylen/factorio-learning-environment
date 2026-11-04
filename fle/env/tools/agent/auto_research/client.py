import json
from typing import Any, Dict, List, Optional

from fle.env.tools import Tool


class AutoResearch(Tool):
    def __init__(self, *args):
        super().__init__(*args)

    def __call__(self, names: Optional[List[str]] = None) -> Dict[str, Any]:
        """
        Set the research priority list (names=None keeps it) and refill the game's research
        queue now. The game keeps it at >= 3 entries by itself (on research finished and every
        600 ticks): priority list first, then techs whose packs the factory made in the last
        10 minutes, cheapest first.
        :return: {"queue": [...], "current": name, "priority": n}
        """
        h = ""
        if names is not None:
            h = json.dumps([n.value if hasattr(n, "value") else str(n) for n in names]).encode().hex()
        response, _ = self.execute(self.player_index, h)
        if isinstance(response, str) and "ARHEX_" in response:
            hx = "".join(ch for ch in response.split("ARHEX_", 1)[1] if ch in "0123456789abcdef")
            out = json.loads(bytes.fromhex(hx).decode())
            if isinstance(out.get("queue"), dict):
                out["queue"] = list(out["queue"].values())
            return out
        raise Exception(f"auto_research failed: {response}")
