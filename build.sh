#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
swift build -c release -j 4 -Xswiftc -file-prefix-map -Xswiftc "$HOME=~"
if [[ ! -f build/Teum.icns || scripts/icon.swift -nt build/Teum.icns ]]; then
  swift scripts/icon.swift build/Teum.iconset
  iconutil -c icns build/Teum.iconset -o build/Teum.icns
fi
app="build/Teum.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/Teum "$app/Contents/MacOS/Teum"
strip -S "$app/Contents/MacOS/Teum"
cp Vendor/LICENSE-QuotaBar "$app/Contents/Resources/LICENSE-QuotaBar"
cp LICENSE THIRD_PARTY_NOTICES.md "$app/Contents/Resources/"
ditto licenses "$app/Contents/Resources/licenses"
cp build/Teum.icns "$app/Contents/Resources/Teum.icns"
ditto Sources/Teum/Resources/logos "$app/Contents/Resources/logos"
mkdir -p "$app/Contents/Resources/cli"
cp cli/teum_cli.py "$app/Contents/Resources/cli/teum_cli.py"
cat > "$app/Contents/Resources/icon-source.txt" <<'SOURCE'
원본: scripts/icon.swift. AppKit NSBezierPath로 직접 그린 일곱 개 잔여량 막대.
외부 사진·스톡·생성형 이미지 없음. iconutil로 Teum.icns 패키징.
SOURCE
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.paul.teum</string>
<key>CFBundleName</key><string>Teum</string>
<key>CFBundleDisplayName</key><string>Teum</string>
<key>CFBundleExecutable</key><string>Teum</string>
<key>CFBundleIconFile</key><string>Teum.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.5</string>
<key>CFBundleVersion</key><string>5</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --sign - "$app"
echo "만들었어요: $PWD/$app"
