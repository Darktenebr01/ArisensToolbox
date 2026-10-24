@echo off
python --version >nul 2>&1
if errorlevel 1 (
    echo ERROR: Python not found. Install it from https://www.python.org/downloads/
    echo Make sure to check "Add python.exe to PATH" during install.
    pause
    exit /b 1
)
python -m pip install --quiet customtkinter
if errorlevel 1 (
    echo ERROR: could not install customtkinter - see the error above.
    pause
    exit /b 1
)
python main.py
if errorlevel 1 (
    echo ERROR: the program exited with an error - see the traceback above.
)
pause
