#!/bin/bash
# Builds KBSwitch.app from source.
#
#   ./build.sh          build, install to /Applications and open it
#   ./build.sh --ci     build only (into ./build), ad-hoc signed; used by GitHub Actions
#
# Signing: the app is signed with a self-signed certificate "KBSwitch Local Signing" that this
# script creates once in its own keychain (no password prompts). Because the signing identity never changes, macOS
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
cp Resources/MenuBarIcon.png Resources/MenuBarIcon@2x.png "$OUT/Contents/Resources/"
# App icon: built from AppIcon.png with Apple's own tools so Finder/Spotlight/Dock read it reliably.
ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
for sz in 16 32 128 256 512; do
  sips -z $sz $sz Resources/AppIcon.png --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
  sips -z $((sz*2)) $((sz*2)) Resources/AppIcon.png --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$OUT/Contents/Resources/AppIcon.icns" 2>/dev/null \
  || cp Resources/AppIcon.icns "$OUT/Contents/Resources/AppIcon.icns"

cat > "$OUT/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleName</key><string>KBSwitch</string>
  <key>CFBundleDisplayName</key><string>KBSwitch</string>
  <key>CFBundleExecutable</key><string>kbswitch</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
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
# The signing key lives in its own small keychain with a fixed password, so codesign can use it
# without ever asking for your login password. It only holds this self-signed key.
KC="$HOME/Library/Keychains/kbswitch-signing.keychain-db"
KCPASS=kbswitch
if [ ! -f "$KC" ]; then
  security create-keychain -p "$KCPASS" "$KC"
  security set-keychain-settings "$KC"                    # never auto-lock
fi
security unlock-keychain -p "$KCPASS" "$KC"
if ! security find-identity -p codesigning "$KC" | grep -q "$CERT"; then
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
  security import "$TMP/id.p12" -k "$KC" -P kbswitch -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPASS" "$KC" >/dev/null
  rm -rf "$TMP"
fi
if ! codesign --force --keychain "$KC" --sign "$CERT" "$OUT" 2>/dev/null; then
  echo "  ! could not sign with '$CERT': falling back to ad-hoc signing."
  echo "    The app works, but macOS will ask for Accessibility again after each rebuild."
  codesign --force --sign - "$OUT"
fi

# macOS has no Ukrainian spell checker; KBSwitch needs one to know which words are real.
SPELL="$HOME/Library/Spelling"
if [ ! -f "$SPELL/uk_UA.dic" ]; then
  echo "→ Installing Ukrainian spell-check dictionary (LibreOffice uk_UA) into ~/Library/Spelling"
  mkdir -p "$SPELL"
  DICT=https://raw.githubusercontent.com/LibreOffice/dictionaries/master/uk_UA
  if curl -fsSL "$DICT/uk_UA.aff" -o "$SPELL/uk_UA.aff" && curl -fsSL "$DICT/uk_UA.dic" -o "$SPELL/uk_UA.dic"; then
    killall AppleSpell 2>/dev/null || true      # reload the system spell server
  else
    rm -f "$SPELL/uk_UA.aff" "$SPELL/uk_UA.dic"
    echo "  ! download failed: Ukrainian words won't be recognised until you run ./build.sh again"
  fi
fi

echo "→ Installing to /Applications"
pkill -x kbswitch 2>/dev/null && sleep 0.5 || true
rm -rf /Applications/KBSwitch.app
ditto "$OUT" /Applications/KBSwitch.app
# Make Finder/Spotlight/Launchpad pick up the (new) icon instead of a cached blank one.
touch /Applications/KBSwitch.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f /Applications/KBSwitch.app 2>/dev/null || true
rm -rf build          # don't leave a second copy for Spotlight to find
open /Applications/KBSwitch.app
sleep 1
/Applications/KBSwitch.app/Contents/MacOS/kbswitch --check || true

echo
echo "✓ KBSwitch is installed and running (ЯR icon in the menu bar)."
echo "  First time only: allow KBSwitch in System Settings → Privacy & Security → Accessibility."
