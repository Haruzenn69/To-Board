# touchpad

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

Runs as a local helper (auto-started by the desktop app) or, to serve an
Android phone over USB:

```bat
native\build\touchpad-helper.exe --listen 4321
native\adb-reverse.cmd
```

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
