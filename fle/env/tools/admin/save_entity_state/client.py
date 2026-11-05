import base64
import json
import zlib
from typing import Dict, List, Union

from fle.env.tools import Tool


class SaveEntityState(Tool):
    def __init__(self, *args):
        super().__init__(*args)

    def __call__(
        self,
        distance=500,
        player_entities=False,
        resource_entities=False,
        items_on_ground=True,
        encode=False,
        compress=False,
    ) -> Union[List[Dict], str]:
        """
        Saves the current player entities on the map into a blueprint string
        :arg: distance: Distance around the player to search for entities. Default is 100 tiles.
        :arg: player_entities: Whether or not to include player entities in the blueprint. Default is True.
        :arg: resource_entities: Whether or not to include resource entities in the blueprint. Default is False.
            Note: This is *enormously* expensive!
        :arg: encode: Whether or not to encode the blueprint string. Default is False.
        :arg: compress: Whether or not to compress the blueprint string before encoding it. Default is False.
            Note: Perform encoding and compression if we are sending this over a network.
        :return: Blueprint and offset to blueprint from the origin.
        """
        entities = None
        if getattr(self, "_chunked", True):
            try:
                entities = self._chunked_save(distance, player_entities, resource_entities, items_on_ground)
            except Exception as ex:
                print(f"save_entity_state: chunked save failed ({str(ex)[:80]}); one-tick save")
                entities = None
        if entities is None:
            entities, _ = self.execute(
                self.player_index,
                distance,
                player_entities,
                resource_entities,
                items_on_ground,
            )

        if encode:
            encoded_string = json.dumps(entities).encode()
            if compress:
                encoded_string = zlib.compress(encoded_string)

            return base64.b64encode(encoded_string).decode()

        return entities


    def _call_action(self, action, *args):
        name = self.name
        self.name = action
        try:
            return self.execute(self.player_index, *args)[0]
        finally:
            self.name = name

    def _chunked_save(self, distance, player_entities, resource_entities, items_on_ground, page_size=400):
        """The snapshot serialised a few hundred entities per tick (never one huge tick)."""
        import time as _t
        r = self._call_action("save_entity_state_begin", distance, player_entities, resource_entities, items_on_ground)
        if not isinstance(r, dict) or "total" not in r:
            raise Exception(f"begin failed: {str(r)[:80]}")
        t0 = _t.time()
        while True:
            p = self._call_action("save_entity_state_poll", -1, 0)
            if isinstance(p, dict) and p.get("done"):
                break
            if _t.time() - t0 > 300:
                raise Exception("snapshot job did not finish in 300 s")
            _t.sleep(0.2)
        out, page = [], 0
        while True:
            p = self._call_action("save_entity_state_poll", page, page_size)
            items = p.get("items") if isinstance(p, dict) else None
            if isinstance(items, dict):
                items = [items[k] for k in sorted(items, key=lambda k: int(k))]
            out.extend(items or [])
            if not isinstance(p, dict) or p.get("last") or not items:
                break
            page += 1
        return out
