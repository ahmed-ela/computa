"""Pure selection rule shared by the production worker and deterministic tests."""

from __future__ import annotations

import itertools
import math


AGREEMENT_THRESHOLD = 0.03
MODEL_NAMES = ("goclick", "gui_owl_2b", "showui")


class GroundingRefusal(ValueError):
    """A bounded, expected refusal distinct from a worker/runtime failure."""

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.details = {}


def _point(value, width, height):
    if not isinstance(value, (list, tuple)) or len(value) != 2:
        return None
    x, y = value
    if isinstance(x, bool) or isinstance(y, bool):
        return None
    if not isinstance(x, (int, float)) or not isinstance(y, (int, float)):
        return None
    x, y = float(x), float(y)
    if not math.isfinite(x) or not math.isfinite(y):
        return None
    if not 0 <= x < width or not 0 <= y < height:
        return None
    return [x, y]


def requires_showui(goclick, gui_owl, width, height):
    first = _point(goclick, width, height)
    second = _point(gui_owl, width, height)
    if first is None or second is None:
        return True, None
    distance = math.dist(first, second)
    return distance > AGREEMENT_THRESHOLD * math.hypot(width, height), distance


def select_point(goclick, gui_owl, showui, width, height):
    """Apply the frozen benchmark rule, failing if fewer than two points are valid."""
    use_showui, initial_distance = requires_showui(goclick, gui_owl, width, height)
    named = [
        (MODEL_NAMES[0], _point(goclick, width, height)),
        (MODEL_NAMES[1], _point(gui_owl, width, height)),
        (MODEL_NAMES[2], _point(showui, width, height) if use_showui else None),
    ]
    valid = [(name, point) for name, point in named if point is not None]
    if len(valid) < 2:
        raise GroundingRefusal(
            "insufficient_valid_points",
            "fewer than two grounders returned a valid point",
        )
    if use_showui:
        first, second = min(
            itertools.combinations(valid, 2),
            key=lambda pair: math.dist(pair[0][1], pair[1][1]),
        )
    else:
        first, second = valid[0], valid[1]
    selected_distance = math.dist(first[1], second[1])
    diagonal = math.hypot(width, height)
    if selected_distance > AGREEMENT_THRESHOLD * diagonal:
        raise GroundingRefusal(
            "no_pair_agreement",
            "no two grounders agree within the required threshold",
        )
    point = [
        (first[1][0] + second[1][0]) / 2,
        (first[1][1] + second[1][1]) / 2,
    ]
    return {
        "point": point,
        "used_showui": use_showui,
        "selected_pair": [first[0], second[0]],
        "initial_distance_normalized_diagonal": (
            initial_distance / diagonal if initial_distance is not None else None
        ),
        "selected_distance_normalized_diagonal": selected_distance / diagonal,
    }
