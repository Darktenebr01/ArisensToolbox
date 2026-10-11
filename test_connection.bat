@echo off
echo Arisen's Toolbox - connection self-test
echo (make sure the game is running with ddbridge.lua loaded)
echo.
python --version >nul 2>&1
if errorlevel 1 (
    echo ERROR: Python not found. Install it from https://www.python.org/downloads/
    echo Make sure to check "Add python.exe to PATH" during install.
    pause
    exit /b 1
)
python -m bridge.selftest
echo.
pause
