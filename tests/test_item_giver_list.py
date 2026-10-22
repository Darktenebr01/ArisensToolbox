"""Item Giver list regression tests (v0.94).

The tab used to cap the display at MAX_SHOWN = 300 matches and insert
rows one at a time, so a 2,000+ item list looked truncated. These
tests pin: no cap, bulk fill through the listvariable, and the parse
counts the status line reports.
"""
import types
import unittest

from ui.tabs.item_giver import parse_items

try:
    import tkinter as tk
    import customtkinter  # noqa: F401
    _root = tk.Tk()
    _root.withdraw()
except Exception:
    tk = None

BIG = "\n".join(f"{i}\tTest Item {i}" for i in range(1, 2501))


class ParseItemsTests(unittest.TestCase):
    def test_parses_everything_and_counts_lines(self):
        items, lines = parse_items(BIG)
        self.assertEqual(lines, 2500)
        self.assertEqual(len(items), 2500)
        self.assertEqual(items[2499], (2500, "Test Item 2500", "test item 2500"))

    def test_skips_junk_but_counts_data_lines(self):
        items, lines = parse_items("1\tSword\n\nnotab\nx\tBad id\n2\tShield\n")
        self.assertEqual([i for i, _n, _l in items], [1, 2])
        self.assertEqual(lines, 4)


@unittest.skipIf(tk is None, "tkinter/customtkinter unavailable")
class ItemGiverListTests(unittest.TestCase):
    def setUp(self):
        from ui.tabs.item_giver import ItemGiverTab
        self.statuses = []
        self.app = types.SimpleNamespace(
            client=None,
            set_status=self.statuses.append,
            read_cached_sidecar=lambda name: None,
            cache_sidecar=lambda name, text: None,
        )
        self.tab = ItemGiverTab(_root, self.app)

    def tearDown(self):
        self.tab.destroy()

    def test_full_list_shown_no_cap(self):
        self.tab._fill_items(BIG, "test")
        self.assertEqual(len(self.tab.items), 2500)
        self.assertEqual(len(self.tab.shown), 2500)
        self.assertEqual(self.tab.listbox.size(), 2500)
        self.assertEqual(self.tab.listbox.get(2499), "2500   Test Item 2500")
        self.assertIn("2500 parsed, 2500 shown", self.statuses[-1])

    def test_search_narrows_without_cap_artifacts(self):
        self.tab._fill_items(BIG, "test")
        self.tab.search_var.set("test item 249")
        self.tab.refresh_list()
        # Names containing "249": 249, 1249, 2249, 2490-2499 -> 13 rows,
        # all really in the widget.
        self.assertEqual(self.tab.listbox.size(), len(self.tab.shown))
        self.assertEqual(len(self.tab.shown), 13)
        self.tab.search_var.set("")
        self.tab.refresh_list()
        self.assertEqual(self.tab.listbox.size(), 2500)


if __name__ == "__main__":
    unittest.main()
