"""Arisen's Toolbox - entry point.

Keeps startup failures visible: a windowed build has no console, so a
crash before the window exists would otherwise look like nothing happened.
"""
import os
import sys
import traceback

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))


def _fatal(message):
    """Report a startup failure on stderr, in a dialog, and in the log."""
    print(message, file=sys.stderr)
    try:
        import tkinter.messagebox as messagebox
        messagebox.showerror("Arisen's Toolbox", message)
    except Exception:
        pass
    try:
        from bridge.game_path import config_dir
        log_path = os.path.join(config_dir(), "logs", "client.log")
        with open(log_path, "a", encoding="utf-8") as f:
            f.write("\n[startup failure]\n" + message + "\n")
    except Exception:
        pass


def main():
    try:
        from ui.app import BridgeApp
        app = BridgeApp()
    except ImportError as e:
        _fatal("Arisen's Toolbox is missing a dependency.\n\n"
               f"Details: {e}\n\n"
               "Run run.bat (it installs CustomTkinter), or:\n"
               "  python -m pip install -r requirements.txt")
        return 1
    except Exception:
        details = traceback.format_exc()
        _fatal("Arisen's Toolbox could not start.\n\n"
               + details[-1200:])
        return 1
    app.mainloop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
