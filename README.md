<p align="center"><img src="macos/Resources/AppIcon.png" width="128" alt="KBSwitch icon"></p>

<h1 align="center">KBSwitch</h1>

<p align="center">Fixes words typed in the wrong keyboard layout, English ⇄ Ukrainian, on macOS.<br>
<code>ghbdsn</code> + Space → <code>привіт</code> · <code>руддщ</code> + Space → <code>hello</code></p>

A tiny menu-bar app with no window and no Dock icon. It uses no CPU while idle and makes no
network requests (it uses the built-in macOS spell checker). It starts at login.

---

## Install

You need macOS 13 or newer. You only do this once.

**1. Install Apple's command-line tools** (skip if you already have Xcode or the tools):

```bash
xcode-select --install
```

**2. Get the code and build the app:**

```bash
git clone https://github.com/dzhusjr/Keyboard-Switcher.git
cd Keyboard-Switcher/macos
./build.sh
```

`build.sh` compiles the app, installs it to **/Applications/KBSwitch.app** and opens it.
macOS has no Ukrainian spell checker, so the first run also installs the LibreOffice Ukrainian
dictionary into `~/Library/Spelling`. That also gives you Ukrainian spell-check in every app.

**3. Allow Accessibility (one time only):** when macOS asks, open *System Settings → Privacy &
Security → Accessibility* and switch **KBSwitch** on. It starts working within 2 seconds. No
restart is needed.

That's it. The **ЯR** icon appears in the menu bar, and the app starts automatically at every login.

## Update

```bash
cd Keyboard-Switcher && git pull && cd macos && ./build.sh
```

You won't be asked for Accessibility again. Every build is signed with the same local
certificate, so macOS recognises it as the same app.

## Uninstall

```bash
cd Keyboard-Switcher/macos && ./uninstall.sh
```

This removes the app, its login item, its Accessibility permission, its settings and its signing
keychain. Add `--all` to also remove the Ukrainian spell-check dictionary.

---

## Using it

Just type. When a word was typed in the wrong layout, pressing **Space** replaces it and switches
the layout.

- **Esc** right after a correction undoes it, and the word is never converted again.
- **Menu-bar icon (ЯR):** Enabled · Settings… · Diagnostic Log · Quit. If you hide the icon, open KBSwitch from
  Applications or Spotlight to get the settings back.

### Settings

A small native window: enable/disable, start at login, show in menu bar, minimum/maximum word length,
only-in-text-fields, undo key, a "Never convert" word list and a list of ignored apps (Terminal and iTerm
by default). Changes apply instantly.

**Optional: Ukrainian typed in Latin.** Turn on *Ukrainian typed in Latin → Cyrillic* and words like
`privit`, `dyakuyu` or `dobryi` become **привіт**, **дякую**, **добрий** when you press Space. It only
fires for words that aren't English and have a dictionary-valid Ukrainian reading, it keeps your layout,
and **Esc** undoes it. Off by default.

If a word isn't fixed and you don't know why, choose **Diagnostic Log** in the menu, reproduce it,
then choose **Show Log**. Every key, every forgotten word and every skipped correction is logged
with its reason. The log contains what you typed, so turn it off afterwards.

### When does it replace a word?

Only when **all** of these are true, so it never deletes or adds the wrong text:

1. You pressed Space right after typing the word key by key. Shortcuts, arrows, held keys, mouse
   clicks or switching apps throw the word away.
2. What you typed is **not** a real word, but the same keys in the other layout **are** a real word.
3. It isn't in your exceptions and its length is within your limits.
4. The cursor is in an editable, non-password text field, and the text right before it is
   exactly that word.

It then deletes exactly the characters you typed, types the converted word and switches the layout.

---

## Build details

- Source: `macos/kbswitch.swift`, a single file using AppKit, Carbon (layouts) and Accessibility
- Icons: `macos/Resources/`
- `./build.sh --ci` builds `macos/build/KBSwitch.zip` without installing. GitHub Actions runs this
  on every push and attaches the zip to releases tagged `v*`.

Prefer building yourself. A downloaded zip isn't notarized, so macOS blocks it until you run
`xattr -dr com.apple.quarantine /Applications/KBSwitch.app`, and it asks for Accessibility again
with each new download.

The original Windows/Python version (`main.pyw`) is still in the repository root.
