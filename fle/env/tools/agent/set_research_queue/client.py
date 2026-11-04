import json
from typing import Any, Dict, List

from fle.env.tools import Tool


class SetResearchQueue(Tool):
    def __init__(self, *args):
        super().__init__(*args)

    def __call__(self, names: List[str]) -> Dict[str, Any]:
        """
        Give the game a research queue (up to 7): when one tech finishes the game starts the next
        by itself, no script needed. Researched techs are dropped; not-enabled, trigger techs and
        techs with unmet prerequisites (not researched and not earlier in the queue) are skipped.
        :return: {"queue": [names now queued], "current": name or "", "skipped": [{name, why}], "error": ""}
        """
        names = [n.value[0] if hasattr(n, "value") and isinstance(n.value, tuple) else
                 (n.value if hasattr(n, "value") else str(n)) for n in names]
        response, _ = self.execute(self.player_index, json.dumps(names).encode().hex())
        if isinstance(response, str) and "RQHEX_" in response:
            hx = "".join(ch for ch in response.split("RQHEX_", 1)[1] if ch in "0123456789abcdef")
            return json.loads(bytes.fromhex(hx).decode())
        raise Exception(f"set_research_queue failed: {response}")
