#!/bin/bash
# Makes iPhoneOS9.3-armv7.sdk: theos's iOS 9.3 SDK with stubs that today's Xcode links armv7 against.
#   tools/make_sdk.sh [dir]     (default ~/sdks)
set -euo pipefail
DEST="${1:-$HOME/sdks}"
mkdir -p "$DEST"
cd "$DEST"
[ -d theos-sdks ] || git clone -q --depth 1 --filter=blob:none --sparse https://github.com/theos/sdks.git theos-sdks
git -C theos-sdks sparse-checkout set iPhoneOS9.3.sdk
rm -rf iPhoneOS9.3-armv7.sdk
cp -R theos-sdks/iPhoneOS9.3.sdk iPhoneOS9.3-armv7.sdk

# The old .tbd stubs also list i386/x86_64, so tapi reads them as iOS Simulator and ld refuses
# them. Keep only armv7 and mark it as real iOS.
find iPhoneOS9.3-armv7.sdk -name '*.tbd' -type f | while IFS= read -r f; do
    xcrun llvm-readtapi --extract --arch=armv7 --filetype=tbd-v4 "$f" --o="$f.new"
    sed -i '' 's/armv7-ios-simulator/armv7-ios/g' "$f.new"
    mv "$f.new" "$f"
done

# theos's stubs lack the armv7 string and memory routines (strcmp, memcpy, ...). On the device
# they come through libSystem's re-exports, so declaring them in libsystem_platform is enough.
perl -0pi -e 's/symbols:(\s+)\[ /symbols:$1\[ _bcmp, _bzero, _memccpy, _memchr, _memcmp, _memcpy, _memmove, _memset, _memset_pattern4, _memset_pattern8, _memset_pattern16, _strchr, _strcmp, _strncmp, /' \
    iPhoneOS9.3-armv7.sdk/usr/lib/system/libsystem_platform.tbd

echo "made $DEST/iPhoneOS9.3-armv7.sdk"
