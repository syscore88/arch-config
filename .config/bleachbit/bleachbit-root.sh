#!/bin/sh

if [ "$(id -u)" -eq 0 ]; then
    exec bleachbit
fi

if command -v xhost >/dev/null 2>&1; then
    xhost +SI:localuser:root >/dev/null 2>&1
    trap 'xhost -SI:localuser:root >/dev/null 2>&1' EXIT
fi

if command -v pkexec >/dev/null 2>&1; then
    pkexec env DISPLAY="$DISPLAY" XAUTHORITY="$XAUTHORITY" bleachbit
elif command -v sudo >/dev/null 2>&1; then
    sudo -E bleachbit
elif command -v doas >/dev/null 2>&1; then
    doas env DISPLAY="$DISPLAY" XAUTHORITY="$XAUTHORITY" bleachbit
else
    su -c "DISPLAY='$DISPLAY' XAUTHORITY='$XAUTHORITY' bleachbit"
fi