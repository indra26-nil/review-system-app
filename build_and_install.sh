#!/usr/bin/env bash
# Rebuild the debug APK and install it on the connected device.
# Wraps the sandbox-specific environment (see .toolchain/env.sh for why each var exists).
set -euo pipefail
PROJ="/home/shian/Documents/RevMap/revamp"
. "$PROJ/.toolchain/env.sh"
cd "$PROJ"

TARGET="${1:-android-arm64}"   # your device is arm64-v8a

echo "flutter : $FLUTTER_ROOT"
echo "jdk     : $JAVA_HOME"
echo "sdk     : $ANDROID_SDK"
echo "pub     : $PUB_CACHE"
echo "target  : $TARGET"
echo

DEV="$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')"
[ -n "$DEV" ] || { echo "no device connected"; exit 1; }

APK="build/app/outputs/flutter-apk/app-debug.apk"
LOG=".toolchain/build-last.log"
mkdir -p .toolchain

echo "building ..."
if ! flutter build apk --debug --target-platform "$TARGET" 2>&1 | tee "$LOG"; then
  echo "BUILD FAILED - see $LOG" >&2
  grep -A12 "What went wrong" "$LOG" >&2 || true
  exit 1
fi

# `flutter build` can exit 0 while printing nothing but a failure banner, and
# `adb install` happily reinstalls the PREVIOUS apk. Verify the artefact was
# actually rewritten before installing, so a failed build can never masquerade
# as a successful deploy.
if ! grep -q "✓ Built" "$LOG"; then
  echo "BUILD FAILED (no 'Built' line) - not installing the stale APK." >&2
  grep -A12 "What went wrong" "$LOG" >&2 || tail -20 "$LOG" >&2
  exit 1
fi
[ -f "$APK" ] || { echo "APK not produced" >&2; exit 1; }

echo "installing on $DEV ..."
if ! adb -s "$DEV" install -r "$APK"; then
  echo "INSTALL FAILED" >&2
  exit 1
fi

# A reinstall resets runtime permissions on some Android versions, which
# silently breaks "my location". Re-grant so a redeploy is not a regression.
for p in ACCESS_FINE_LOCATION ACCESS_COARSE_LOCATION; do
  adb -s "$DEV" shell pm grant com.example.revamp "android.permission.$p" 2>/dev/null || true
done

adb -s "$DEV" shell am force-stop com.example.revamp
adb -s "$DEV" shell am start -n com.example.revamp/.MainActivity
sleep 8
echo "launched. pid: $(adb -s "$DEV" shell pidof com.example.revamp)"
