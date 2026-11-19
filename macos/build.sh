#!/bin/bash
# Builds KBSwitch.app from source.
#
#   ./build.sh          build, install to /Applications and open it
#   ./build.sh --ci     build only (into ./build), ad-hoc signed; used by GitHub Actions
#
# Signing: the app is signed with a self-signed certificate "KBSwitch Local Signing" that this
# script creates once in your login keychain. Because the signing identity never changes, macOS
# keeps the Accessibility permission across rebuilds, so you are asked for it only once.
set -euo pipefail
cd "$(dirname "$0")"

ID=com.roman.kbswitch
CERT="KBSwitch Local Signing"
CI=false; [[ "${1:-}" == "--ci" ]] && CI=true
OUT=build/KBSwitch.app

command -v swiftc >/dev/null || { echo "✗ swiftc not found. Run:  xcode-select --install   then run ./build.sh again."; exit 1; }

echo "→ Compiling"
rm -rf build && mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
swiftc -O -swift-version 5 kbswitch.swift -o "$OUT/Contents/MacOS/kbswitch"
cp Resources/AppIcon.icns Resources/MenuBarIcon.png Resources/MenuBarIcon@2x.png "$OUT/Contents/Resources/"

cat > "$OUT/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleName</key><string>KBSwitch</string>
  <key>CFBundleDisplayName</key><string>KBSwitch</string>
  <key>CFBundleExecutable</key><string>kbswitch</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>2.0</string>
  <key>CFBundleVersion</key><string>2.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>KBSwitch — English ⇄ Ukrainian layout fixer</string>
</dict></plist>
EOF

if $CI; then
  codesign --force --sign - "$OUT"
  (cd build && ditto -c -k --keepParent KBSwitch.app KBSwitch.zip)
  echo "✓ Built build/KBSwitch.app and build/KBSwitch.zip"
  exit 0
fi

echo "→ Signing"
if ! security find-identity -p codesigning | grep -q "$CERT"; then
  echo "  creating signing certificate '$CERT' (one time)"
  TMP=$(mktemp -d)
  cat > "$TMP/cert.cfg" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $CERT
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -config "$TMP/cert.cfg" \
      -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
  /usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$CERT" \
      -out "$TMP/id.p12" -passout pass:kbswitch
  security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
      -P kbswitch -T /usr/bin/codesign >/dev/null
  rm -rf "$TMP"
fi
if ! codesign --force --sign "$CERT" "$OUT" 2>/dev/null; then
  echo "  ! could not use '$CERT' (keychain refused?): falling back to ad-hoc signing."
  echo "    The app works, but macOS will ask for Accessibility again after each rebuild."
  codesign --force --sign - "$OUT"
fi

echo "→ Installing to /Applications"
pkill -x kbswitch 2>/dev/null && sleep 0.5 || true
rm -rf /Applications/KBSwitch.app
ditto "$OUT" /Applications/KBSwitch.app
open /Applications/KBSwitch.app

echo
echo "✓ KBSwitch is installed and running (AЯ icon in the menu bar)."
echo "  First time only: allow KBSwitch in System Settings → Privacy & Security → Accessibility."
