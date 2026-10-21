import io
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock

from ui.tabs import connection


def make_zip(payload):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("REFramework/dinput8.dll", payload)
    return buf.getvalue()


class InstallerTests(unittest.TestCase):
    def test_extracts_only_dinput8(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "ref.zip"
            path.write_bytes(make_zip(b"x" * connection.REFW_MIN_BYTES))
            self.assertEqual(connection._extract_dinput8(str(path)),
                             b"x" * connection.REFW_MIN_BYTES)

    def test_rejects_small_dll(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "ref.zip"
            path.write_bytes(make_zip(b"not a real dll"))
            with self.assertRaises(RuntimeError):
                connection._extract_dinput8(str(path))

    def test_failed_download_leaves_existing_dll_alone(self):
        with tempfile.TemporaryDirectory() as td:
            game = Path(td)
            dest = game / "dinput8.dll"
            dest.write_bytes(b"old working dll")

            def fake_download(_url, out, _progress):
                Path(out).write_bytes(make_zip(b"tiny"))

            with mock.patch.object(connection, "_download", fake_download):
                with self.assertRaises(RuntimeError):
                    connection.download_reframework(str(game), lambda _m: None)

            self.assertEqual(dest.read_bytes(), b"old working dll")
            self.assertFalse((game / "dinput8.dll.new").exists())

    def test_successful_install_replaces_and_backs_up(self):
        with tempfile.TemporaryDirectory() as td:
            game = Path(td)
            dest = game / "dinput8.dll"
            dest.write_bytes(b"old working dll")
            new_data = b"n" * connection.REFW_MIN_BYTES

            def fake_download(_url, out, _progress):
                Path(out).write_bytes(make_zip(new_data))

            with mock.patch.object(connection, "_download", fake_download):
                connection.download_reframework(str(game), lambda _m: None)

            self.assertEqual(dest.read_bytes(), new_data)
            backups = list(game.glob("dinput8.dll.bak"))
            self.assertEqual(len(backups), 1)
            self.assertEqual(backups[0].read_bytes(), b"old working dll")
            self.assertFalse((game / "dinput8.dll.new").exists())


if __name__ == "__main__":
    unittest.main()
