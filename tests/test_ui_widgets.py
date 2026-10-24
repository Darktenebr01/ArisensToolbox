"""Widget-level regression tests for the design system."""
import unittest

try:
    import tkinter as tk

    import customtkinter  # noqa: F401
    _root = tk.Tk()
    _root.withdraw()
    _TK_OK = True
except Exception:  # noqa: BLE001
    _TK_OK = False


@unittest.skipUnless(_TK_OK, "no Tk display available")
class WidgetTests(unittest.TestCase):
    def tearDown(self):
        for child in _root.winfo_children():
            child.destroy()

    def test_list_panel_toggles_empty_state(self):
        from ui.widgets import ListPanel
        panel = ListPanel(_root, height=3, empty="nothing here")
        panel.pack()
        _root.update()
        self.assertEqual(panel._empty.winfo_manager(), "place")

        panel.set_rows(["one", "two"])
        _root.update()
        self.assertEqual(panel._empty.winfo_manager(), "")
        self.assertEqual(panel.listbox.size(), 2)

        panel.set_rows([])
        _root.update()
        self.assertEqual(panel._empty.winfo_manager(), "place")

    def test_page_header_is_compact(self):
        from ui.widgets import PageHeader
        header = PageHeader(_root, "Title", "One line of description.")
        header.pack(fill="x")
        _root.update_idletasks()
        self.assertLess(header.winfo_reqheight(), 90)

    def test_theme_fonts_are_tuples(self):
        from ui import theme as T
        font = T.font(T.SIZE_BODY, "bold")
        self.assertEqual(len(font), 3)
        self.assertEqual(font[1], T.SIZE_BODY)

    def test_slim_scrollbar_hides_when_content_fits(self):
        from ui.widgets import SlimScrollbar
        bar = SlimScrollbar(_root, command=lambda *_a: None)
        bar.pack(fill="y")
        bar.set(0.0, 1.0)
        _root.update_idletasks()
        self.assertEqual(bar.itemcget(bar._line, "state"), "hidden")
        bar.set(0.2, 0.6)
        self.assertEqual(bar.itemcget(bar._line, "state"), "normal")


if __name__ == "__main__":
    unittest.main()
