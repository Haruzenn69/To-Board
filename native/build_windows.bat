@echo off
rem Build the Windows input daemon. Requires MinGW-w64 gcc (e.g. MSYS2).
rem Usage:  build_windows.bat   or   CC=C:\path\to\gcc.exe build_windows.bat
setlocal

if defined CC ( set "GCC=%CC%" ) else ( set "GCC=C:\msys64\mingw64\bin\gcc.exe" )
if not exist "%GCC%" ( set "GCC=gcc.exe" )

rem gcc driver spawns cc1/as which need the mingw runtime DLLs on PATH.
if exist "C:\msys64\mingw64\bin" set "PATH=C:\msys64\mingw64\bin;%PATH%"

echo CC=%GCC%
"%GCC%" -O2 -Wall -Wextra -std=gnu11 -o "%~dp0build\touchpad-helper.exe" "%~dp0win_helper.c" -lws2_32
if errorlevel 1 goto :fail

echo.
echo Built: %~dp0build\touchpad-helper.exe
echo Listen mode (phone via adb reverse):
echo   touchpad-helper.exe --listen 4321
exit /b 0

:fail
echo Build failed.
exit /b 1