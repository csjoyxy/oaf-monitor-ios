#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS_DIR="$ROOT_DIR/ios"
BUILD_DIR="$ROOT_DIR/build"
DIST_DIR="$ROOT_DIR/dist"

echo "==> Generating Xcode project via XcodeGen..."
cd "$IOS_DIR"
xcodegen generate

echo "==> Building OAFPulse (Release, iOS 16.0+ arm64)..."
cd "$ROOT_DIR"
rm -rf "$BUILD_DIR" "$DIST_DIR"
mkdir -p "$BUILD_DIR" "$DIST_DIR"

xcodebuild \
  -project "$IOS_DIR/OAFPulse.xcodeproj" \
  -scheme OAFPulse \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath "$BUILD_DIR/DerivedData" \
  ARCHS="arm64" \
  ONLY_ACTIVE_ARCH=NO \
  IPHONEOS_DEPLOYMENT_TARGET=16.0 \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  clean build

APP_PATH="$BUILD_DIR/DerivedData/Build/Products/Release-iphoneos/OAFPulse.app"
if [ ! -d "$APP_PATH" ]; then
  echo "Error: OAFPulse.app not found at $APP_PATH" >&2
  exit 1
fi

mkdir -p "$BUILD_DIR/Payload"
cp -R "$APP_PATH" "$BUILD_DIR/Payload/OAFPulse.app"

if command -v ldid >/dev/null 2>&1; then
  echo "==> Applying TrollStore fake-sign entitlements via ldid..."
  ldid -S"$IOS_DIR/entitlements.plist" "$BUILD_DIR/Payload/OAFPulse.app/OAFPulse"
fi

echo "==> Packaging IPA and TrollStore TIPA..."
cd "$BUILD_DIR"
zip -qry "$DIST_DIR/OAFPulse-unsigned.ipa" Payload
cp "$DIST_DIR/OAFPulse-unsigned.ipa" "$DIST_DIR/OAFPulse-TrollStore.tipa"

ls -lh "$DIST_DIR"
echo "==> Build succeeded!"
