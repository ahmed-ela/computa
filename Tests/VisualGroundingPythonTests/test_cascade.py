import math
from pathlib import Path
import sys
import unittest


RESOURCE_ROOT = (
    Path(__file__).resolve().parents[2]
    / "Sources"
    / "Computa"
    / "Resources"
    / "VisualGrounding"
)
sys.path.insert(0, str(RESOURCE_ROOT))

from grounding_runtime.cascade import (
    AGREEMENT_THRESHOLD,
    GroundingRefusal,
    requires_showui,
    select_point,
)


class CascadeTests(unittest.TestCase):
    def test_agreement_uses_first_two_midpoint_and_does_not_consult_showui(self):
        result = select_point([100, 100], [106, 108], [900, 700], 1280, 800)
        self.assertFalse(result["used_showui"])
        self.assertEqual(result["selected_pair"], ["goclick", "gui_owl_2b"])
        self.assertEqual(result["point"], [103, 104])

    def test_exact_threshold_is_agreement(self):
        width, height = 400, 300
        threshold_pixels = AGREEMENT_THRESHOLD * math.hypot(width, height)
        use_showui, distance = requires_showui(
            [100, 100], [100 + threshold_pixels, 100], width, height
        )
        self.assertFalse(use_showui)
        self.assertAlmostEqual(distance, threshold_pixels)

    def test_disagreement_runs_showui_and_uses_closest_pair(self):
        result = select_point([100, 100], [900, 700], [110, 108], 1280, 800)
        self.assertTrue(result["used_showui"])
        self.assertEqual(result["selected_pair"], ["goclick", "showui"])
        self.assertEqual(result["point"], [105, 104])

    def test_missing_initial_point_can_be_resolved_by_showui(self):
        result = select_point(None, [500, 300], [504, 306], 1280, 800)
        self.assertTrue(result["used_showui"])
        self.assertEqual(result["selected_pair"], ["gui_owl_2b", "showui"])
        self.assertEqual(result["point"], [502, 303])

    def test_fewer_than_two_valid_points_fails_closed(self):
        with self.assertRaisesRegex(ValueError, "fewer than two"):
            select_point([float("nan"), 10], [2000, 10], [50, 50], 1280, 800)

    def test_three_way_disagreement_fails_closed(self):
        with self.assertRaisesRegex(GroundingRefusal, "no two grounders agree") as caught:
            select_point([50, 50], [640, 400], [1200, 750], 1280, 800)
        self.assertEqual(caught.exception.code, "no_pair_agreement")

    def test_boolean_nonfinite_and_out_of_bounds_points_are_invalid(self):
        invalid = [
            [True, 1],
            [float("inf"), 1],
            [-1, 1],
            [1280, 1],
            [1],
            "1,2",
        ]
        for value in invalid:
            with self.subTest(value=value):
                use_showui, distance = requires_showui(value, [10, 10], 1280, 800)
                self.assertTrue(use_showui)
                self.assertIsNone(distance)


if __name__ == "__main__":
    unittest.main()
