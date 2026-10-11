"""Headless connection test. Run: python -m bridge.selftest (game must be running)."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from bridge.game_path import find_data_dir
from bridge.protocol import BridgeClient, BridgeError, BridgeTimeout


def main():
    d = find_data_dir()
    print("data dir:", d or "NOT FOUND")
    if not d:
        print("Set DD2_BRIDGE_GAME_DIR or pass the folder manually.")
        return 1
    client = BridgeClient(d)
    try:
        pong = client.ping(timeout=10)
    except (BridgeError, BridgeTimeout) as e:
        print("PING FAILED:", e)
        return 1
    print("pong:", pong)
    if "1.22" not in pong:
        print("WARNING: version mismatch, expected 1.22.x")
        return 1
    print("SELFTEST OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
