#!/usr/bin/env bash
# Rebuild the debug APK and install it on the connected device.
# Wraps the sandbox-specific environment (see .toolchain/env.sh for why each var exists).
set -euo pipefail
PROJ="/home/shian/Documents/RevMap/revamp"
. "$PROJ/.toolchain/env.sh"
cd "$PROJ"

TARGET="${1:-android-arm64}"   # your device is arm64-v8a

# --------------------------------------------------------------------- config
# Read a key from .env. Empty when absent, so a missing value is reported here
# rather than silently producing an app pointed at the wrong backend.
#
# Whitespace around the value is trimmed and surrounding quotes are stripped:
# a stray space after "=" is an easy typo to make and produces a URL that
# silently fails much later, with a confusing error.
env_value() {
  local key="$1" raw
  [ -f "$PROJ/.env" ] || return 0
  raw="$(sed -n "s/^${key}=//p" "$PROJ/.env" | head -1)"
  raw="${raw#"${raw%%[![:space:]]*}"}"    # leading whitespace
  raw="${raw%"${raw##*[![:space:]]}"}"    # trailing whitespace
  # Drop one layer of matching quotes.
  if [[ "$raw" == \"*\" || "$raw" == \'*\' ]]; then
    raw="${raw:1:${#raw}-2}"
  fi
  printf '%s' "$raw"
}

SUPABASE_URL="$(env_value SUPABASE_URL)"
SUPABASE_ANON_KEY="$(env_value SUPABASE_ANON_KEY)"
DEMO_MODE="$(env_value DEMO_MODE)"
DEMO_MODE="${DEMO_MODE:-false}"

echo "flutter : $FLUTTER_ROOT"
echo "jdk     : $JAVA_HOME"
echo "sdk     : $ANDROID_SDK"
echo "pub     : $PUB_CACHE"
echo "target  : $TARGET"
echo "demo    : $DEMO_MODE"

# Report incomplete config loudly, but still build: an unconfigured app is a
# valid state (it runs on sample data) and should not block a build.
MISSING=()
[ -n "$SUPABASE_URL" ]      || MISSING+=("SUPABASE_URL")
[ -n "$SUPABASE_ANON_KEY" ] || MISSING+=("SUPABASE_ANON_KEY")
if [ ${#MISSING[@]} -gt 0 ]; then
  echo "config  : INCOMPLETE - missing: ${MISSING[*]}"
  echo "          copy .env.example to .env and fill it in."
  echo "          the app will run on sample data until you do."
else
  echo "config  : Supabase connected"
fi
echo

DEV="$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')"
[ -n "$DEV" ] || { echo "no device connected"; exit 1; }

APK="build/app/outputs/flutter-apk/app-debug.apk"
LOG=".toolchain/build-last.log"
mkdir -p .toolchain

# ---------------------------------------------------------------------- build
# Keys reach the app only as compile-time defines, never in source.
DEFINES=(
  "--dart-define=SUPABASE_URL=$SUPABASE_URL"
  "--dart-define=SUPABASE_ANON_KEY=$SUPABASE_ANON_KEY"
  "--dart-define=DEMO_MODE=$DEMO_MODE"
)

echo "building ..."
if ! flutter build apk --debug --target-platform "$TARGET" \
     "${DEFINES[@]}" 2>&1 | tee "$LOG"; then
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
