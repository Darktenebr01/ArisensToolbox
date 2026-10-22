"""Single source of truth for Arisen's Toolbox versions.

The Lua bridge lives in the game process and cannot import this file, so
``tests/test_versions.py`` asserts that the Lua header, pong string, log line
and ``bridge/data/version.txt`` all agree with the values below.
"""

# Desktop client version (shown in the sidebar, build artifacts, releases).
CLIENT_VERSION = "0.94"

# Game-side bridge version. Bump this whenever ddbridge.lua changes.
BRIDGE_VERSION = "1.89.3"

# Older/newer patch releases of the bridge are accepted as long as the
# protocol-compatible major version matches.
BRIDGE_MAJOR = "1.89"
