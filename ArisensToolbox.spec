# ArisensToolbox.spec — PyInstaller build for Arisen's Toolbox.
# Build on Windows with: build.bat  (or: pyinstaller --noconfirm ArisensToolbox.spec)

block_cipher = None

a = Analysis(
    ['main.py'],
    pathex=[],
    binaries=[],
    datas=[
        ('bridge/data', 'bridge/data'),   # bundled ddbridge.lua + version.txt
        ('assets/icon.ico', 'assets'),    # window icon at runtime
    ],
    hiddenimports=[],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[
        # heavy packages that are never imported — belt and suspenders
        'matplotlib', 'numpy', 'pandas', 'scipy', 'sklearn',
        'pytest', 'nose', 'sphinx',
        'PyQt5', 'PyQt6', 'PySide2', 'PySide6', 'wx',
    ],
    win_no_prefer_redirects=False,
    win_private_assemblies=False,
    cipher=block_cipher,
    noarchive=False,
)

pyz = PYZ(a.pure, a.zipped_data, cipher=block_cipher)

exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.zipfiles,
    a.datas,
    [],
    name='ArisensToolbox',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,                     # set True + put upx.exe on PATH for smaller exe
    upx_exclude=[],
    runtime_tmpdir=None,
    console=False,                 # windowed: no console popup
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
    icon='assets/icon.ico',
)
