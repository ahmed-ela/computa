from pathlib import Path
import sys
import unittest


RESOURCE_ROOT = (
    Path(__file__).resolve().parents[2]
    / "Sources"
    / "HeyDash"
    / "Resources"
    / "VisualGrounding"
)
sys.path.insert(0, str(RESOURCE_ROOT))

from worker import _go_point, _target


class WorkerParserTests(unittest.TestCase):
    def test_goclick_accepts_only_one_complete_coordinate(self):
        self.assertEqual(_go_point("<s>(<loc_250>,<loc_500>)", 1000, 800), [250, 400])
        self.assertEqual(_go_point("(<loc_250>, <loc_500>)</s>", 1000, 800), [250, 400])
        for value in (
            "point=(<loc_250>,<loc_500>)",
            "(<loc_250>,<loc_500>) trailing",
            "(<loc_250>,<loc_500>) (<loc_100>,<loc_100>)",
            "<loc_250>,<loc_500>",
        ):
            with self.subTest(value=value):
                self.assertIsNone(_go_point(value, 1000, 800))

    def test_target_rejects_controls_formatting_and_surrounding_whitespace(self):
        self.assertEqual(_target("Calculator digit 1 button"), "Calculator digit 1 button")
        for value in (" Save", "Save\nCancel", "Save\tCancel", "Save\u202eCancel"):
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    _target(value)


if __name__ == "__main__":
    unittest.main()
