"""UI smoke test: construct the app and every tab.

Runs wherever Tk can open a window (Windows, macOS, X11). On a headless
Linux runner it skips instead of failing.

The test exists because of the v0.159 Mods-tab crash: a pack() call inside a
grid-managed card killed BridgeApp.__init__ at startup. Every tab must
construct cleanly.
"""
import os
import tempfile
import unittest

try:
    import tkinter as tk

    import customtkinter  # noqa: F401
    _root = tk.Tk()
    _root.destroy()
    _TK_OK = True
except Exception:  # noqa: BLE001 - any Tk failure means "no display"
    _TK_OK = False


def _make_app():
    from ui.app import BridgeApp
    return BridgeApp()


@unittest.skipUnless(_TK_OK, "no Tk display available")
class TestUISmoke(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._config = tempfile.mkdtemp(prefix="arisens-ui-")
        os.environ.setdefault("ARISENS_CONFIG_DIR", cls._config)

    def test_every_tab_constructs(self):
        app = _make_app()
        try:
            labels = [label for _cat, label, _f in app.tabs]
            self.assertIn("Mods", labels)
            for label in labels:
                with self.subTest(tab=label):
                    app.show_tab(label)
                    app.update()
        finally:
            app._on_close()

    def test_header_is_compact(self):
        """Regression: default-sized CTk frames used to leave 200 px bands."""
        app = _make_app()
        try:
            app.show_tab("Connection")
            app.update()
            tab = app._tab_frames["Connection"]
            header = tab.winfo_children()[0]
            self.assertLess(header.winfo_height(), 110)
        finally:
            app._on_close()


if __name__ == "__main__":
    unittest.main()
