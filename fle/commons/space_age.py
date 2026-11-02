"""Space Age (DLC) toggle shared by the cluster launcher and the agent API.

Set FLE_SPACE_AGE=1 to run servers with the Space Age DLC enabled and to expose
the DLC prototypes, recipes, resources and technologies in ``fle.env.game_types``.
Unset (the default), FLE behaves exactly like upstream: vanilla base game only.
"""

import os


def space_age_enabled() -> bool:
    """True when FLE_SPACE_AGE is set to 1/true/yes."""
    return os.environ.get("FLE_SPACE_AGE", "").strip().lower() in ("1", "true", "yes")
