# where

`where(step_out=False)` reads the character's real position from the game (and refreshes player_location). step_out=True first moves a character standing inside a building to the nearest free spot (within 3 tiles). play_lib.here() and move_to use it.
