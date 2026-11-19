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
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Files

enum Files {
    static let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/kbswitch", isDirectory: true)
    static let settings = dir.appendingPathComponent("settings.txt")
    static let exceptions = dir.appendingPathComponent("exceptions.txt")
    static func words(_ lang: String) -> URL { dir.appendingPathComponent("words_\(lang).txt") }

    static let defaultExceptions = """
    # Words that are never converted: one per line, in either layout. Editable in Settings.

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

/// Diagnostic log (Settings → "Write diagnostic log"): ~/Library/Logs/KBSwitch.log
enum DebugLog {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/KBSwitch.log")
    static var on = false
    static func write(_ message: String) {
        guard on, let data = "\(Date()) \(message)\n".data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() }
        else { try? data.write(to: url) }
    }
}

func logLine(_ message: String) {
    FileHandle.standardError.write(("kbswitch: " + message + "\n").data(using: .utf8)!)
}

// MARK: - Settings

struct Config {
    var enabled = true
    var minLength = 3
    var maxLength = 30
    var undoKey = "escape"
    var learnOnUndo = true
    var requireTextField = true
    var electronAccessibility = true
    var menuBarIcon = true
    var excludedApps: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2"]
    var debugLog = false
    var englishLayout = "auto"
    var ukrainianLayout = "auto"
    var exceptions = Set<String>()

    static func load() -> Config {
        let fm = FileManager.default
        try? fm.createDirectory(at: Files.dir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: Files.settings.path) { Config().save() }
        if !fm.fileExists(atPath: Files.exceptions.path) {
            try? Files.defaultExceptions.write(to: Files.exceptions, atomically: true, encoding: .utf8)
        }

        var s = Config()
        for line in Files.lines(Files.settings) {
            let kv = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
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
            case "debug_log": s.debugLog = flag
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

    /// Settings are edited in the Settings window; the file stays human-readable.
    func save() {
        let text = """
        # KBSwitch settings. Change them in the app: menu-bar icon → Settings…
        enabled = \(enabled)
        min_length = \(minLength)
        max_length = \(max(maxLength, minLength))
        undo_key = \(undoKey)
        learn_on_undo = \(learnOnUndo)
        require_text_field = \(requireTextField)
        electron_accessibility = \(electronAccessibility)
        menu_bar_icon = \(menuBarIcon)
        excluded_apps = \(excludedApps.sorted().joined(separator: ", "))
        english_layout = \(englishLayout)
        ukrainian_layout = \(ukrainianLayout)
        debug_log = \(debugLog)

        """
        try? FileManager.default.createDirectory(at: Files.dir, withIntermediateDirectories: true)
        try? text.write(to: Files.settings, atomically: true, encoding: .utf8)
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

final class KeyLayout {
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
    private(set) var english: KeyLayout?
    private(set) var ukrainian: KeyLayout?

    func reload(_ s: Config) {
        let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String] as CFDictionary
        let sources = (TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource]) ?? []
        let all = sources.compactMap(KeyLayout.init)
        func pick(_ lang: String, _ wanted: String) -> KeyLayout? {
            if wanted.lowercased() == "auto" { return all.first(where: { $0.lang == lang }) }
            return all.first(where: { $0.id == wanted })
        }
        english = pick("en", s.englishLayout)
        ukrainian = pick("uk", s.ukrainianLayout)
        if english == nil { logLine("no English layout enabled (or english_layout id not found)") }
        if ukrainian == nil { logLine("no Ukrainian layout enabled (or ukrainian_layout id not found)") }
    }

    /// (current layout, layout to convert into), or nil if the current layout is neither language.
    func pair() -> (from: KeyLayout, to: KeyLayout)? {
        guard let cur = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let from = KeyLayout(cur) else { return nil }
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

        // Apps draw keystrokes asynchronously: when typing fast the last letters may not be in the
        // field yet. Re-read a few times before deciding the text doesn't match.
        var result = FieldState.mismatch
        for attempt in 0..<4 {
            if attempt > 0 { usleep(15_000) }
            result = compare(el, word)
            if result != .mismatch { break }
        }
        return result
    }

    private static func compare(_ el: AXUIElement, _ word: String) -> FieldState {
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

final class Engine: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let marker: Int64 = 0x4B42_5357          // tags our own synthetic events
    private var settings = Config()
    private var stamps: [Date?] = [nil, nil]
    private let layouts = Layouts()
    private let lexicon = Lexicon()
    private let eventSource = CGEventSource(stateID: .privateState)
    private var tap: CFMachPort?
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var headless = false
    private var activity: NSObjectProtocol?        // --check: no menu-bar icon
    private var sessionIgnore = Set<String>()
    private var electronDone = Set<pid_t>()

    // Typing state
    private var buffer: [Key] = []
    private var atWordStart = false     // a word boundary was seen right before `buffer`
    /// Words (and empty gaps) before each Space typed since the last reset, so that backspacing
    /// over a Space brings the previous word back and editing it still works.
    private var history: [(keys: [Key], atStart: Bool)] = []
    private var last: Correction?

    private var active: Bool { settings.enabled }

    func start() {
        // App Nap would delay the event tap after a while in the background.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "Watching typing")
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
                if self?.installTap() ?? true { t.invalidate(); self?.updateMenu(); logLine("running") }
            }
        } else { logLine("running") }
    }

    func report() {
        headless = true
        reloadIfChanged(force: true)
        print("English layout:   \(layouts.english?.id ?? "NOT FOUND")")
        print("Ukrainian layout: \(layouts.ukrainian?.id ?? "NOT FOUND")")
        print("English words:    \(lexicon.describe("en"))")
        print("Ukrainian words:  \(lexicon.describe("uk"))")
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
            // The user changed layout mid-word: the tracked keys no longer describe the text.
            // Our own switch after a fix is ignored (keys typed since then are re-checked anyway).
            guard let self = self, Date() > self.ownSwitchUntil, !self.buffer.isEmpty else { return }
            self.buffer.removeAll(); self.atWordStart = false; self.history.removeAll()
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
        settings = Config.load()
        DebugLog.on = settings.debugLog
        stamps = [Files.modified(Files.settings), Files.modified(Files.exceptions)]
        layouts.reload(settings)
        lexicon.reloadWordLists()
        updateMenu()
    }

    // MARK: Event handling

    private func reset() { buffer.removeAll(); atWordStart = false; last = nil; history.removeAll() }

    private var ownSwitchUntil = Date.distantPast

    private func selectLayout(_ source: TISInputSource) {
        ownSwitchUntil = Date().addingTimeInterval(1.5)
        TISSelectInputSource(source)
    }

    private func pushWord(_ keys: [Key]) {
        history.append((keys, atWordStart))
        if history.count > 10 { history.removeFirst() }
    }

    fileprivate func handle(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .keyDown: break
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            DebugLog.write("event tap was disabled by macOS (\(type.rawValue)); re-enabled")
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
            if isRepeat { reset(); atWordStart = true; return pass }
            if !buffer.isEmpty, correct(proxy) { return nil }
            pushWord(buffer)
            buffer.removeAll(); atWordStart = true
        case kVK_Delete:
            if isRepeat { reset() }
            else if !buffer.isEmpty { buffer.removeLast() }
            else if let prev = history.popLast() {           // deleted a Space: back into the previous word
                buffer = prev.keys; atWordStart = prev.atStart
            }
            else { atWordStart = false }                     // deleting into text we never saw
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
        func skip(_ why: String) -> Bool { DebugLog.write("skip: \(why)"); return false }
        guard active else { return false }
        guard buffer.count >= settings.minLength, buffer.count <= settings.maxLength else {
            return skip("length \(buffer.count) outside \(settings.minLength)…\(settings.maxLength)")
        }
        let appID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
        if settings.excludedApps.contains(appID) { return skip("excluded app \(appID)") }
        guard let pair = layouts.pair() else { return skip("current layout is not English/Ukrainian, or the other one is not enabled") }
        guard lexicon.supports(pair.from.lang), lexicon.supports(pair.to.lang) else {
            return skip("no dictionary — en: \(lexicon.describe("en")); uk: \(lexicon.describe("uk"))")
        }

        var typed = "", converted = ""
        var newChars: [String] = []
        for key in buffer {
            // Re-deriving each char through the current layout must reproduce what was typed
            // (guards against dead keys, input methods, remapping tools); otherwise do nothing.
            guard pair.from.char(for: key) == key.char, let c = pair.to.char(for: key) else {
                return skip("key \(key.code) does not map cleanly in \(pair.from.id)/\(pair.to.id)")
            }
            typed += key.char
            converted += c
            newChars.append(c)
        }

        guard Decision.shouldConvert(typed: typed, converted: converted,
                                     fromLang: pair.from.lang, toLang: pair.to.lang,
                                     minLength: settings.minLength,
                                     exceptions: settings.exceptions.union(sessionIgnore),
                                     isWord: lexicon.isWord) else {
            return skip("'\(typed)' → '\(converted)': typed is a word, or result is not a word (\(pair.to.lang))")
        }

        // Only touch the text if we are sure it is exactly the word we tracked.
        let field = FocusedField.check(expect: typed)
        switch field {
        case .verified: break
        case .unverified: guard atWordStart else { return skip("text unreadable in \(appID) and word start not seen") }
        case .unknown, .notText:
            guard !settings.requireTextField, atWordStart else { return skip("not a text field (\(field)) in \(appID)") }
        case .secure, .mismatch: return skip("field check: \(field) in \(appID)")
        }
        DebugLog.write("fix: '\(typed)' → '\(converted)' in \(appID)")

        for _ in buffer { post(UInt16(kVK_Delete), nil, shift: false, proxy) }
        for (key, c) in zip(buffer, newChars) { post(key.code, c, shift: key.shift, proxy) }
        post(UInt16(kVK_Space), " ", shift: false, proxy)
        selectLayout(pair.to.source)

        last = Correction(typed: buffer, inserted: converted, from: pair.from.source,
                          word: Decision.core(typed), time: Date())
        // Remember the word as it now appears, so backspacing into it keeps working.
        pushWord(zip(buffer, newChars).map { Key(code: $0.code, shift: $0.shift, caps: $0.caps, char: $1) })
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
        selectLayout(c.from)

        if let top = history.popLast() { history.append((c.typed, top.atStart)) }   // the original is back
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
        if headless { return }
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
                item.button?.title = "ЯR"
            }
            let menu = NSMenu()
            menu.delegate = self
            func add(_ title: String, _ action: Selector, tag: Int = 0) {
                let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
                mi.target = self
                mi.tag = tag
                menu.addItem(mi)
            }
            add("Paused: secure input is on", #selector(explainSecureInput), tag: 4)
            add("Allow Accessibility…", #selector(openAccessibility), tag: 3)
            add("Enabled", #selector(toggleEnabled), tag: 1)
            menu.addItem(NSMenuItem.separator())
            add("Settings…", #selector(openSettings))
            menu.addItem(NSMenuItem.separator())
            add("Quit KBSwitch", #selector(quit))
            item.menu = menu
            statusItem = item
        }
        let trusted = AXIsProcessTrusted()
        statusItem?.button?.appearsDisabled = !active || !trusted
        statusItem?.menu?.item(withTag: 3)?.isHidden = trusted
        let secureInput: Bool = IsSecureEventInputEnabled() == true   // compiles whether Bool or DarwinBoolean
        statusItem?.menu?.item(withTag: 4)?.isHidden = !secureInput
        statusItem?.menu?.item(withTag: 1)?.state = active ? .on : .off
    }

    @objc private func toggleEnabled() {
        var c = Config.load()
        c.enabled.toggle()
        c.save()
        reset()
        reloadIfChanged(force: true)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    func menuWillOpen(_ menu: NSMenu) { updateMenu() }

    @objc private func explainSecureInput() {
        let alert = NSAlert()
        alert.messageText = "Secure input is on"
        alert.informativeText = "While a password field is focused, or an app such as Terminal (Secure Keyboard Entry) or a password manager enables secure input, macOS hides typing from all other apps. KBSwitch resumes automatically when it ends."
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func openAccessibility() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func openSettings() {
        if let w = settingsWindow, w.isVisible {
            NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil); return
        }
        let model = SettingsModel { [weak self] in self?.reloadIfChanged(force: true) }
        let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
        w.title = "KBSwitch"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.center()
        settingsWindow = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    // Opening the app again (Finder, Spotlight) shows Settings, even if the menu-bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }
}

// MARK: - Settings window

final class SettingsModel: ObservableObject {
    @Published var config: Config {
        didSet {
            config.save()
            onChange()
        }
    }
    @Published var exceptions: String {
        didSet {
            let words = exceptions.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            try? (words.joined(separator: "\n") + "\n").write(to: Files.exceptions, atomically: true, encoding: .utf8)
            onChange()
        }
    }
    @Published var startAtLogin: Bool
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.config = Config.load()
        self.exceptions = Files.lines(Files.exceptions).joined(separator: "\n")
        self.startAtLogin = SMAppService.mainApp.status == .enabled
        self.onChange = onChange
    }

    func setStartAtLogin(_ on: Bool) {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { logLine("login item: \(error)") }
        startAtLogin = SMAppService.mainApp.status == .enabled
    }

    var apps: [String] { config.excludedApps.sorted { name($0).lowercased() < name($1).lowercased() } }

    func name(_ id: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return id }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    func addApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier { config.excludedApps.insert(id) }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Toggle("Enabled", isOn: $model.config.enabled)
                Toggle("Start at login", isOn: Binding(get: { model.startAtLogin },
                                                       set: { model.setStartAtLogin($0) }))
                Toggle("Show in menu bar", isOn: $model.config.menuBarIcon)
            }
            Section {
                Stepper("Minimum word length: \(model.config.minLength)", value: $model.config.minLength, in: 1...10)
                Stepper("Maximum word length: \(model.config.maxLength)", value: $model.config.maxLength, in: 3...60)
                Toggle("Only in text fields", isOn: $model.config.requireTextField)
                Picker("Undo a fix with", selection: $model.config.undoKey) {
                    Text("Esc").tag("escape")
                    Text("Backspace").tag("backspace")
                    Text("Off").tag("none")
                }
                Toggle("Never convert undone words again", isOn: $model.config.learnOnUndo)
            }
            Section {
                TextEditor(text: $model.exceptions)
                    .font(.body.monospaced())
                    .frame(height: 80)
            } header: {
                Text("Never convert")
            } footer: {
                Text("One word per line, in either layout.").foregroundStyle(.secondary)
            }
            Section {
                ForEach(model.apps, id: \.self) { id in
                    HStack {
                        Text(model.name(id))
                        Spacer()
                        Button { model.config.excludedApps.remove(id) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                Button("Add App…") { model.addApps() }
            } header: {
                Text("Ignored apps")
            }
            Section {
                Toggle("Write diagnostic log", isOn: $model.config.debugLog)
            } footer: {
                Text("Logs why words were or weren't fixed to ~/Library/Logs/KBSwitch.log. Includes the words, so keep it off normally.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 620)
    }
}

// MARK: - Main

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let engine = Engine()
app.delegate = engine
if CommandLine.arguments.contains("--unregister") {   // used by uninstall.sh
    try? SMAppService.mainApp.unregister()
    exit(0)
}
if CommandLine.arguments.contains("--check") {
    engine.report()
    exit(0)
}
engine.start()
app.run()
