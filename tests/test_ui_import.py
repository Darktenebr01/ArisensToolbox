import unittest

try:
    import customtkinter  # noqa: F401
except ImportError:
    customtkinter = None


@unittest.skipIf(customtkinter is None, "customtkinter is not installed")
class UIImportTests(unittest.TestCase):
    def test_all_ui_modules_import(self):
        # Importing ui.app pulls in every tab and ui.base; this catches
        # missing imports / class-base mistakes without opening a window.
        import ui.app  # noqa: F401
        import ui.base  # noqa: F401
        import ui.widgets  # noqa: F401


if __name__ == "__main__":
    unittest.main()
