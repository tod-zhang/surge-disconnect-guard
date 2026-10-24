#!/bin/bash
set -euo pipefail
GUI=$(cd -- "$(dirname -- "$0")" && pwd -P)
BASE=$(cd -- "$GUI/.." && pwd -P)
WORK=${1:?请传入中间构建目录的绝对路径}
OUTPUT=${2:?请传入输出 DMG 的绝对路径}
APP="$WORK/Surge 断网守护.app"
STAGE="$WORK/dmg-root"
mkdir -p "$WORK" "$APP/Contents/MacOS" "$APP/Contents/Resources/engine" "$STAGE"
xcrun clang -target arm64-apple-macosx13.0 -Wall -Wextra -Werror -c "$BASE/native.c" -o "$WORK/native.o"
xcrun swiftc -parse-as-library -target arm64-apple-macosx13.0 -O -warnings-as-errors "$BASE/GuardSettings.swift" "$BASE/SurgeGuard.swift" "$WORK/native.o" -o "$WORK/surge-guard"
"$WORK/surge-guard" self-test
xcrun swiftc -parse-as-library -target arm64-apple-macosx13.0 -O -warnings-as-errors "$BASE/GuardSettings.swift" "$GUI/ControlIPC.swift" "$GUI/GuardUI.swift" -o "$APP/Contents/MacOS/SurgeGuardUI"
"$APP/Contents/MacOS/SurgeGuardUI" --self-test
install -m 755 "$WORK/surge-guard" "$APP/Contents/Resources/engine/surge-guard"
install -m 755 "$WORK/surge-guard" "$BASE/surge-guard"
install -m 755 "$BASE/sgctl" "$APP/Contents/Resources/engine/sgctl"
install -m 644 "$BASE/local.surgedisconnect.guard.plist" "$APP/Contents/Resources/engine/local.surgedisconnect.guard.plist"
install -m 755 "$GUI/gui-control.sh" "$APP/Contents/Resources/gui-control.sh"
install -m 755 "$GUI/install-control.sh" "$APP/Contents/Resources/install-control.sh"
install -m 755 "$GUI/control-actions.sh" "$APP/Contents/Resources/control-actions.sh"
install -m 644 "$GUI/local.surgedisconnect.control.plist" "$APP/Contents/Resources/local.surgedisconnect.control.plist"
xcrun swiftc -parse-as-library -target arm64-apple-macosx13.0 -O -warnings-as-errors "$BASE/GuardSettings.swift" "$GUI/ControlIPC.swift" "$GUI/ControlService.swift" "$GUI/ControlSelfTest.swift" "$WORK/native.o" -o "$APP/Contents/Resources/engine/sg-control"
codesign --force --sign - --identifier local.surgedisconnect.control "$APP/Contents/Resources/engine/sg-control"
"$APP/Contents/Resources/engine/sg-control" self-test
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.surgedisconnect.ui</string>
<key>CFBundleName</key><string>Surge 断网守护</string>
<key>CFBundleDisplayName</key><string>Surge 断网守护</string>
<key>CFBundleExecutable</key><string>SurgeGuardUI</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>2.3.0</string>
<key>CFBundleVersion</key><string>230</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppleEventsUsageDescription</key><string>通过 macOS 管理员授权安装及控制本机网络守护。</string>
</dict></plist>
PLIST
xcrun swiftc "$GUI/CreateIcon.swift" -o "$WORK/create-icon"
"$WORK/create-icon" "$WORK/icon.png"
mkdir -p "$WORK/AppIcon.iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$WORK/icon.png" --out "$WORK/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$WORK/icon.png" --out "$WORK/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$WORK/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
plutil -lint "$APP/Contents/Info.plist"
codesign --force --sign - "$APP/Contents/Resources/engine/surge-guard"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
ditto "$APP" "$STAGE/Surge 断网守护.app"
[[ -L "$STAGE/Applications" ]] || ln -s /Applications "$STAGE/Applications"
cp "$GUI/DMG安装说明.txt" "$STAGE/安装说明.txt"
hdiutil create -volname 'Surge 断网守护 2.3.0' -fs HFS+ -srcfolder "$STAGE" -format UDZO -ov "$OUTPUT"
hdiutil verify "$OUTPUT"
echo "已生成：$OUTPUT"
