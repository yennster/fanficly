#!/bin/bash
# Put a simulator into (or out of) "marketing mode" for screenshots and app
# previews:
#
#   on   US region (so the status-bar clock reads "9:41", not "09:41"),
#        light appearance, Apple's 9:41 status bar with full signal and battery.
#        Saves the simulator's previous region so `off` can restore it.
#   off  Clears the status-bar override and restores the saved region.
#
# Usage: bin/sim-marketing-mode.sh on|off "<simulator name or UDID>"
# Prints the UDID on stdout, so callers can target `-destination id=<udid>`.
# Changing the region needs a reboot, so `on` may cycle the simulator. Status-bar
# overrides don't survive a shutdown, so run `on` AFTER anything that reboots it.
# App number formatting comes from the tests' own -AppleLocale launch argument.
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$(dirname "$0")/.."

mode="${1:?on|off}"
sim="${2:?simulator name or UDID}"
if [[ "$sim" =~ ^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$ ]]; then
    udid="$sim"
else
    udid=$(xcrun simctl list devices available | grep -F "$sim (" | head -1 \
        | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' | head -1)
    [ -n "$udid" ] || { echo "no available simulator named '$sim'" >&2; exit 1; }
fi
mkdir -p build
saved="build/.sim-region-$udid"

boot() {
    xcrun simctl boot "$udid" 2>/dev/null || true
    xcrun simctl bootstatus "$udid" -b >/dev/null
}
region() { xcrun simctl spawn "$udid" defaults read -g AppleLocale 2>/dev/null || true; }

case "$mode" in
on)
    boot
    current=$(region)
    if [ "$current" != "en_US" ]; then
        [ -f "$saved" ] || printf '%s' "$current" > "$saved"
        xcrun simctl spawn "$udid" defaults write -g AppleLocale -string en_US
        xcrun simctl shutdown "$udid"
        boot
    fi
    xcrun simctl ui "$udid" appearance light
    xcrun simctl status_bar "$udid" override --time "9:41" \
        --dataNetwork wifi --wifiMode active --wifiBars 3 \
        --cellularMode active --cellularBars 4 \
        --batteryState discharging --batteryLevel 100
    ;;
off)
    xcrun simctl status_bar "$udid" clear 2>/dev/null || true
    if [ -f "$saved" ]; then
        previous=$(cat "$saved")
        boot
        if [ -n "$previous" ]; then
            xcrun simctl spawn "$udid" defaults write -g AppleLocale -string "$previous"
        else
            xcrun simctl spawn "$udid" defaults delete -g AppleLocale 2>/dev/null || true
        fi
        rm -f "$saved"
    fi
    ;;
*)
    echo "usage: $0 on|off <simulator>" >&2
    exit 2
    ;;
esac
echo "$udid"
