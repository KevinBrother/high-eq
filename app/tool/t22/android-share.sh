#!/usr/bin/env bash
# Only target a disposable emulator. Do not inspect clipboard, messages, logs or external storage.
set -euo pipefail
serial=${1:?usage: android-share.sh emulator-5554}
[[ $serial == emulator-* ]] && [[ $(adb -s "$serial" shell getprop ro.kernel.qemu | tr -d '\r') == 1 ]] || { echo 'Disposable Android emulator required' >&2; exit 2; }
adb -s "$serial" shell am start -W -a android.intent.action.SEND -t text/plain --es android.intent.extra.TEXT T22-synthetic-share -p cn.higheq.high_eq
