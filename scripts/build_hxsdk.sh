#!/bin/bash
set -euo pipefail

# SOURCE_ROOT OUTPUT_ROOT VERSION; never writes build output into the source tag.
SOURCE_ROOT="$(cd "${1:?source root is required}" && pwd)"
mkdir -p "${2:?output root is required}"
OUTPUT_ROOT="$(cd "$2" && pwd)"
VERSION="${3:?version is required}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 1
BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/hxsdk-build.XXXXXX")"
trap 'rm -rf "$BUILD_ROOT"' EXIT

for SDK in iphoneos iphonesimulator; do
  EXTRA=()
  if [[ "$SDK" == iphonesimulator ]]; then
    EXTRA=(ARCHS=x86_64 EXCLUDED_ARCHS=arm64 ONLY_ACTIVE_ARCH=NO)
  else
    EXTRA=(ARCHS=arm64 ONLY_ACTIVE_ARCH=NO)
  fi
  xcodebuild archive \
    -workspace "$SOURCE_ROOT/Example/HXSDK.xcworkspace" \
    -scheme HXSDK -configuration Release -sdk "$SDK" \
    -archivePath "$BUILD_ROOT/$SDK.xcarchive" \
    -derivedDataPath "$BUILD_ROOT/DerivedData-$SDK" \
    SKIP_INSTALL=NO BUILD_LIBRARY_FOR_DISTRIBUTION=YES CODE_SIGNING_ALLOWED=NO \
    "${EXTRA[@]}"
done

DEVICE="$BUILD_ROOT/iphoneos.xcarchive/Products/Library/Frameworks/HXSDK.framework"
SIMULATOR="$BUILD_ROOT/iphonesimulator.xcarchive/Products/Library/Frameworks/HXSDK.framework"
test -f "$DEVICE/HXSDK"
test -f "$SIMULATOR/HXSDK"
rm -rf "$OUTPUT_ROOT/HXSDK.framework"
cp -R "$DEVICE" "$OUTPUT_ROOT/HXSDK.framework"
lipo -create "$DEVICE/HXSDK" "$SIMULATOR/HXSDK" -output "$OUTPUT_ROOT/HXSDK.framework/HXSDK"
lipo "$OUTPUT_ROOT/HXSDK.framework/HXSDK" -verify_arch arm64 x86_64
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$OUTPUT_ROOT/HXSDK.framework/Info.plist"
echo "HXSDK $VERSION framework: $OUTPUT_ROOT/HXSDK.framework"
