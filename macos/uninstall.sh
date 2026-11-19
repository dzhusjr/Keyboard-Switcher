#!/bin/bash
# Completely removes KBSwitch: app, login item, Accessibility permission, settings, signing
# keychain, cache and logs.   ./uninstall.sh --all   also removes a uk_UA dictionary in ~/Library/Spelling.
ID=com.roman.kbswitch
APP=/Applications/KBSwitch.app

if [ -x "$APP/Contents/MacOS/kbswitch" ]; then      # remove the login item
  "$APP/Contents/MacOS/kbswitch" --unregister >/dev/null 2>&1 &
  sleep 1
fi
pkill -x kbswitch 2>/dev/null
rm -rf "$APP"
tccutil reset Accessibility "$ID" >/dev/null 2>&1
tccutil reset ListenEvent "$ID" >/dev/null 2>&1
defaults delete "$ID" >/dev/null 2>&1
rm -rf "$HOME/.config/kbswitch" "$HOME/Library/Logs/KBSwitch.log" "$HOME/Library/Caches/KBSwitch"
security delete-keychain "$HOME/Library/Keychains/kbswitch-signing.keychain-db" 2>/dev/null

# Leftovers from early test versions
launchctl bootout "gui/$(id -u)/$ID" 2>/dev/null
rm -rf "$HOME/Library/LaunchAgents/$ID.plist" "$HOME/Applications/KBSwitch.app"
security delete-certificate -c "KBSwitch Local Signing" "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1

if [ "${1:-}" = "--all" ]; then
  rm -f "$HOME/Library/Spelling/uk_UA.aff" "$HOME/Library/Spelling/uk_UA.dic"
  killall AppleSpell 2>/dev/null
fi
echo "KBSwitch removed."
