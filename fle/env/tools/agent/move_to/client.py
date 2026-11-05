import math
from time import sleep

from fle.env.entities import Position
from fle.env.instance import NONE
from fle.env.game_types import Prototype
from fle.env.tools.admin.get_path.client import GetPath
from fle.env.tools.admin.request_path.client import RequestPath
from fle.env.tools import Tool
from fle.env.lua_manager import LuaScriptManager


# Hooks set by the play library (per process): GUARD["path"](points, start, goal) may raise to refuse a
# planned path (e.g. one that leaves the turret rings); GUARD["step"]() is polled every 0.5 s while a
# slow walk is under way and returns a reason string to STOP it (enemies came near), or None.
# (kept in the controller module: tool clients are loaded per instance by file path, so a module
# global here would not be the one the play library sees)
from fle.env.tools import controller as _ctl
if not hasattr(_ctl, "WALK_GUARD"):
    _ctl.WALK_GUARD = {"path": None, "step": None}
GUARD = _ctl.WALK_GUARD


class WalkStopped(Exception):
    """The walk was stopped part-way by GUARD["step"] (the character stands where it stopped)."""


class MoveTo(Tool):
    def __init__(self, connection: LuaScriptManager, game_state):
        super().__init__(connection, game_state)
        # self.observe = ObserveAll(connection, game_state)
        self.request_path = RequestPath(connection, game_state)
        self.get_path = GetPath(connection, game_state)

    def __call__(
        self, position: Position, laying: Prototype = None, leading: Prototype = None
    ) -> Position:
        """
        Move to a position.
        :param position: Position to move to.
        :return: Your final position
        """

        X_OFFSET, Y_OFFSET = 0, 0  # 0.5, 0

        x, y = (
            math.floor(position.x * 4) / 4 + X_OFFSET,
            math.floor(position.y * 4) / 4 + Y_OFFSET,
        )
        nposition = Position(x=x, y=y)

        # Slow (real-time) mode: the character really walks the path, so it must go AROUND our
        # buildings (a path through them pins it against a chest forever). Fast mode moves along
        # the path without collisions, so through-own-entities paths are fine there. If no path
        # around exists (goal enclosed by our entities), fall back to the old through-path.
        slow = not self.game_state.instance.fast
        start = Position(x=self.game_state.player_location.x, y=self.game_state.player_location.y)
        # start from where the character really is (player_location can be stale), and if it
        # stands inside a building (one was built around it), step it out first
        try:
            r = self.connection.rcon_client.send_command(
                f"/silent-command local p = storage.actions.where({self.player_index}, 1) "
                f"rcon.print(p.x .. ',' .. p.y .. ',' .. tostring(p.moved))"
            )
            px, py, mv = r.strip().split(",")
            start = Position(x=float(px), y=float(py))
            self.game_state.player_location = start
        except Exception:
            pass
        def _try_paths(st, owns):
            """path handle from st, or the last error"""
            err = None
            for own in owns:
                h = self.request_path(start=st, finish=nposition, allow_paths_through_own_entities=own,
                                      resolution=-1, for_walking=slow)
                try:
                    self.get_path(h)
                    return h, None
                except Exception as e:
                    err = e
            return None, err

        # slow: around our entities first; fast: through them (it does not collide)
        path_handle, err = _try_paths(start, (False,) if slow else (True,))
        if path_handle is None:
            # boxed in (a restore dropped the character on a cliff, trees/rocks, a row built
            # around it): mine trees/rocks in reach, move to the nearest free spot, try again
            around = ""
            try:
                r = self.connection.rcon_client.send_command(
                    f"/silent-command local p = storage.actions.where({self.player_index}, 2) "
                    f"rcon.print(p.x .. '|' .. p.y .. '|' .. tostring(p.moved) .. '|' .. p.mined .. '|' .. p.around)"
                )
                px, py, mv, mined, around = (r.strip().split("|") + ["", "", "", "", ""])[:5]
                start = Position(x=float(px), y=float(py))
                self.game_state.player_location = start
            except Exception:
                pass
            # around again from the free spot
            path_handle, err2 = _try_paths(start, (False,) if slow else (True,))
            if path_handle is None and slow:
                # the way in is a way out: retrace the last walked route, then plan again
                try:
                    k = self.connection.rcon_client.send_command(
                        f"/silent-command rcon.print(storage.actions.walk_back({self.player_index}, 30))")
                    if k and k.strip() not in ("", "0"):
                        import time as _t
                        t0 = _t.time()
                        while _t.time() - t0 < 60:
                            sleep(0.5)
                            rem = self.connection.rcon_client.send_command(
                                f"/silent-command rcon.print(storage.actions.get_walking_queue_length({self.player_index}))")
                            if rem == "0":
                                break
                        r = self.connection.rcon_client.send_command(
                            f"/silent-command local p = storage.actions.where({self.player_index}, 0) rcon.print(p.x .. ',' .. p.y)")
                        px, py = r.strip().split(",")
                        start = Position(x=float(px), y=float(py))
                        self.game_state.player_location = start
                        path_handle, err2 = _try_paths(start, (False,))
                except Exception:
                    pass
            if path_handle is None:
                # last resort: through our entities
                path_handle, err2 = _try_paths(start, (True,))
            if path_handle is None:
                hint = (f" Entities around the character: {around}. Pick up the one toward the target "
                        f"(pickup_entity(...)), walk out, and re-place it." if around else "")
                raise Exception(f"Could not get path to ({x}, {y}) from ({start.x:.1f}, {start.y:.1f}): {err2 or err}.{hint}")

        if GUARD.get("path"):
            try:
                pts = self.get_path(path_handle)
            except Exception:
                pts = None
            if pts:
                GUARD["path"](pts, start, nposition)     # raises to refuse the path

        # Track elapsed ticks for fast forward
        ticks_before = self.game_state.instance.get_elapsed_ticks()

        try:
            if laying is not None:
                entity_name = laying.value[0]
                response, execution_time = self.execute(
                    self.player_index, path_handle, entity_name, 1
                )
            elif leading:
                entity_name = leading.value[0]
                response, execution_time = self.execute(
                    self.player_index, path_handle, entity_name, 0
                )
            else:
                response, execution_time = self.execute(
                    self.player_index, path_handle, NONE, NONE
                )

            # Sleep for the appropriate real-world time based on elapsed ticks
            ticks_after = self.game_state.instance.get_elapsed_ticks()
            ticks_added = ticks_after - ticks_before
            if ticks_added > 0:
                game_speed = self.game_state.instance.get_speed()
                real_world_sleep = (
                    ticks_added / 60 / game_speed if game_speed > 0 else 0
                )
                sleep(real_world_sleep)

            if isinstance(response, int) and response == 0:
                raise Exception("Could not move.")

            if isinstance(response, str):
                raise Exception(f"Could not move. {response}")

            if response == "trailing" or response == "leading":
                raise Exception("Could not lay entity, perhaps a typo?")

            if response and isinstance(response, dict):
                self.game_state.player_location = Position(
                    x=response["x"], y=response["y"]
                )

            # If `fast` is turned off - we need to long poll the game state to ensure the player has moved
            if not self.game_state.instance.fast:
                remaining_steps = self.connection.rcon_client.send_command(
                    f"/silent-command rcon.print(storage.actions.get_walking_queue_length({self.player_index}))"
                )
                import time as _time
                t_walk = _time.time()
                while remaining_steps != "0" and _time.time() - t_walk < 600:
                    sleep(0.5)
                    if GUARD.get("step"):
                        why = None
                        try:
                            why = GUARD["step"]()
                        except Exception:
                            why = None
                        if why:
                            self.connection.rcon_client.send_command(
                                f"/silent-command storage.actions.clear_walking_queue({self.player_index})")
                            raise WalkStopped(f"walk to ({position.x}, {position.y}) stopped: {why}")
                    remaining_steps = self.connection.rcon_client.send_command(
                        f"/silent-command rcon.print(storage.actions.get_walking_queue_length({self.player_index}))"
                    )
                stuck = self.connection.rcon_client.send_command(
                    f"/silent-command rcon.print(storage.actions.get_walk_stuck({self.player_index}))"
                )
                if stuck and stuck.strip():
                    raise Exception(f"walk to ({position.x}, {position.y}) failed: {stuck.strip()}. "
                                    f"Move to a tile beside the target, or pick up / walk around the blocker.")
                self.game_state.player_location = Position(x=position.x, y=position.y)

            return Position(x=response["x"], y=response["y"])  # , execution_time
        except Exception as e:
            if response:
                raise Exception(f"Cannot move. {e} - {response}")
            raise Exception(f"Cannot move. {e}")
