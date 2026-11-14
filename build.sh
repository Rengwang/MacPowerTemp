#!/bin/bash
# 编译 MacPowerTemp.app（单文件菜单栏程序，无需 Xcode 工程）
set -e
cd "$(dirname "$0")"

APP="MacPowerTemp.app"

echo "→ 编译 C 桥接层与功率控制助手"
clang -O2 -Wall -Wextra -c sensors.c -o sensors.o
clang -O2 -Wall -Wextra powerctl.c -o powerctl -framework IOKit -framework CoreFoundation

echo "→ 编译 Swift 主程序"
swiftc -O -swift-version 5 \
    -import-objc-header bridge.h \
    main.swift SidecarBridge.swift SidecarController.swift SidecarControlView.swift sensors.o \
    -o MacPowerTemp \
    -framework AppKit -framework IOKit -framework CoreFoundation \
    -framework CoreGraphics -framework CoreVideo -framework QuartzCore \
    -framework ScreenCaptureKit -framework Carbon

echo "→ 组装 .app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp MacPowerTemp "$APP/Contents/MacOS/MacPowerTemp"
cp powerctl "$APP/Contents/Resources/powerctl"
chmod 755 "$APP/Contents/Resources/powerctl"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

SIGN_NAME="${MACPOWERTEMP_SIGN_IDENTITY:-MacPowerTemp Local Signing}"
SIGN_HASH="$(security find-identity -p codesigning 2>/dev/null | awk -v name="\"$SIGN_NAME\"" '$0 ~ name { print $2; exit }')"
if [ -n "$SIGN_HASH" ]; then
    echo "→ 固定证书签名：$SIGN_NAME"
    codesign --force --sign "$SIGN_HASH" "$APP"
else
    echo "→ 临时签名"
    codesign --force --sign - "$APP" >/dev/null 2>&1 || true
fi

echo "✓ 完成：$(pwd)/$APP"
