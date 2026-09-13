# To-Board

Turn a phone into a multitouch trackpad + laptop keyboard for your desktop.

- **Linux (daemon `native/main.c`)**: libei (Wayland portal) → uinput
  (`/dev/uinput`, raw multitouch) → XTest (X11).
- **Windows (daemon `native/win_helper.c`)**: injects via `SendInput`.
  No virtual-touchpad API exists, so the app uses its synthetic-gesture mode
  (`backend=win32`); gesture interpretation happens on the phone.

## Building the Windows daemon

Requires MinGW-w64 gcc (tested against MSYS2's
`mingw-w64-x86_64-gcc`):

```bat
native\build_windows.bat
```

## Windows one-stop setup (`native\setup.bat`)

Copy `setup.bat` (and ideally `touchpad-helper.exe` too — it's not committed,
see `.gitignore`) to the target PC, then double-click it. It will:

1. find the daemon (next to the script, or build in `build\` automatically),
2. open inbound TCP 4321 in Windows Firewall (one UAC prompt),
3. ask whether to auto-start the daemon at login (adds a
   `touchpad-daemon.bat` to the Startup folder),
4. start the daemon on `0.0.0.0:4321`.

Run it as Administrator once on any Windows machine to use the phone over
hotspot/LAN. For the exe alone, copy to another PC just
`touchpad-helper.exe` and run: `touchpad-helper.exe --listen 4321 --host 0.0.0.0`

Runs as a local helper (auto-started by the desktop app) or, to serve a
phone:

```bat
native\build\touchpad-helper.exe --listen 4321
```

- **USB phone (adb reverse)**: keep the loopback default and run
  `native/adb-reverse.sh` (Linux) or `native\adb-reverse.cmd` (Windows).
- **Hotspot / LAN (wireless)**: listen on all interfaces so the phone can
  connect straight over the network:

  **Linux**:
  ```bash
  make -C native
  native/touchpad-helper --listen 4321 --host 0.0.0.0
  sudo ufw allow 4321/tcp   # (or open port 4321 in your firewall once)
  ```

  **Windows**:
  ```bat
  native\build_windows.bat
  native\build\touchpad-helper.exe --listen 4321 --host 0.0.0.0
  netsh advfirewall firewall add rule name="Touchpad-4321" dir=in action=allow protocol=TCP localport=4321
  ```

  On the phone, open Settings → **Daemon (laptop IP)** → **Scan** to
  auto-discover the laptop on the same hotspot/wifi, or type its IP manually.
  Blank falls back to USB + adb reverse. The laptop must be on the same
  subnet as the phone's hotspot (by default an Android hotspot puts itself
  at `192.168.43.1` and clients in `192.168.43.0/24`).

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
