@echo off
rem Keep `adb reverse tcp:4321 tcp:4321` alive for the virtual touchpad.
:loop
adb wait-for-device 2>nul
if errorlevel 1 goto sleep
adb reverse tcp:4321 tcp:4321 2>nul
:sleep
timeout /t 2 /nobreak >nul
goto loop