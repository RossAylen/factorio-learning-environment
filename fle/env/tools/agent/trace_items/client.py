from typing import Any, Dict, List, Union

from fle.env.entities import Entity, EntityGroup, Position
from fle.env.tools import Tool


class ItemTrace:
    """Result of trace_items: can items move from source to target, and if not, where it breaks."""

    def __init__(self, data: Dict[str, Any]):
        def as_list(v):
            if isinstance(v, dict):
                return [v[k] for k in sorted(v, key=lambda k: int(k) if str(k).isdigit() else str(k))]
            return list(v or [])

        self.connected: bool = bool(data.get("connected"))
        self.path: List[str] = as_list(data.get("path"))
        self.dead_ends: List[str] = as_list(data.get("dead_ends"))
        self.reached: List[str] = as_list(data.get("reached"))
        self.items_on_belts: Dict[str, int] = dict(data.get("items_on_belts") or {})
        self.visited: int = int(data.get("visited") or 0)
        self.source = data.get("source")
        self.target = data.get("target")

    def __bool__(self):
        return self.connected

    def __repr__(self):
        if self.connected:
            return f"ItemTrace(connected {self.source} -> {self.target}: " + " | ".join(self.path) + ")"
        return (f"ItemTrace(NOT connected {self.source} -> {self.target}; visited {self.visited}; "
                f"dead ends: {self.dead_ends[:6]}; machines reached: {self.reached[:6]}; "
                f"items on belts: {self.items_on_belts})")


class TraceItems(Tool):
    def __init__(self, *args):
        super().__init__(*args)

    def __call__(
        self,
        source: Union[Entity, EntityGroup, Position],
        target: Union[Entity, EntityGroup, Position],
        max_nodes: int = 5000,
    ) -> ItemTrace:
        """
        Check whether items can travel from `source` to `target` through belts, underground belts,
        splitters, inserters and mining-drill drops, exactly as the game has them connected.
        :param source: entity (drill, chest, machine, belt) or position where items start
        :param target: entity or position that should receive them
        :param max_nodes: search limit
        :return: ItemTrace (truthy when connected) with the path, or the dead ends where it breaks
        """
        def pos(x):
            import math
            if isinstance(x, Position):
                # a bare position means the tile it lies on
                return Position(x=math.floor(x.x) + 0.5, y=math.floor(x.y) + 0.5)
            if isinstance(x, tuple):
                return Position(x=x[0], y=x[1])
            return x.position

        s, t = pos(source), pos(target)
        response, _ = self.execute(self.player_index, s.x, s.y, t.x, t.y, max_nodes)
        if isinstance(response, str) and "TRACEHEX_" in response:
            import json
            blob = response.split("TRACEHEX_", 1)[1]
            blob = "".join(ch for ch in blob if ch in "0123456789abcdef")
            return ItemTrace(json.loads(bytes.fromhex(blob).decode("utf-8")))
        if isinstance(response, str):
            raise Exception(f"trace_items failed: {response}")
        return ItemTrace(response)
