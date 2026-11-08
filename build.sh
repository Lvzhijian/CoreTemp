#!/bin/bash
# Release build of 芯温. Produces a double-clickable, ad-hoc signed app.
# Requires the full Xcode app (xcodebuild + the macOS SDK). No Xcode window.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

APP="$ROOT/build/CoreTemp.app"
ZIP="$ROOT/build/CoreTemp.zip"
DERIVED="$ROOT/build/DerivedData"
PRODUCT="$DERIVED/Build/Products/Release/CoreTemp.app"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "这个脚本只能在 Mac 上运行。" >&2
  exit 1
fi

if ! xcode-select -p >/dev/null 2>&1; then
  echo "找不到开发者目录。请安装 Xcode，然后执行：" >&2
  echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
  exit 1
fi

DEVDIR="$(xcode-select -p)"
if [[ "$DEVDIR" != *".app/Contents/Developer" ]]; then
  echo "当前开发者目录是：$DEVDIR" >&2
  echo "只装 Command Line Tools 不够，需要完整的 Xcode.app。安装后执行：" >&2
  echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
  exit 1
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "找不到 xcodebuild。" >&2
  exit 1
fi

echo "使用 $(xcodebuild -version | tr '\n' ' ')"
rm -rf "$APP" "$ZIP"
mkdir -p "$ROOT/build"

xcodebuild \
  -project "$ROOT/CoreTemp.xcodeproj" \
  -scheme CoreTemp \
  -configuration Release \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_ALLOWED=YES \
  AD_HOC_CODE_SIGNING_ALLOWED=YES \
  build

if [[ ! -d "$PRODUCT" ]]; then
  echo "编译结束，但没有找到 $PRODUCT" >&2
  exit 1
fi

cp -R "$PRODUCT" "$APP"
codesign --force --sign - "$APP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo
echo "可以双击运行："
echo "  $APP"
echo "压缩包："
echo "  $ZIP"
echo
echo "装到「应用程序」："
echo "  cp -R \"$APP\" /Applications/ && open /Applications/CoreTemp.app"
