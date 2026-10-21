"""File-based IPC with ddbridge.lua.

Protocol v2:
  client -> <data>/cmd.txt :  "{id}|{command}|{arg}|...|B:{boot}|END\\n"
  game   -> <data>/resp.txt:  "{id}|OK|{payload}|END"  or  "{id}|ERR|{msg}|END"

The game writes a fresh boot token at load and returns it from ``ping``.
Every mutating command carries that token, so a ``cmd.txt`` left over from a
previous game session is rejected instead of being executed a second time.
Responses carry an ``|END`` sentinel, which lets the client distinguish a
complete response from a partially written file.

Bulk data (item lists, dumps) still travels through sidecar files.
"""
import collections
import logging
import os
import re
import threading
import time

from bridge.safety import is_mutating

POLL_INTERVAL = 0.05
RESP_SENTINEL = "|END"
STALE_SESSION = "STALE_SESSION"
BOOT_TOKEN_RE = re.compile(r"\bboot=([0-9A-Za-z_.:-]+)")
VERSION_RE = re.compile(r"pong\s+ddbridge\s+(\d+\.\d+\.\d+)")

log = logging.getLogger("arisens.bridge")


class BridgeError(Exception):
    pass


class BridgeTimeout(BridgeError):
    pass


class _StaleSession(BridgeError):
    """Internal: the game restarted while this client was connected."""


class BridgeClient:
    def __init__(self, data_dir):
        self.data_dir = data_dir
        self.cmd_path = os.path.join(data_dir, "cmd.txt")
        self.resp_path = os.path.join(data_dir, "resp.txt")
        self._counter = 0
        self._lock = threading.Lock()
        self._send_lock = threading.Lock()  # one in-flight command at a time
        self.boot_id = None          # token returned by ping (None for old Lua)
        self.bridge_version = None   # "1.89.2"
        self._boot_probed = False
        # Diagnostics: last 200 commands with timings (see safety bundle).
        self.history = collections.deque(maxlen=200)
        # Set by the app: called once, right before the first mutating
        # command of this session is written (save-backup hook).
        self.on_before_first_mutation = None
        self._mutation_hook_done = False
        # Do not replay a command that was left behind by the previous session.
        self._clear_cmd_file()

    # -- low level ------------------------------------------------------

    def _next_id(self):
        with self._lock:
            self._counter += 1
            return f"{time.time_ns()}_{self._counter}_{os.getpid() % 1000}"

    def _clear_cmd_file(self):
        try:
            os.remove(self.cmd_path)
        except OSError:
            pass

    @staticmethod
    def _arg_text(value):
        text = str(value)
        if "|" in text or "\r" in text or "\n" in text:
            raise BridgeError(
                "Command arguments cannot contain '|' or line breaks."
            )
        return text

    def _command_line(self, cmd_id, command, args, boot_id):
        parts = [cmd_id, command] + [self._arg_text(a) for a in args]
        if boot_id and command != "ping":
            parts.append(f"B:{boot_id}")
        return "|".join(parts) + "|END\n"

    def _write_cmd(self, cmd_id, command, args, boot_id=None):
        line = self._command_line(cmd_id, command, args, boot_id)
        # unique tmp name per send: concurrent threads must never share one
        tmp = f"{self.cmd_path}.{cmd_id}.tmp"
        try:
            with open(tmp, "w", encoding="utf-8") as f:
                f.write(line)
            # Windows: AV or the game can briefly hold the file; retry a few times
            last_err = None
            for _ in range(5):
                try:
                    os.replace(tmp, self.cmd_path)
                    last_err = None
                    break
                except OSError as e:
                    last_err = e
                    time.sleep(0.05)
            if last_err is not None:
                raise last_err
        except OSError as e:
            try:
                os.remove(tmp)
            except OSError:
                pass
            raise BridgeError(f"could not write cmd.txt: {e}")
        finally:
            # never leave stale tmp files behind
            try:
                os.remove(tmp)
            except OSError:
                pass

    def _read_resp(self):
        try:
            with open(self.resp_path, "r", encoding="utf-8", errors="replace") as f:
                text = f.read().strip()
        except OSError:
            return None, None, None
        if not text:
            return None, None, None
        # A response is only complete when the game's sentinel is present.
        # Without this check a read that lands mid-write can return a
        # truncated payload as if it were a successful result.
        if not text.endswith(RESP_SENTINEL):
            return None, None, None
        text = text[: -len(RESP_SENTINEL)]
        parts = text.split("|", 2)
        if len(parts) < 3:
            return None, None, None
        return parts[0], parts[1], parts[2]

    def _parse_pong(self, pong):
        m = VERSION_RE.search(pong or "")
        if m:
            self.bridge_version = m.group(1)
        m = BOOT_TOKEN_RE.search(pong or "")
        if m:
            self.boot_id = m.group(1)
        else:
            # Older Lua (pre-1.89.2) has no boot token. Keep working, but
            # the server-side replay guard is unavailable.
            self.boot_id = None

    def _read_resp_legacy(self, cmd_id):
        """One last-chance read for a pre-1.89.2 bridge (no |END sentinel).

        Only ever used for the read-only ``ping`` after the strict wait has
        already timed out, so the version check can report "old bridge in
        the running game" instead of a misleading generic timeout. All
        other commands keep the strict sentinel rule.
        """
        try:
            with open(self.resp_path, "r", encoding="utf-8",
                      errors="replace") as f:
                text = f.read().strip()
        except OSError:
            return None
        if not text or text.endswith(RESP_SENTINEL):
            return None
        parts = text.split("|", 2)
        if len(parts) == 3 and parts[0] == cmd_id and parts[1] == "OK":
            return parts[2]
        return None

    def _wait_for(self, cmd_id, command, timeout):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            rid, status, payload = self._read_resp()
            if rid == cmd_id:
                if status == "OK":
                    return payload
                if payload.strip() == STALE_SESSION:
                    raise _StaleSession(payload.strip())
                raise BridgeError(payload or "unknown error")
            time.sleep(POLL_INTERVAL)
        if command == "ping":
            legacy = self._read_resp_legacy(cmd_id)
            if legacy is not None:
                log.warning("old bridge without |END sentinel answered ping")
                return legacy
        raise BridgeTimeout(
            f"No response to '{command}' within {timeout}s. "
            "Is the game running with ddbridge.lua installed?"
        )

    def _record(self, command, args, started, result):
        self.history.append({
            "ts": time.strftime("%H:%M:%S"),
            "command": command,
            "argc": len(args),
            "ms": (time.monotonic() - started) * 1000,
            "result": result,
        })

    def _send_once(self, command, args, timeout, boot_id):
        cmd_id = self._next_id()
        started = time.monotonic()
        self._write_cmd(cmd_id, command, args, boot_id)
        try:
            payload = self._wait_for(cmd_id, command, timeout)
        except BridgeTimeout:
            log.warning("timeout after %.1fs: %s", timeout, command)
            self._record(command, args, started, "TIMEOUT")
            raise
        except BridgeError as e:
            self._record(command, args, started, f"ERR {e}")
            raise
        # The response is complete; the command file is no longer needed.
        # If this fails, the boot token still prevents a replay.
        self._clear_cmd_file()
        self._record(command, args, started, "OK")
        log.debug("%s -> %s (%.0f ms)", command, payload[:120],
                  (time.monotonic() - started) * 1000)
        return payload

    def _maybe_mutation_hook(self, command):
        """Fire the app's save-backup hook once per session, pre-mutation."""
        if self._mutation_hook_done or not is_mutating(command):
            return
        self._mutation_hook_done = True
        hook = self.on_before_first_mutation
        if hook is not None:
            try:
                hook(command)
            except Exception:
                log.exception("pre-mutation hook failed for %s", command)

    def _do_ping(self, timeout):
        pong = self._send_once("ping", (), timeout, None)
        self._parse_pong(pong)
        self._boot_probed = True
        return pong

    # -- public API -----------------------------------------------------

    def send(self, command, *args, timeout=8.0):
        """Send a command and wait for the matching response.

        Serialized: only one command is in flight at a time. When the game
        restarts, the new Lua rejects the old boot token with
        ``STALE_SESSION``; the client re-pings and retries once.

        Returns the payload string. Raises BridgeError / BridgeTimeout.
        """
        with self._send_lock:
            if command != "ping" and not self._boot_probed:
                self._do_ping(min(timeout, 8.0))
            self._maybe_mutation_hook(command)
            try:
                return self._send_once(command, args, timeout, self.boot_id)
            except _StaleSession:
                if command == "ping":
                    raise
                log.info("game session changed; reconnecting and retrying %s",
                         command)
                self._do_ping(min(timeout, 8.0))
                return self._send_once(command, args, timeout, self.boot_id)

    def ping(self, timeout=8.0):
        """Return the raw pong string, e.g. 'pong ddbridge 1.89.2 boot=...'."""
        with self._send_lock:
            return self._do_ping(timeout)

    def read_sidecar(self, filename):
        """Read a bulk-data sidecar file (items.txt, specialsweep.txt, ...)."""
        path = os.path.join(self.data_dir, filename)
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as f:
                return f.read()
        except OSError:
            return None
