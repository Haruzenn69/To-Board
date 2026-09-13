@echo off
rem ------------------------------------------------------------------
rem One-stop Windows setup for the touchpad LAN daemon.
rem  - locates touchpad-helper.exe (next to this script, or in build\)
rem  - opens inbound TCP 4321 in Windows Firewall (needs admin once)
rem  - optionally registers the daemon to start at login
rem  - starts the daemon right now
rem ------------------------------------------------------------------
setlocal
title Touchpad helper setup

set "HERE=%~dp0"

rem ---- locate the daemon --------------------------------------------------
set "EXE="
if exist "%HERE%touchpad-helper.exe"       set "EXE=%HERE%touchpad-helper.exe"
if exist "%HERE%build\touchpad-helper.exe" set "EXE=%HERE%build\touchpad-helper.exe"

if defined EXE goto :found
if not exist "%HERE%build_windows.bat" goto :nofind

echo touchpad-helper.exe not found next to setup.bat.
echo Building it now...
call "%HERE%build_windows.bat"
if exist "%HERE%build\touchpad-helper.exe" set "EXE=%HERE%build\touchpad-helper.exe"
if defined EXE goto :found

:nofind
echo.
echo Could not find touchpad-helper.exe. Copy setup.bat next to the exe
echo and re-run, or run build_windows.bat first.
echo.
pause
exit /b 1

:found
echo Using daemon: %EXE%
echo.

rem ---- firewall rule (elevated, once) ------------------------------------
echo [1/3] Firewall...
netsh advfirewall firewall show rule name="Touchpad-4321" >nul 2>&1
if errorlevel 1 goto :addrule
echo       Rule Touchpad-4321 already exists.
goto :afterfire

:addrule
echo       Adding rule 'Touchpad-4321' (inbound TCP 4321) - accept the UAC prompt.
powershell -NoProfile -Command "Start-Process netsh -ArgumentList 'advfirewall','firewall','add','rule','name=Touchpad-4321','dir=in','action=allow','protocol=TCP','localport=4321' -Verb RunAs -Wait"
netsh advfirewall firewall show rule name="Touchpad-4321" >nul 2>&1
if errorlevel 1 echo       WARNING: rule not created. Run this script as Administrator (right-click, Run as administrator).
:afterfire
echo.

rem ---- optional startup registration -------------------------------------
echo [2/3] Auto-start on login?
set /P ADD=[Y/N]? 
if /I "%ADD%"=="Y" goto :addstartup
echo       Skipped.
goto :afterstart

:addstartup
set "STARTUP=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup"
>  "%STARTUP%\touchpad-daemon.bat" echo @echo off
>> "%STARTUP%\touchpad-daemon.bat" echo start "" /min "%EXE%" --listen 4321 --host 0.0.0.0
echo       Added touchpad-daemon.bat to your Startup folder.
:afterstart
echo.

rem ---- start it now ------------------------------------------------------
echo [3/3] Starting daemon...
netstat -ano | findstr ":4321" | findstr "LISTENING" >nul 2>&1
if errorlevel 1 goto :launch
echo       Port 4321 already in use - daemon may already be running.
goto :done

:launch
start "" /min "%EXE%" --listen 4321 --host 0.0.0.0
echo       Daemon launching in background on 0.0.0.0:4321.

:done
echo.
echo Done. On the phone: open the app, Settings, tap Scan.
echo It should discover this laptop on the same hotspot/wifi and connect.
echo.
pause