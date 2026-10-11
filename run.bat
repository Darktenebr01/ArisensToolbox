@echo off
python --version >nul 2>&1
if errorlevel 1 (
    echo ERROR: Python not found. Install it from https://www.python.org/downloads/
    echo Make sure to check "Add python.exe to PATH" during install.
    pause
    exit /b 1
)
pip install --quiet customtkinter
python main.py
pause
