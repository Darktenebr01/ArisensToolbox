"""File-based IPC with ddbridge.lua.

Protocol (mirrors the Cheat Engine table):
  client -> <data>/cmd.txt :  "{id}|{command}|{arg1}|{arg2}|...|END\\n"
  game   -> <data>/resp.txt:  "{id}|OK|{payload}"  or  "{id}|ERR|{message}"

The game polls cmd.txt ~10x/sec and ignores repeat ids. Payload newlines are
flattened to spaces by the game side; bulk data goes through sidecar files.
"""
import os
import threading
import time

BOOT_ID = "boot"
POLL_INTERVAL = 0.05


class BridgeError(Exception):
    pass


class BridgeTimeout(BridgeError):
    pass


class BridgeClient:
    def __init__(self, data_dir):
        self.data_dir = data_dir
        self.cmd_path = os.path.join(data_dir, "cmd.txt")
        self.resp_path = os.path.join(data_dir, "resp.txt")
        self._counter = 0
        self._lock = threading.Lock()
        self._send_lock = threading.Lock()  # one in-flight command at a time (like the CE table's queue)
        self._last_resp_id = None

    # -- low level ------------------------------------------------------

    def _next_id(self):
        with self._lock:
            self._counter += 1
            return f"{int(time.time()) % 1000000}_{self._counter}_{os.getpid() % 1000}"

    def _write_cmd(self, cmd_id, command, args):
        parts = [cmd_id, command] + [str(a) for a in args]
        line = "|".join(parts) + "|END\n"
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
            with open(self.resp_path, "r", encoding="utf-8") as f:
                text = f.read().strip()
        except OSError:
            return None, None, None
        if not text:
            return None, None, None
        parts = text.split("|", 2)
        if len(parts) < 3:
            return None, None, None
        return parts[0], parts[1], parts[2]

    # -- public API -----------------------------------------------------

    def send(self, command, *args, timeout=8.0):
        """Send a command and wait for the matching response.

        Serialized: only one command is in flight at a time, like the CE
        table's queue — the game processes cmd.txt single-file anyway, and
        overlapping sends would clobber each other's responses.
        Returns the payload string. Raises BridgeError / BridgeTimeout.
        """
        with self._send_lock:
            return self._send_locked(command, args, timeout)

    def _send_locked(self, command, args, timeout=8.0):
        cmd_id = self._next_id()
        self._write_cmd(cmd_id, command, args)
        deadline = time.time() + timeout
        while time.time() < deadline:
            rid, status, payload = self._read_resp()
            if rid == cmd_id:
                if status == "OK":
                    return payload
                raise BridgeError(payload or "unknown error")
            time.sleep(POLL_INTERVAL)
        raise BridgeTimeout(
            f"No response to '{command}' within {timeout}s. "
            "Is the game running with ddbridge.lua installed?"
        )

    def ping(self, timeout=8.0):
        """Returns the raw pong string, e.g. 'pong ddbridge 1.22.0'."""
        return self.send("ping", timeout=timeout)

    def read_sidecar(self, filename):
        """Read a bulk-data sidecar file (items.txt, specialsweep.txt, ...)."""
        path = os.path.join(self.data_dir, filename)
        try:
            with open(path, "r", encoding="utf-8") as f:
                return f.read()
        except OSError:
            return None
