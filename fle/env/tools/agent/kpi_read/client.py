import json
from typing import Any, Dict

from fle.env.tools import Tool


class KpiRead(Tool):
    """kpi_read(op, **spec) - read-only base health:
    kpi_read("prod", hours=10, items=[...], consumed=[...]) -> {items: {name: [per hour, newest first]}, consumed, power_mw, generators, low_power, no_power}
    kpi_read("clean", x0=, y0=, x1=, y1=) -> counts: redundant poles, belts to nowhere, belts empty 10+ min, machine statuses by area, rails
    """

    def __init__(self, *args):
        super().__init__(*args)

    def __call__(self, op: str, **spec: Any) -> Dict[str, Any]:
        response, _ = self.execute(self.player_index, op, json.dumps(spec).encode().hex())
        if isinstance(response, str) and "KPIHEX_" in response:
            hx = "".join(ch for ch in response.split("KPIHEX_", 1)[1] if ch in "0123456789abcdef")
            return json.loads(bytes.fromhex(hx).decode())
        raise Exception(f"kpi_read {op} failed: {response}")
