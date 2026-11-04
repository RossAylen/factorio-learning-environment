import json
from typing import Any, Dict

from fle.env.tools import Tool


class Circuits(Tool):
    """circuits(op, **spec) - Factorio 2.x circuit network and rail graph:
    circuits("wire", a={"x","y","name"?,"side"?: "input"|"output"}, b={...}, color="red"|"green", disconnect=False)
    circuits("signals", x=, y=, color="red", side="output") -> {network, signals: [{type, name, count}]}
    circuits("constant", x=, y=, signals=[{"type": "item", "name": "iron-plate", "count": 10}])
    circuits("arithmetic", x=, y=, parameters={first_signal, second_constant|second_signal, operation, output_signal})
    circuits("decider", x=, y=, parameters={"conditions": [...], "outputs": [...]})   (2.x tables verbatim)
    circuits("control", x=, y=, name=?, fields={"set_trains_limit": True, "trains_limit_signal": {...}, ...})
        any LuaControlBehavior fields: train stop, chest, pump, inserter, ...
    circuits("inserters", x=, y=, into=False, from=False, radius=3) -> {entity, inserters: [{n, x, y, into, from, drop, pick}]}
    circuits("pole", x=, y=) -> {n, x, y, net, reach, supply, nb: [{n, x, y, net, reach}]}   (copper neighbours)
    circuits("pole_connect", a={x, y}, b={x, y}, disconnect=False) -> {ok, a, b}
    circuits("graph", x=, y=, radius=60) -> {rails, blocks, block_sizes, signals [{x,y,d,chain,state}], stops}
    """

    def __init__(self, *args):
        super().__init__(*args)

    def __call__(self, op: str, **spec: Any) -> Dict[str, Any]:
        h = json.dumps(spec).encode().hex()
        response, _ = self.execute(self.player_index, op, h)
        if isinstance(response, str) and "CIRCHEX_" in response:
            hx = "".join(ch for ch in response.split("CIRCHEX_", 1)[1] if ch in "0123456789abcdef")
            out = json.loads(bytes.fromhex(hx).decode())
            for k, v in list(out.items()):
                if isinstance(v, dict) and v and all(str(x).isdigit() for x in v):
                    out[k] = [v[x] for x in sorted(v, key=int)]
            return out
        raise Exception(f"circuits {op} failed: {response}")
