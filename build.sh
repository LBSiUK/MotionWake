#!/bin/bash
# Builds MotionWake for 32-bit iOS 9 (armv7) and packages it as a rootful Cydia .deb.
#   ./build.sh            build build/uk.lbsi.motionwake_<version>_iphoneos-arm.deb
#   ./build.sh install    also copy it to the iPad and install it (IPAD=root@host, password alpine)
set -euo pipefail
cd "$(dirname "$0")"

VERSION=1.0.0
SDK="${SDK:-$HOME/sdks/iPhoneOS9.3-armv7.sdk}"
IPAD="${IPAD:-root@192.168.0.161}"
[ -d "$SDK" ] || { echo "missing SDK $SDK (run tools/make_sdk.sh)"; exit 1; }

# -marm: Xcode's linker no longer sets the Thumb bit on armv7 entry points, so Thumb code
# would start in ARM mode and crash. ARM-mode code has no such bit to lose.
CC=(xcrun clang -isysroot "$SDK" -arch armv7 -marm -miphoneos-version-min=9.0 -Os -Wall -Wextra
    -Wno-unused-parameter -fobjc-arc -Isrc)
quiet() { grep -v "liblaunch.dylib" || true; }

rm -rf build/root && mkdir -p build/root/DEBIAN build/root/usr/libexec build/root/Library/LaunchDaemons \
    build/root/Applications/MotionWake.app
DAEMON=build/root/usr/libexec/motionwaked
APP=build/root/Applications/MotionWake.app

"${CC[@]}" src/motionwaked.m src/motionwake.c -framework Foundation -framework AVFoundation -framework CoreMedia \
    -framework CoreVideo -framework IOKit -o "$DAEMON" 2>&1 | quiet
"${CC[@]}" app/main.m src/motionwake.c -framework Foundation -framework CFNetwork -framework UIKit -framework CoreGraphics -framework IOKit \
    -o "$APP/MotionWake" 2>&1 | quiet
[ -f "$DAEMON" ] && [ -f "$APP/MotionWake" ] || { echo "build failed"; exit 1; }

[ -f packaging/app/AppIcon76x76~ipad.png ] || swift tools/make_art.swift packaging/app
cp packaging/app/*~ipad.png "$APP/"
sed "s/@VERSION@/$VERSION/g" packaging/app/Info.plist > "$APP/Info.plist"
plutil -convert binary1 "$APP/Info.plist"
cp packaging/uk.lbsi.motionwake.plist build/root/Library/LaunchDaemons/
ldid -Spackaging/motionwaked.entitlements "$DAEMON"
ldid -S -Iuk.lbsi.motionwake "$APP/MotionWake"

sed "s/@VERSION@/$VERSION/g" packaging/control > build/root/DEBIAN/control
cp packaging/DEBIAN/postinst packaging/DEBIAN/prerm packaging/DEBIAN/postrm build/root/DEBIAN/
find build/root -name .DS_Store -delete
DEB="build/uk.lbsi.motionwake_${VERSION}_iphoneos-arm.deb"
dpkg-deb --root-owner-group -Zgzip -b build/root "$DEB" >/dev/null
echo "built $DEB"

if [ "${1:-}" = install ]; then
    O=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o PubkeyAuthentication=no
       -o ConnectTimeout=8 -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa)
    # sshpass on this host sometimes misses the first password prompt, so retry.
    retry() { for i in 1 2 3 4 5 6; do "$@" && return 0; sleep 1; done; return 1; }
    retry sshpass -p alpine scp -O "${O[@]}" "$DEB" "$IPAD:/var/root/motionwake.deb"
    retry sshpass -p alpine ssh "${O[@]}" "$IPAD" "dpkg -i /var/root/motionwake.deb && rm /var/root/motionwake.deb"
fi
