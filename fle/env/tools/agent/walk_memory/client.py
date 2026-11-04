import json
from typing import Any, List

from fle.env.tools import Tool


class WalkMemory(Tool):
    def __init__(self, *args):
        super().__init__(*args)

    def __call__(self, op: str = "last", n: int = 10) -> Any:
        """
        The route the character last walked. op="last": its points sampled every `n`
        ([{"x", "y"}]); op="back": walk back along it by up to `n` points (slow mode; returns the
        number queued).
        """
        response, _ = self.execute(self.player_index, op, n)
        if op == "back":
            return response
        if isinstance(response, str) and "LPHEX_" in response:
            hx = "".join(ch for ch in response.split("LPHEX_", 1)[1] if ch in "0123456789abcdef")
            out = json.loads(bytes.fromhex(hx).decode())
            return list(out.values()) if isinstance(out, dict) else out
        raise Exception(f"walk_memory failed: {response}")
