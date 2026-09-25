#!/usr/bin/env bash
#
# run_on_android.sh — build and install the Revamp app on the connected device.
#
# WHY THIS EXISTS
#   The previous `assembleDebug` run never compiled anything. It hung for ~20 min
#   downloading the Gradle distribution, and stalled permanently at 5.78 MB of ~200 MB
#   (gradle-9.3.1-all.zip.part, frozen since 20:40:55). Separately, no `java` was on
#   PATH, so Gradle could not have run even with a complete download.
#
#   Both problems are handled here:
#     1. JAVA_HOME is pointed at the Android Studio JBR (OpenJDK 21) that already
#        exists on this machine but was never exported.
#     2. The dead partial download is cleared and the distribution is re-fetched
#        with curl, so you get a visible progress bar instead of a silent hang.
#
#   Run this from your normal terminal (NOT from the DSH sandbox, which mounts / as
#   read-only and blocks Flutter's cache and ~/.gradle writes).
#
# USAGE
#   ./run_on_android.sh              # doctor -> build -> install
#   ./run_on_android.sh --run        # additionally launch `flutter run` (hot reload)
#   ./run_on_android.sh --bin-dist   # use the smaller -bin Gradle dist (~130 MB vs ~200 MB)
#
set -euo pipefail

# ---------------------------------------------------------------- configuration
FLUTTER_ROOT="/home/shian/Documents/Programming/Flutter/Flutter SDK"
ANDROID_SDK="/home/shian/Android/Sdk"
JAVA_HOME="/opt/android-studio-panda4-linux/android-studio/jbr"
PROJECT_DIR="/home/shian/Documents/RevMap/revamp"

GRADLE_VERSION="9.3.1"
DIST_FLAVOUR="all"
LAUNCH_RUN=0

for arg in "$@"; do
  case "$arg" in
    --run)       LAUNCH_RUN=1 ;;
    --bin-dist)  DIST_FLAVOUR="bin" ;;
    -h|--help)   sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg (try --help)"; exit 1 ;;
  esac
done

# NOTE: the Flutter path contains a space. Every use of it below is quoted.
export FLUTTER_ROOT JAVA_HOME
export ANDROID_SDK ANDROID_HOME="$ANDROID_SDK"
export PATH="$FLUTTER_ROOT/flutter/bin:$JAVA_HOME/bin:$ANDROID_SDK/platform-tools:$PATH"

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$1"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$1"; }
fail() { printf '\033[1;31m[fail]\033[0m %s\n' "$1" >&2; exit 1; }

# ------------------------------------------------------------- 0. preflight
step "Preflight"
[ -d "$PROJECT_DIR" ]       || fail "project not found: $PROJECT_DIR"
[ -x "$JAVA_HOME/bin/java" ] || fail "no JDK at $JAVA_HOME"
[ -d "$FLUTTER_ROOT/flutter" ] || fail "flutter SDK not found at $FLUTTER_ROOT"

echo "JDK:      $("$JAVA_HOME/bin/java" -version 2>&1 | head -1)"
echo "Flutter:  $FLUTTER_ROOT/flutter"
echo "Project:  $PROJECT_DIR"

if [ ! -w "$FLUTTER_ROOT/flutter/bin/cache" ]; then
  fail "Flutter's cache is NOT writable.
       You are probably running inside the DSH sandbox, which mounts / read-only.
       Run this script from your own terminal instead."
fi
if [ ! -w "$HOME/.gradle" ]; then
  fail "~/.gradle is NOT writable (same read-only-sandbox cause)."
fi

# ------------------------------------------------- 1. verify the device is ready
step "Checking for a connected device"
DEVICES="$(adb devices | awk 'NR>1 && $2=="device" {print $1}')"
[ -n "$DEVICES" ] || fail "no device. Check USB debugging, then: adb devices"
echo "found: $DEVICES"
for d in $DEVICES; do
  echo "  $d  Android $(adb -s "$d" shell getprop ro.build.version.release | tr -d '\r')" \
       "(SDK $(adb -s "$d" shell getprop ro.build.version.sdk | tr -d '\r')," \
       "$(adb -s "$d" shell getprop ro.product.cpu.abi | tr -d '\r'))"
done

# ------------------------------------- 2. re-fetch the Gradle distribution
# The wrapper hangs silently on a stalled download, so fetch it ourselves first.
DIST_DIR="$HOME/.gradle/wrapper/dists/gradle-$GRADLE_VERSION-$DIST_FLAVOUR"
if [ "$DIST_FLAVOUR" = "all" ]; then
  DIST_DIR="$DIST_DIR/9ot9r568e8zfvvd4mn8rbu1j0"   # wrapper's hash of the -all URL
else
  DIST_DIR="$DIST_DIR"                              # -bin hashes differently; let the wrapper handle it
fi
ZIP="$DIST_DIR/gradle-$GRADLE_VERSION-$DIST_FLAVOUR.zip"

step "Gradle $GRADLE_VERSION-$DIST_FLAVOUR distribution"
if [ -f "$ZIP" ]; then
  echo "already present: $ZIP"
else
  echo "clearing the stalled partial download..."
  # the .part is the corpse of the previous 20-minute hang
  find "$HOME/.gradle/wrapper/dists" -name '*.part' -o -name '*.lck' 2>/dev/null \
    | while read -r f; do echo "  removing $f"; rm -f "$f"; done

  URL="https://services.gradle.org/distributions/gradle-$GRADLE_VERSION-$DIST_FLAVOUR.zip"
  echo "downloading (this stalled last time — it is ~200 MB):"
  echo "  $URL"
  mkdir -p "$DIST_DIR"
  # --continue resumes rather than restarting if the connection drops again
  curl -L --fail --retry 5 --retry-delay 3 --continue-at - \
       -o "$ZIP" "$URL" \
    || fail "download failed. Re-run this script; curl will resume where it stopped."
  echo "done: $(du -h "$ZIP" | cut -f1)"
fi

# ------------------------------------------------------------- 3. flutter doctor
step "flutter doctor"
flutter doctor -v 2>&1 | grep -vE '^\s*$' || true

# ---------------------------------------------------------------- 4. build
step "Building debug APK"
echo "memory check: $(free -h | awk '/^Mem:/{print $7" available"}')"
AVAIL_GB=$(free -g | awk '/^Mem:/{print $7}')
if [ "${AVAIL_GB:-0}" -lt 4 ]; then
  warn "Only ~${AVAIL_GB}GB RAM free, but android/gradle.properties requests -Xmx8G."
  warn "It will start (heap is a cap, not a reservation) but may thrash or OOM."
  warn "To be safe, lower it:  sed -i 's/-Xmx8G/-Xmx2G/' android/gradle.properties"
fi

# assembleDebug only, matching the task that originally hung
( cd "$PROJECT_DIR" && flutter build apk --debug )

APK="$PROJECT_DIR/build/app/outputs/flutter-apk/app-debug.apk"
[ -f "$APK" ] || fail "expected APK not produced at $APK"
echo "built: $APK ($(du -h "$APK" | cut -f1))"

# --------------------------------------------------------------- 5. install
step "Installing to device"
for d in $DEVICES; do
  echo "installing on $d ..."
  adb -s "$d" install -r "$APK"
done

# ------------------------------------------------------------------ 6. launch
if [ "$LAUNCH_RUN" -eq 1 ]; then
  step "flutter run (hot reload: r, quit: q)"
  cd "$PROJECT_DIR" && flutter run -d "$(echo "$DEVICES" | head -1)"
else
  step "Done"
  echo "Launch it from the device's app drawer, or re-run with:  ./run_on_android.sh --run"
fi
