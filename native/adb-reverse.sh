#!/usr/bin/env bash
# Keep `adb reverse tcp:4321 tcp:4321` alive for the virtual touchpad.
# Runs as the logged-in user so it reuses the user's adb server and keys
# (no separate root server, no new RSA authorization prompt).
while true; do
    adb wait-for-device 2>/dev/null || { sleep 2; continue; }
    adb reverse tcp:4321 tcp:4321 2>/dev/null
    sleep 2
done