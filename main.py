"""Arisen's Toolbox standalone client - entry point."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ui.app import BridgeApp


def main():
    app = BridgeApp()
    app.mainloop()


if __name__ == "__main__":
    main()
