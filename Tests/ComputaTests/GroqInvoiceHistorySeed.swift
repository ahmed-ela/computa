import Foundation

/// Byte-exact existing controlled invoice seed; no provider/user history.
enum GroqInvoiceHistorySeed {
    static let files: [String: Data] = [
        "README.md": Data(#"""
# Invoice reconciliation exercise

Fix only `summarize` in `reconcile.py`. Rows with the same SKU after trimming
surrounding whitespace and uppercasing must be combined. Sum every quantity and
every line subtotal (`quantity * unit_cents`), including when prices differ.
Return SKU-sorted rows and their exact integer-cent total. Do not mutate inputs.

Keep `SAMPLE_ITEMS`, `reference_for`, the tests, and this README unchanged.
Use no dependencies.

Run `python3 -m unittest -v`, then `python3 reconcile.py` to print the reference.
The browser task uses that printed reference.
"""#.utf8) + Data([10]),
        "reconcile.py": Data(#"""
"""Small invoice reconciliation exercise; run this file to print its reference."""
import hashlib
import json

SAMPLE_ITEMS = [
    {"sku": " bolt ", "quantity": 2, "unit_cents": 125},
    {"sku": "NUT", "quantity": 3, "unit_cents": 40},
    {"sku": "BOLT", "quantity": 1, "unit_cents": 150},
    {"sku": "nut ", "quantity": 2, "unit_cents": 40},
]


def summarize(items):
    """Aggregate normalized SKUs, quantities, and exact integer-cent subtotals."""
    grouped = {}
    for item in items:
        sku = item["sku"].strip().upper()
        grouped[sku] = {
            "sku": sku,
            "quantity": item["quantity"],
            "subtotal_cents": item["quantity"] * item["unit_cents"],
        }
    rows = [grouped[sku] for sku in sorted(grouped)]
    return {"items": rows, "total_cents": sum(row["subtotal_cents"] for row in rows)}


def reference_for(summary):
    canonical = json.dumps(summary, sort_keys=True, separators=(",", ":"))
    digest = hashlib.sha256(canonical.encode("utf-8")).hexdigest()[:8].upper()
    return f"INV-{digest}-{summary['total_cents']}"


if __name__ == "__main__":
    print(reference_for(summarize(SAMPLE_ITEMS)))
"""#.utf8) + Data([10]),
        "test_reconcile.py": Data(#"""
"""Immutable specification tests; this file is not part of the requested edit."""
import copy
import itertools
import unittest
from reconcile import SAMPLE_ITEMS, reference_for, summarize


class ReconcileTests(unittest.TestCase):
    def test_duplicates_normalize_and_accumulate_different_prices(self):
        self.assertEqual(summarize(SAMPLE_ITEMS), {
            "items": [
                {"sku": "BOLT", "quantity": 3, "subtotal_cents": 400},
                {"sku": "NUT", "quantity": 5, "subtotal_cents": 200},
            ],
            "total_cents": 600,
        })

    def test_all_input_orders_have_the_same_result(self):
        expected = {"items": [
            {"sku": "BOLT", "quantity": 3, "subtotal_cents": 400},
            {"sku": "NUT", "quantity": 5, "subtotal_cents": 200},
        ], "total_cents": 600}
        for items in itertools.permutations(SAMPLE_ITEMS):
            with self.subTest(items=items):
                self.assertEqual(summarize(items), expected)

    def test_three_repeated_lines_are_all_retained(self):
        items = [
            {"sku": " x ", "quantity": 4, "unit_cents": 11},
            {"sku": "X", "quantity": 2, "unit_cents": 17},
            {"sku": "x", "quantity": 3, "unit_cents": 5},
        ]
        self.assertEqual(summarize(items), {
            "items": [{"sku": "X", "quantity": 9, "subtotal_cents": 93}],
            "total_cents": 93,
        })

    def test_unique_rows_are_sorted_and_do_not_mutate_input(self):
        items = [
            {"sku": " z ", "quantity": 2, "unit_cents": 101},
            {"sku": "a", "quantity": 3, "unit_cents": 19},
        ]
        original = copy.deepcopy(items)
        self.assertEqual(summarize(items), {"items": [
            {"sku": "A", "quantity": 3, "subtotal_cents": 57},
            {"sku": "Z", "quantity": 2, "subtotal_cents": 202},
        ], "total_cents": 259})
        self.assertEqual(items, original)

    def test_empty_input(self):
        self.assertEqual(summarize([]), {"items": [], "total_cents": 0})

    def test_reference_encoding_and_sample_dataset_are_unchanged(self):
        self.assertEqual(SAMPLE_ITEMS, [
            {"sku": " bolt ", "quantity": 2, "unit_cents": 125},
            {"sku": "NUT", "quantity": 3, "unit_cents": 40},
            {"sku": "BOLT", "quantity": 1, "unit_cents": 150},
            {"sku": "nut ", "quantity": 2, "unit_cents": 40},
        ])
        self.assertEqual(reference_for({"items": [], "total_cents": 0}), "INV-2C2F8254-0")


if __name__ == "__main__":
    unittest.main()
"""#.utf8) + Data([10]),
    ]
}
