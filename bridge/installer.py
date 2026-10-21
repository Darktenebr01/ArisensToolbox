"""REFramework download/install, kept out of the UI layer.

Lives here (not in a tab module) so it can be unit-tested headless - it
must never import tkinter/customtkinter.
"""
import glob
import hashlib
import os
import shutil
import tempfile
import urllib.request
import zipfile

from version import CLIENT_VERSION

REFRAMEWORK_URL = ("https://github.com/praydog/REFramework-nightly/releases/"
                   "latest/download/REFramework.zip")
# Nightly is deliberately tracked so title updates keep working; there is no
# stable checksum to pin. We trust GitHub's TLS, validate the zip, assert a
# plausible DLL size, and keep a backup before replacing anything.
# dinput8.dll is several MB; a tiny file means an HTML error page or a
# truncated zip, so refuse to install it over a working copy.
REFW_MIN_BYTES = 200_000

# Byte markers that identify a DLL as REFramework (present in its strings).
REFW_MARKERS = (b"REFramework", b"reframework")


def file_sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def looks_like_reframework(path):
    """True when the file at ``path`` carries REFramework's markers.

    Used before replacing an existing dinput8.dll: some other mod's proxy
    DLL must never be silently overwritten (the single .bak would then be
    the only copy, and the next refresh would destroy it).
    """
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError:
        return False
    return any(marker in data for marker in REFW_MARKERS)


def _download(url, dest, progress_cb):
    """Download url to dest with a timeout and progress reporting."""
    req = urllib.request.Request(
        url, headers={"User-Agent": f"ArisensToolbox/{CLIENT_VERSION}"})
    with urllib.request.urlopen(req, timeout=30) as resp, \
            open(dest, "wb") as out:
        total = int(resp.headers.get("Content-Length") or 0)
        done = 0
        while True:
            chunk = resp.read(256 * 1024)
            if not chunk:
                break
            out.write(chunk)
            done += len(chunk)
            if total:
                pct = min(100, done * 100 // total)
                progress_cb(f"Downloading REFramework... {pct}%")


def _extract_dinput8(zip_path):
    """Return the dinput8.dll bytes from REFramework.zip, or raise."""
    with zipfile.ZipFile(zip_path, "r") as z:
        bad = z.testzip()
        if bad:
            raise RuntimeError(f"REFramework.zip is corrupt ({bad})")
        name = next((n for n in z.namelist()
                     if n.lower().endswith("dinput8.dll")), None)
        if not name:
            raise RuntimeError("dinput8.dll not found in REFramework.zip")
        data = z.read(name)
    if len(data) < REFW_MIN_BYTES:
        raise RuntimeError(
            f"dinput8.dll looks invalid ({len(data)} bytes) - download aborted")
    return data


def _backup_dll(dest):
    """Back up dest to a single ``.bak`` file, replaced on the next update."""
    backup = dest + ".bak"
    shutil.copy2(dest, backup)
    # Drop any timestamped backups left by older builds: one .bak policy.
    for old in glob.glob(dest + ".bak-*"):
        try:
            os.remove(old)
        except OSError:
            pass
    return backup


def download_reframework(game_dir, progress_cb):
    """Download REFramework.zip and extract ONLY dinput8.dll.

    The existing DLL is backed up first and the new one is swapped in with
    os.replace, so a failed download can never leave a broken install. An
    existing DLL that does not look like REFramework is never replaced:
    it may be another mod's proxy, and overwriting it (with only a single
    .bak kept) could destroy it on a later refresh.
    """
    progress_cb("Downloading REFramework...")
    tmp_zip = None
    tmp_dll = os.path.join(game_dir, "dinput8.dll.new")
    try:
        fd, tmp_zip = tempfile.mkstemp(suffix=".zip")
        os.close(fd)
        _download(REFRAMEWORK_URL, tmp_zip, progress_cb)
        progress_cb("Installing REFramework...")
        data = _extract_dinput8(tmp_zip)
        with open(tmp_dll, "wb") as f:
            f.write(data)
        dest = os.path.join(game_dir, "dinput8.dll")
        if os.path.isfile(dest):
            if not looks_like_reframework(dest):
                raise RuntimeError(
                    "The existing dinput8.dll does not look like "
                    "REFramework, so it was NOT replaced - it may belong "
                    "to another mod. Move or rename it yourself if you "
                    "want REFramework installed here.")
            backup = _backup_dll(dest)
            progress_cb(
                f"Backed up the old dinput8.dll to {os.path.basename(backup)}")
        os.replace(tmp_dll, dest)
        progress_cb("REFramework installed "
                    f"(dinput8.dll sha256 {file_sha256(dest)[:16]}...)")
    finally:
        for path in (tmp_zip, tmp_dll):
            if path:
                try:
                    os.remove(path)
                except OSError:
                    pass
