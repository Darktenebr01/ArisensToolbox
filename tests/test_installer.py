import io
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock

from bridge import installer


def make_zip(payload):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("REFramework/dinput8.dll", payload)
    return buf.getvalue()


OLD_REFW = b"REFramework previous nightly " + b"o" * 300_000


class InstallerTests(unittest.TestCase):
    def test_extracts_only_dinput8(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "ref.zip"
            path.write_bytes(make_zip(b"x" * installer.REFW_MIN_BYTES))
            self.assertEqual(installer._extract_dinput8(str(path)),
                             b"x" * installer.REFW_MIN_BYTES)

    def test_rejects_small_dll(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "ref.zip"
            path.write_bytes(make_zip(b"not a real dll"))
            with self.assertRaises(RuntimeError):
                installer._extract_dinput8(str(path))

    def test_failed_download_leaves_existing_dll_alone(self):
        with tempfile.TemporaryDirectory() as td:
            game = Path(td)
            dest = game / "dinput8.dll"
            dest.write_bytes(OLD_REFW)

            def fake_download(_url, out, _progress):
                Path(out).write_bytes(make_zip(b"tiny"))

            with mock.patch.object(installer, "_download", fake_download):
                with self.assertRaises(RuntimeError):
                    installer.download_reframework(str(game), lambda _m: None)

            self.assertEqual(dest.read_bytes(), OLD_REFW)
            self.assertFalse((game / "dinput8.dll.new").exists())

    def test_successful_install_replaces_and_backs_up(self):
        with tempfile.TemporaryDirectory() as td:
            game = Path(td)
            dest = game / "dinput8.dll"
            dest.write_bytes(OLD_REFW)
            new_data = b"REFramework new " + b"n" * installer.REFW_MIN_BYTES

            def fake_download(_url, out, _progress):
                Path(out).write_bytes(make_zip(new_data))

            with mock.patch.object(installer, "_download", fake_download):
                installer.download_reframework(str(game), lambda _m: None)

            self.assertEqual(dest.read_bytes(), new_data)
            backups = list(game.glob("dinput8.dll.bak"))
            self.assertEqual(len(backups), 1)
            self.assertEqual(backups[0].read_bytes(), OLD_REFW)
            self.assertFalse((game / "dinput8.dll.new").exists())

    def test_foreign_dll_is_never_replaced(self):
        """A dinput8.dll without REFramework markers (another mod's
        proxy) must survive a refresh attempt untouched."""
        with tempfile.TemporaryDirectory() as td:
            game = Path(td)
            dest = game / "dinput8.dll"
            foreign = b"some other mod proxy " + b"f" * 300_000
            dest.write_bytes(foreign)
            new_data = b"REFramework new " + b"n" * installer.REFW_MIN_BYTES

            def fake_download(_url, out, _progress):
                Path(out).write_bytes(make_zip(new_data))

            with mock.patch.object(installer, "_download", fake_download):
                with self.assertRaises(RuntimeError):
                    installer.download_reframework(str(game), lambda _m: None)

            self.assertEqual(dest.read_bytes(), foreign)
            self.assertFalse((game / "dinput8.dll.bak").exists())

    def test_looks_like_reframework(self):
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "dinput8.dll"
            p.write_bytes(b"xx REFramework yy")
            self.assertTrue(installer.looks_like_reframework(str(p)))
            p.write_bytes(b"plain proxy bytes")
            self.assertFalse(installer.looks_like_reframework(str(p)))
            self.assertFalse(
                installer.looks_like_reframework(str(Path(td) / "gone")))


if __name__ == "__main__":
    unittest.main()
