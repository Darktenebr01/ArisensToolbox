@echo off
setlocal
title Arisen's Toolbox - exe builder

echo ============================================
echo  Arisen's Toolbox - building ArisensToolbox.exe
echo  build script v0.12
echo ============================================
echo.

python --version >nul 2>&1
if errorlevel 1 (
    echo ERROR: Python not found. Install it from https://www.python.org/downloads/
    echo Check "Add python.exe to PATH" during install, then run this again.
    pause
    exit /b 1
)

echo [1/2] Installing PyInstaller...
python -m pip install "pyinstaller>=6,<7" "customtkinter==6.0.0"
if errorlevel 1 (
    echo.
    echo ERROR: pip install failed - see the error above.
    pause
    exit /b 1
)

echo [2/2] Building ArisensToolbox.exe (takes a few minutes, window stays open)...
python -m PyInstaller --noconfirm ArisensToolbox.spec
if errorlevel 1 (
    echo.
    echo ERROR: build failed - see the error above.
    pause
    exit /b 1
)

echo.
echo ============================================
for %%F in (dist\ArisensToolbox.exe) do echo  Done: %%F  (%%~zF bytes)
echo ============================================
echo.
echo Copy ArisensToolbox.exe anywhere and run it.
echo.
pause
