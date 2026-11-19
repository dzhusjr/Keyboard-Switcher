// kbswitch — fixes words typed in the wrong keyboard layout (English ⇄ Ukrainian) on macOS.
//
// How it works, in one paragraph:
//   A keyboard event tap records the *physical keys* of the word you are typing. When you press
//   Space, the same keys are translated through the other layout (UCKeyTranslate, using your real
//   installed layouts). The word is replaced only if (1) what you typed is NOT a word in the current
//   layout's language, (2) the converted text IS a word in the other language (offline macOS spell
//   checker), (3) the focused element is an editable text field whose text before the caret is
//   exactly the word that was tracked, and (4) it passes the length/exception rules from settings.
//   It then deletes exactly that many characters, types the converted word and switches the layout.
//   Idle cost: zero CPU (purely event driven); work per key is an array append.
//
// Build: ./build.sh (creates /Applications/KBSwitch.app)   Settings: ~/.config/kbswitch/settings.txt

import Cocoa
import Carbon.HIToolbox
import ServiceManagement

// MARK: - Files

enum Files {
    static let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/kbswitch", isDirectory: true)
    static let settings = dir.appendingPathComponent("settings.txt")
    static let exceptions = dir.appendingPathComponent("exceptions.txt")
    static func words(_ lang: String) -> URL { dir.appendingPathComponent("words_\(lang).txt") }

    static let defaultSettings = """
    # kbswitch settings: changes apply automatically, no restart needed.

    # Master switch (clicking the menu-bar icon can also pause it).
    enabled = true

    # Only words whose length is within this range are ever converted.
    min_length = 3
    max_length = 30

    # Key that reverts the last correction if it is the very next key you press:
    # escape, backspace or none. A reverted word is added to exceptions.txt if learn_on_undo = true.
    undo_key = escape
    learn_on_undo = true

    # Act only when the focused element is an editable text field (recommended).
    require_text_field = true

    # Ask Electron apps (Slack, VS Code, Discord, ...) to expose their text fields, so the
    # text-field check and the text verification work there too.
    electron_accessibility = true

    # Apps where kbswitch never does anything (bundle ids, comma separated).
    # Find an id with:  osascript -e 'id of app "Terminal"'
    excluded_apps = com.apple.Terminal, com.googlecode.iterm2

    # Layouts to switch between. "auto" = first enabled English / Ukrainian layout.
    # e.g. com.apple.keylayout.ABC, com.apple.keylayout.US, com.apple.keylayout.Ukrainian-PC
    english_layout = auto
    ukrainian_layout = auto

    menu_bar_icon = true

    """

    static let defaultExceptions = """
    # Words that are never converted: one per line, written in either layout, case-insensitive.
    # Corrections you undo are appended here automatically.

    """

    /// Non-empty lines with `#` comments stripped.
    static func lines(_ url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.components(separatedBy: .newlines).compactMap { raw in
            let line = (raw.components(separatedBy: "#").first ?? "").trimmingCharacters(in: .whitespaces)
            return line.isEmpty ? nil : line
        }
    }

    static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

func logLine(_ message: String) {
    FileHandle.standardError.write(("kbswitch: " + message + "\n").data(using: .utf8)!)
}

// MARK: - Settings

struct Settings {
    var enabled = true
    var minLength = 3
    var maxLength = 30
    var undoKey = "escape"
    var learnOnUndo = true
    var requireTextField = true
    var electronAccessibility = true
    var menuBarIcon = true
    var excludedApps = Set<String>()
    var englishLayout = "auto"
    var ukrainianLayout = "auto"
    var exceptions = Set<String>()

    static func load() -> Settings {
        let fm = FileManager.default
        try? fm.createDirectory(at: Files.dir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: Files.settings.path) {
            try? Files.defaultSettings.write(to: Files.settings, atomically: true, encoding: .utf8)
        }
        if !fm.fileExists(atPath: Files.exceptions.path) {
            try? Files.defaultExceptions.write(to: Files.exceptions, atomically: true, encoding: .utf8)
        }

        var s = Settings()
        for line in Files.lines(Files.settings) {
            let kv = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2 else { continue }
            let value = kv[1]
            let flag = ["true", "yes", "on", "1"].contains(value.lowercased())
            switch kv[0].lowercased() {
            case "enabled": s.enabled = flag
            case "min_length": s.minLength = max(1, Int(value) ?? s.minLength)
            case "max_length": s.maxLength = max(1, Int(value) ?? s.maxLength)
            case "undo_key": s.undoKey = value.lowercased()
            case "learn_on_undo": s.learnOnUndo = flag
            case "require_text_field": s.requireTextField = flag
            case "electron_accessibility": s.electronAccessibility = flag
            case "menu_bar_icon": s.menuBarIcon = flag
            case "english_layout": s.englishLayout = value
            case "ukrainian_layout": s.ukrainianLayout = value
            case "excluded_apps":
                s.excludedApps = Set(value.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
            default: logLine("unknown setting '\(kv[0])' ignored")
            }
        }
        s.maxLength = max(s.maxLength, s.minLength)
        s.exceptions = Set(Files.lines(Files.exceptions).map { $0.lowercased() })
        return s
    }
}

// MARK: - Keyboard layouts

/// One physical key press that produced exactly one printable character.
struct Key {
    let code: UInt16
    let shift: Bool
    let caps: Bool
    let char: String
}

private func tisValue(_ src: TISInputSource, _ key: CFString) -> AnyObject? {
    guard let p = TISGetInputSourceProperty(src, key) else { return nil }
    return Unmanaged<AnyObject>.fromOpaque(p).takeUnretainedValue()
}

final class Layout {
    let source: TISInputSource
    let id: String
    let lang: String          // "en", "uk", ...
    private let uchr: CFData

    init?(_ src: TISInputSource) {
        guard (tisValue(src, kTISPropertyInputSourceType) as? String) == (kTISTypeKeyboardLayout as String),
              let id = tisValue(src, kTISPropertyInputSourceID) as? String,
              let lang = (tisValue(src, kTISPropertyInputSourceLanguages) as? [String])?.first,
              let p = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        self.source = src
        self.id = id
        self.lang = String(lang.prefix(2))
        self.uchr = Unmanaged<CFData>.fromOpaque(p).takeUnretainedValue()
    }

    /// The single character this layout produces for the key, or nil (dead key, multi-char, error).
    func char(for key: Key) -> String? {
        guard let bytes = CFDataGetBytePtr(uchr) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let modifiers = (UInt32(key.shift ? shiftKey : 0) | UInt32(key.caps ? alphaLock : 0)) >> 8
        let status = UCKeyTranslate(layout, key.code, UInt16(kUCKeyActionDown), modifiers & 0xFF,
                                    UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                    &deadKeyState, 4, &length, &chars)
        guard status == 0, length > 0 else { return nil }
        let s = String(utf16CodeUnits: chars, count: length)
        return s.count == 1 ? s : nil
    }
}

final class Layouts {
    private(set) var english: Layout?
    private(set) var ukrainian: Layout?

    func reload(_ s: Settings) {
        let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String] as CFDictionary
        let sources = (TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource]) ?? []
        let all = sources.compactMap(Layout.init)
        func pick(_ lang: String, _ wanted: String) -> Layout? {
            if wanted.lowercased() == "auto" { return all.first(where: { $0.lang == lang }) }
            return all.first(where: { $0.id == wanted })
        }
        english = pick("en", s.englishLayout)
        ukrainian = pick("uk", s.ukrainianLayout)
        if english == nil { logLine("no English layout enabled (or english_layout id not found)") }
        if ukrainian == nil { logLine("no Ukrainian layout enabled (or ukrainian_layout id not found)") }
    }

    /// (current layout, layout to convert into), or nil if the current layout is neither language.
    func pair() -> (from: Layout, to: Layout)? {
        guard let cur = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let from = Layout(cur) else { return nil }
        switch from.lang {
        case "en": if let to = ukrainian { return (from, to) }
        case "uk": if let to = english { return (from, to) }
        default: break
        }
        return nil
    }
}

// MARK: - Dictionary (offline macOS spell checker + optional word lists)

final class Lexicon {
    private let checker = NSSpellChecker.shared
    private var spellCode: [String: String] = [:]     // "uk" -> code the spell checker understands
    private var extra: [String: Set<String>] = [:]    // optional ~/.config/kbswitch/words_<lang>.txt

    init() {
        let available = checker.availableLanguages
        for lang in ["en", "uk"] {
            let exact = available.first(where: { $0 == lang })
            spellCode[lang] = exact ?? available.first(where: { $0.hasPrefix(lang + "_") || $0.hasPrefix(lang + "-") })
            if let code = spellCode[lang] {   // warm up so the first real check is fast
                _ = checker.checkSpelling(of: "test", startingAt: 0, language: code, wrap: false,
                                          inSpellDocumentWithTag: 0, wordCount: nil)
            }
        }
        reloadWordLists()
    }

    func reloadWordLists() {
        for lang in ["en", "uk"] {
            extra[lang] = Set(Files.lines(Files.words(lang)).map { $0.lowercased() })
        }
    }

    func describe(_ lang: String) -> String {
        "spell checker: \(spellCode[lang] ?? "MISSING"), extra words: \(extra[lang]?.count ?? 0)"
    }

    /// Without a dictionary for a language, every word would look "misspelled": never act then.
    func supports(_ lang: String) -> Bool {
        spellCode[lang] != nil || !(extra[lang]?.isEmpty ?? true)
    }

    func isWord(_ word: String, _ lang: String) -> Bool {
        let variants = word == word.lowercased() ? [word] : [word, word.lowercased()]
        for v in variants {
            if extra[lang]?.contains(v.lowercased()) == true { return true }
            if let code = spellCode[lang] {
                let miss = checker.checkSpelling(of: v, startingAt: 0, language: code, wrap: false,
                                                 inSpellDocumentWithTag: 0, wordCount: nil)
                if miss.location == NSNotFound { return true }
            }
        }
        return false
    }
}

// MARK: - Decision (pure logic)

enum Decision {
    private static let edges = CharacterSet.punctuationCharacters.union(.symbols)
    private static let innerMarks: Set<Character> = ["'", "’", "ʼ", "-"]

    static func core(_ s: String) -> String { s.trimmingCharacters(in: edges) }

    static func isLetter(_ c: Character, _ lang: String) -> Bool {
        guard c.unicodeScalars.count == 1, let v = c.unicodeScalars.first?.value else { return false }
        switch lang {
        case "uk": return (0x0400...0x04FF).contains(v) && c.isLetter         // Cyrillic only
        default:   return (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v) // ASCII Latin only
        }
    }

    static func shouldConvert(typed: String, converted: String, fromLang: String, toLang: String,
                              minLength: Int, exceptions: Set<String>,
                              isWord: (String, String) -> Bool) -> Bool {
        guard typed != converted, !typed.contains(where: { $0.isNumber }) else { return false }
        let src = core(typed), dst = core(converted)
        guard !src.isEmpty, dst.count >= minLength else { return false }

        // The result must be a clean word in the target script (letters, inner apostrophe/hyphen).
        guard let first = dst.first, let last = dst.last,
              isLetter(first, toLang), isLetter(last, toLang),
              dst.allSatisfy({ isLetter($0, toLang) || innerMarks.contains($0) }) else { return false }

        // Natural casing only: word, Word or WORD.
        let letters = dst.filter { $0.isLetter }
        let capitalized = letters.prefix(1).uppercased() + letters.dropFirst().lowercased()
        guard letters == letters.lowercased() || letters == letters.uppercased() || letters == capitalized
        else { return false }

        for w in [typed, src, dst] where exceptions.contains(w.lowercased()) { return false }

        // Strict rule: what you typed is not a word, and what it becomes is a word.
        return !isWord(src, fromLang) && isWord(dst, toLang)
    }
}

// MARK: - Focused text field (Accessibility)

enum FieldState { case verified, unverified, unknown, notText, secure, mismatch }

enum FocusedField {
    private static let textRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField"]
    private static let openers: Set<Character> = ["(", "«", "“", "„"]

    private static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success ? value : nil
    }

    /// Checks that the focused element is an editable text field and that the text right before
    /// the caret is exactly `word`, preceded by whitespace / an opening bracket / start of text.
    static func check(expect word: String) -> FieldState {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.08)
        guard let f = attr(system, kAXFocusedUIElementAttribute),
              CFGetTypeID(f) == AXUIElementGetTypeID() else { return .unknown }
        let el = f as! AXUIElement
        AXUIElementSetMessagingTimeout(el, 0.08)

        if (attr(el, kAXSubroleAttribute) as? String) == kAXSecureTextFieldSubrole { return .secure }
        let role = (attr(el, kAXRoleAttribute) as? String) ?? ""
        var settable = DarwinBoolean(false)
        let editable = AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable) == .success
            && settable.boolValue
        guard textRoles.contains(role) || editable else { return .notText }

        guard let rv = attr(el, kAXSelectedTextRangeAttribute),
              CFGetTypeID(rv) == AXValueGetTypeID() else { return .unverified }
        var sel = CFRange()
        guard AXValueGetValue(rv as! AXValue, .cfRange, &sel) else { return .unverified }
        guard sel.length == 0 else { return .mismatch }                 // something is selected

        let start = sel.location - word.utf16.count
        guard start >= 0 else { return .mismatch }
        let from = max(0, start - 1)
        guard let text = string(el, CFRange(location: from, length: sel.location - from)) else { return .unverified }
        guard text.hasSuffix(word) else { return .mismatch }
        let before = text.dropLast(word.count)
        if before.isEmpty { return start == 0 ? .verified : .mismatch }
        guard before.count == 1, let c = before.first, c.isWhitespace || openers.contains(c) else { return .mismatch }
        return .verified
    }

    private static func string(_ el: AXUIElement, _ range: CFRange) -> String? {
        var r = range
        if let rv = AXValueCreate(.cfRange, &r) {
            var out: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(el, kAXStringForRangeParameterizedAttribute as CFString, rv, &out) == .success,
               let s = out as? String { return s }
        }
        if let n = attr(el, kAXNumberOfCharactersAttribute) as? Int, n > 200_000 { return nil }
        guard let full = attr(el, kAXValueAttribute) as? String else { return nil }
        let units = Array(full.utf16)
        guard range.location >= 0, range.location + range.length <= units.count else { return nil }
        let slice = Array(units[range.location ..< range.location + range.length])
        return String(utf16CodeUnits: slice, count: slice.count)
    }
}

// MARK: - Engine

struct Correction {
    let typed: [Key]
    let inserted: String
    let from: TISInputSource
    let word: String
    let time: Date
}

final class Engine: NSObject {
    private static let marker: Int64 = 0x4B42_5357          // tags our own synthetic events
    private var settings = Settings()
    private var stamps: [Date?] = [nil, nil]
    private let layouts = Layouts()
    private let lexicon = Lexicon()
    private let eventSource = CGEventSource(stateID: .privateState)
    private var tap: CFMachPort?
    private var statusItem: NSStatusItem?
    private var paused = false
    private var sessionIgnore = Set<String>()
    private var electronDone = Set<pid_t>()

    // Typing state
    private var buffer: [Key] = []
    private var atWordStart = false     // a word boundary was seen right before `buffer`
    private var last: Correction?

    private var active: Bool { settings.enabled && !paused }

    func start() {
        reloadIfChanged(force: true)
        observeSystem()
        // First launch: start at login by default (toggle in the menu).
        if !UserDefaults.standard.bool(forKey: "loginConfigured") {
            UserDefaults.standard.set(true, forKey: "loginConfigured")
            try? SMAppService.mainApp.register()
            updateMenu()
        }
        // The only permission needed is Accessibility. macOS shows its prompt only while the app is
        // not yet allowed; the grant survives rebuilds because build.sh signs with a stable identity.
        if !AXIsProcessTrusted() {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
        if !installTap() {
            logLine("waiting for Accessibility permission…")
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                if self?.installTap() ?? true { t.invalidate(); logLine("running") }
            }
        } else { logLine("running") }
    }

    func report() {
        reloadIfChanged(force: true)
        print("English layout:   \(layouts.english?.id ?? "NOT FOUND")")
        print("Ukrainian layout: \(layouts.ukrainian?.id ?? "NOT FOUND")")
        print("English words:    \(lexicon.describe("en"))")
        print("Ukrainian words:  \(lexicon.describe("uk"))")
        print("Accessibility:    \(AXIsProcessTrusted() ? "granted" : "NOT granted")")
    }

    // MARK: Setup

    private func installTap() -> Bool {
        // Creating a keyboard tap before Accessibility is granted would make macOS show a second
        // (Input Monitoring) prompt, so wait for the one permission first.
        guard AXIsProcessTrusted() else { return false }
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            return Unmanaged<Engine>.fromOpaque(refcon).takeUnretainedValue().handle(proxy, type, event)
        }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                        options: .defaultTap, eventsOfInterest: mask, callback: callback,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        tap = t
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0), .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    private func observeSystem() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            self?.reset()
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.exposeElectron(app)
            }
        }
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
                        object: nil, queue: .main) { [weak self] _ in
            // Layout changed mid-word: the tracked keys no longer describe the text. Keep `last` (undo).
            guard let self = self, !self.buffer.isEmpty else { return }
            self.buffer.removeAll(); self.atWordStart = false
        }
        dnc.addObserver(forName: Notification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String),
                        object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.layouts.reload(self.settings)
        }
    }

    private func exposeElectron(_ app: NSRunningApplication) {
        guard settings.electronAccessibility, !electronDone.contains(app.processIdentifier),
              let url = app.bundleURL?.appendingPathComponent("Contents/Frameworks/Electron Framework.framework"),
              FileManager.default.fileExists(atPath: url.path) else { return }
        electronDone.insert(app.processIdentifier)
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier),
                                     "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    private func reloadIfChanged(force: Bool = false) {
        let now = [Files.modified(Files.settings), Files.modified(Files.exceptions)]
        guard force || now != stamps else { return }
        settings = Settings.load()
        stamps = [Files.modified(Files.settings), Files.modified(Files.exceptions)]
        layouts.reload(settings)
        lexicon.reloadWordLists()
        updateMenu()
    }

    // MARK: Event handling

    private func reset() { buffer.removeAll(); atWordStart = false; last = nil }

    fileprivate func handle(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .keyDown: break
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            reset(); return pass
        default:                                   // mouse click: the caret may have moved
            reset(); return pass
        }
        if event.getIntegerValueField(.eventSourceUserData) == Engine.marker { return pass }

        let pending = last
        last = nil
        guard active else { reset(); return pass }

        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let shortcut = !flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty

        if let p = pending, !isRepeat, !shortcut, isUndoKey(code),
           Date().timeIntervalSince(p.time) < 10, undo(p, proxy) {
            return nil
        }
        if shortcut { reset(); return pass }      // shortcuts are not typing

        switch code {
        case kVK_Space:
            if !isRepeat, !buffer.isEmpty, correct(proxy) { return nil }
            buffer.removeAll(); atWordStart = true
        case kVK_Delete:
            if isRepeat { reset() }
            else if buffer.isEmpty { atWordStart = false }   // deleting into text we never saw
            else { buffer.removeLast() }
        case kVK_Return, kVK_ANSI_KeypadEnter:
            buffer.removeAll(); atWordStart = true
        default:
            // Arrows, F-keys, Tab, Esc, held keys, over-long words: not part of a word we can trust.
            guard !isRepeat, let ch = printable(event), buffer.count < settings.maxLength else {
                reset(); return pass
            }
            buffer.append(Key(code: UInt16(code), shift: flags.contains(.maskShift),
                              caps: flags.contains(.maskAlphaShift), char: ch))
        }
        return pass
    }

    private func isUndoKey(_ code: Int) -> Bool {
        switch settings.undoKey {
        case "escape": return code == kVK_Escape
        case "backspace": return code == kVK_Delete
        default: return false
        }
    }

    private func printable(_ event: CGEvent) -> String? {
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &chars)
        guard length > 0 else { return nil }
        let s = String(utf16CodeUnits: chars, count: length)
        guard s.count == 1, let scalar = s.unicodeScalars.first else { return nil }
        let v = scalar.value
        if v < 0x20 || v == 0x7F || (0xF700...0xF8FF).contains(v) || scalar.properties.isWhitespace { return nil }
        return s
    }

    // MARK: Correction

    private func correct(_ proxy: CGEventTapProxy) -> Bool {
        reloadIfChanged()
        guard active, buffer.count >= settings.minLength, buffer.count <= settings.maxLength else { return false }
        if let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           settings.excludedApps.contains(id) { return false }
        guard let pair = layouts.pair(),
              lexicon.supports(pair.from.lang), lexicon.supports(pair.to.lang) else { return false }

        var typed = "", converted = ""
        var newChars: [String] = []
        for key in buffer {
            // Re-deriving each char through the current layout must reproduce what was typed
            // (guards against dead keys, input methods, remapping tools); otherwise do nothing.
            guard pair.from.char(for: key) == key.char, let c = pair.to.char(for: key) else { return false }
            typed += key.char
            converted += c
            newChars.append(c)
        }

        guard Decision.shouldConvert(typed: typed, converted: converted,
                                     fromLang: pair.from.lang, toLang: pair.to.lang,
                                     minLength: settings.minLength,
                                     exceptions: settings.exceptions.union(sessionIgnore),
                                     isWord: lexicon.isWord) else { return false }

        // Only touch the text if we are sure it is exactly the word we tracked.
        switch FocusedField.check(expect: typed) {
        case .verified: break
        case .unverified: guard atWordStart else { return false }
        case .unknown, .notText: guard !settings.requireTextField, atWordStart else { return false }
        case .secure, .mismatch: return false
        }

        for _ in buffer { post(UInt16(kVK_Delete), nil, shift: false, proxy) }
        for (key, c) in zip(buffer, newChars) { post(key.code, c, shift: key.shift, proxy) }
        post(UInt16(kVK_Space), " ", shift: false, proxy)
        TISSelectInputSource(pair.to.source)

        last = Correction(typed: buffer, inserted: converted, from: pair.from.source,
                          word: Decision.core(typed), time: Date())
        buffer.removeAll()
        atWordStart = true
        return true
    }

    /// Reverts the last correction. Returns false (and lets the key through) if the text no longer matches.
    private func undo(_ c: Correction, _ proxy: CGEventTapProxy) -> Bool {
        switch FocusedField.check(expect: c.inserted + " ") {
        case .mismatch, .secure, .notText: return false
        default: break
        }
        for _ in 0 ..< c.inserted.count + 1 { post(UInt16(kVK_Delete), nil, shift: false, proxy) }
        for key in c.typed { post(key.code, key.char, shift: key.shift, proxy) }
        post(UInt16(kVK_Space), " ", shift: false, proxy)
        TISSelectInputSource(c.from)

        sessionIgnore.insert(c.word.lowercased())
        if settings.learnOnUndo { addException(c.word) }
        buffer.removeAll()
        atWordStart = true
        return true
    }

    /// Synthetic key press inserted right after this tap, i.e. before any keys still in flight.
    private func post(_ code: UInt16, _ text: String?, shift: Bool, _ proxy: CGEventTapProxy) {
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: eventSource, virtualKey: code, keyDown: down) else { continue }
            e.flags = shift ? .maskShift : []
            if let text = text {
                let units = Array(text.utf16)
                e.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            }
            e.setIntegerValueField(.eventSourceUserData, value: Engine.marker)
            e.tapPostEvent(proxy)
        }
    }

    private func addException(_ word: String) {
        var text = (try? String(contentsOf: Files.exceptions, encoding: .utf8)) ?? ""
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        text += word.lowercased() + "\n"
        try? text.write(to: Files.exceptions, atomically: true, encoding: .utf8)
    }

    // MARK: Menu-bar icon

    private func updateMenu() {
        guard settings.menuBarIcon else {
            if let item = statusItem { NSStatusBar.system.removeStatusItem(item); statusItem = nil }
            return
        }
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            if let icon = Bundle.main.image(forResource: "MenuBarIcon") {
                icon.isTemplate = true                     // adapts to light/dark menu bar
                item.button?.image = icon
            } else {
                item.button?.title = "AЯ"
            }
            let menu = NSMenu()
            func add(_ title: String, _ action: Selector, tag: Int = 0) {
                let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
                mi.target = self
                mi.tag = tag
                menu.addItem(mi)
            }
            add("Enabled", #selector(togglePause), tag: 1)
            add("Start at Login", #selector(toggleLogin), tag: 2)
            menu.addItem(NSMenuItem.separator())
            add("Settings…", #selector(openSettings))
            add("Exceptions…", #selector(openExceptions))
            menu.addItem(NSMenuItem.separator())
            add("Quit kbswitch", #selector(quit))
            item.menu = menu
            statusItem = item
        }
        statusItem?.button?.appearsDisabled = !active
        statusItem?.menu?.item(withTag: 1)?.state = active ? .on : .off
        statusItem?.menu?.item(withTag: 2)?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func togglePause() { paused.toggle(); reset(); updateMenu() }
    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch { logLine("login item: \(error)") }
        updateMenu()
    }
    @objc private func openSettings() { openInEditor(Files.settings) }
    @objc private func openExceptions() { openInEditor(Files.exceptions) }
    @objc private func quit() { NSApp.terminate(nil) }

    private func openInEditor(_ url: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-t", url.path]
        try? p.run()
    }
}

// MARK: - Main

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let engine = Engine()
if CommandLine.arguments.contains("--check") {
    engine.report()
    exit(0)
}
engine.start()
app.run()
