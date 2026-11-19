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

CACHE="$HOME/Library/Caches/KBSwitch"
mkdir -p "$CACHE"

# Hunspell (in ./hunspell) checks Ukrainian words; compiled once and cached.
HSOBJ="$CACHE/hunspell-1.7.2-$(uname -m)"
if [ ! -f "$HSOBJ/.done" ]; then
  echo "→ Compiling Hunspell (one time)"
  rm -rf "$HSOBJ" && mkdir -p "$HSOBJ"
  for f in hunspell/*.cxx; do
    clang++ -c -O2 -std=c++11 -DHUNSPELL_STATIC -w -Ihunspell "$f" -o "$HSOBJ/$(basename "$f" .cxx).o"
  done
  touch "$HSOBJ/.done"
fi

# Ukrainian dictionary (LibreOffice uk_UA), downloaded once and bundled inside the app.
if [ ! -f "$CACHE/uk_UA.dic" ]; then
  echo "→ Downloading the Ukrainian dictionary (one time)"
  DICT=https://raw.githubusercontent.com/LibreOffice/dictionaries/master/uk_UA
  curl -fsSL "$DICT/uk_UA.aff" -o "$CACHE/uk_UA.aff.part" && curl -fsSL "$DICT/uk_UA.dic" -o "$CACHE/uk_UA.dic.part" \
    || { rm -f "$CACHE"/*.part; echo "✗ Download failed. Check your internet connection and run ./build.sh again."; exit 1; }
  mv "$CACHE/uk_UA.aff.part" "$CACHE/uk_UA.aff" && mv "$CACHE/uk_UA.dic.part" "$CACHE/uk_UA.dic"
fi
# Earlier versions installed this dictionary into ~/Library/Spelling, but macOS only half understands
# it (valid verbs get underlined as typos in every app). Remove that copy if it is ours.
if cmp -s "$CACHE/uk_UA.dic" "$HOME/Library/Spelling/uk_UA.dic"; then
  rm -f "$HOME/Library/Spelling/uk_UA.aff" "$HOME/Library/Spelling/uk_UA.dic"
  killall AppleSpell 2>/dev/null || true
fi

echo "→ Compiling"
rm -rf build && mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
swiftc -O -swift-version 5 -import-objc-header hunspell/bridge.h -Xcc -DHUNSPELL_STATIC -Xcc -Ihunspell \
  kbswitch.swift "$HSOBJ"/*.o -lc++ -o "$OUT/Contents/MacOS/kbswitch"
cp "$CACHE/uk_UA.aff" "$CACHE/uk_UA.dic" "$OUT/Contents/Resources/"
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
