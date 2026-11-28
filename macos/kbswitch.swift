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
    /// Starts a fresh log with a header describing the setup.
    static func start(_ header: String) {
        try? ("KBSwitch diagnostic log\n" + header + "\n").data(using: .utf8)?.write(to: url)
    }
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
    var transliteration = false
    var typoFixing = "off"          // off | careful | smart
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
            case "undo_key": s.undoKey = ["none", "backspace"].contains(value.lowercased()) ? value.lowercased() : "escape"
            case "learn_on_undo": s.learnOnUndo = flag
            case "require_text_field": s.requireTextField = flag
            case "electron_accessibility": s.electronAccessibility = flag
            case "menu_bar_icon": s.menuBarIcon = flag
            case "debug_log": s.debugLog = flag
            case "transliteration": s.transliteration = flag
            case "autocorrect": if flag && s.typoFixing == "off" { s.typoFixing = "careful" }   // older setting
            case "typo_fixing": if ["off", "careful", "smart"].contains(value.lowercased()) { s.typoFixing = value.lowercased() }
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
        transliteration = \(transliteration)
        typo_fixing = \(typoFixing)

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
    /// Which key (and Shift) types each character in this layout.
    lazy var keyFor: [String: (code: UInt16, shift: Bool)] = {
        var map: [String: (code: UInt16, shift: Bool)] = [:]
        for code in UInt16(0)..<UInt16(51) {
            for shift in [false, true] {
                if let c = self.char(for: Key(code: code, shift: shift, caps: false, char: "")), map[c] == nil {
                    map[c] = (code, shift)
                }
            }
        }
        return map
    }()

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

    /// Which layout the keys were typed in, decided from the characters they actually produced
    /// (macOS's "current layout" can be stale for a background app right after a manual switch).
    func pair(for keys: [Key]) -> (from: KeyLayout, to: KeyLayout)? {
        guard let en = english, let uk = ukrainian else { return nil }
        let inEnglish = keys.allSatisfy { en.char(for: $0) == $0.char }
        let inUkrainian = keys.allSatisfy { uk.char(for: $0) == $0.char }
        switch (inEnglish, inUkrainian) {
        case (true, false): return (en, uk)
        case (false, true): return (uk, en)
        default: return nil            // ambiguous, or typed in some other layout
        }
    }

    static func currentID() -> String {
        guard let cur = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return "?" }
        return (tisValue(cur, kTISPropertyInputSourceID) as? String) ?? "?"
    }
}

// MARK: - Transliteration (optional): privit → привіт

enum Translit {
    /// Latin spellings and the Cyrillic they can stand for, most likely first. Casual and official
    /// (KMU 2010) romanisations both occur, and the soft sign is usually left out (sohodni →
    /// сьогодні), so several readings are tried against the dictionary.
    private static let table: [(String, [String])] = [
        ("shch", ["щ"]), ("sch", ["щ"]),
        ("zh", ["ж"]), ("kh", ["х"]), ("ch", ["ч"]), ("sh", ["ш", "сх"]), ("ts", ["ц", "ць", "тс"]), ("tz", ["ц"]),
        ("ya", ["я"]), ("ja", ["я"]), ("ia", ["я", "іа"]),
        ("yu", ["ю"]), ("ju", ["ю"]), ("iu", ["ю", "іу"]),
        ("ye", ["є"]), ("je", ["є"]), ("ie", ["є", "іе"]),
        ("yi", ["ї"]), ("ji", ["ї"]), ("yo", ["йо"]), ("jo", ["йо"]),
        ("a", ["а"]), ("b", ["б"]), ("c", ["ц", "к"]), ("d", ["д", "дь"]), ("e", ["е", "є"]), ("f", ["ф"]),
        ("g", ["г", "ґ"]), ("h", ["г", "х"]), ("i", ["і", "и", "ї", "й"]), ("j", ["й"]), ("k", ["к"]),
        ("l", ["л", "ль"]), ("m", ["м"]), ("n", ["н", "нь"]), ("o", ["о"]), ("p", ["п"]), ("q", ["к"]), ("r", ["р"]),
        ("s", ["с", "сь"]), ("t", ["т", "ть"]), ("u", ["у"]), ("v", ["в"]), ("w", ["в"]), ("x", ["кс", "х"]),
        ("y", ["и", "й"]), ("z", ["з", "зь"]), ("'", ["ь", "ʼ"]), ("`", ["ь"]),
    ]
    private static let maxTries = 400        // keeps the worst case to a few milliseconds

    /// First reading of a lowercase Latin word that `isWord` accepts, or nil.
    static func convert(_ latin: String, isWord: (String) -> Bool) -> String? {
        let chars = Array(latin)
        var tries = 0
        var found: String?
        func walk(_ i: Int, _ acc: String) {
            if found != nil || tries >= maxTries { return }
            if i == chars.count {
                tries += 1
                if isWord(acc) { found = acc }
                return
            }
            for (latinPart, options) in table {
                let p = Array(latinPart)
                guard i + p.count <= chars.count, Array(chars[i ..< i + p.count]) == p else { continue }
                for o in options { walk(i + p.count, acc + o); if found != nil { return } }
            }
        }
        walk(0, "")
        return found
    }
}

// MARK: - Typos (optional): one letter off

enum Typos {
    static let alphabet: [String: [Character]] = [
        "en": Array("abcdefghijklmnopqrstuvwxyz"),
        "uk": Array("абвгґдеєжзиіїйклмнопрстуфхцчшщьюя'"),
    ]

    /// Physical key positions (row, column) by macOS virtual key code (letter rows, ANSI).
    static let grid: [UInt16: (row: Int, col: Int)] = {
        let rows: [[UInt16]] = [[12, 13, 14, 15, 17, 16, 32, 34, 31, 35, 33, 30],
                                [0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39],
                                [6, 7, 8, 9, 11, 45, 46, 43, 47, 44]]
        var g: [UInt16: (row: Int, col: Int)] = [:]
        for (r, row) in rows.enumerated() { for (c, k) in row.enumerated() { g[k] = (r, c) } }
        return g
    }()

    /// Keys that touch on a staggered keyboard: left/right, two above, two below.
    static func adjacent(_ a: (row: Int, col: Int), _ b: (row: Int, col: Int)) -> Bool {
        switch b.row - a.row {
        case 0: return abs(b.col - a.col) == 1
        case -1: return b.col == a.col || b.col == a.col + 1
        case 1: return b.col == a.col || b.col == a.col - 1
        default: return false
        }
    }

    static func isPlain(_ w: String, _ lang: String) -> Bool {
        guard let letters = alphabet[lang], !w.isEmpty, w == w.lowercased() else { return false }
        return w.allSatisfy { letters.contains($0) } && w.first != "'" && w.last != "'"
    }

    /// The one word that `word` becomes by undoing a single common slip, or nil if there is none or
    /// more than one. Only these slips are considered, because they are what fingers actually do and
    /// they rarely turn one valid word into another:
    ///   - two neighbouring letters swapped          implemnet → implement
    ///   - a key right next to the intended one      hwllo → hello   (inside words of 5+ letters)
    ///   - a letter doubled by accident              helllo → hello
    ///   - a double letter typed once                adress → address
    /// (Arbitrary missing or extra letters are not: iphone would become phone.)
    static func correction(of word: String, lang: String, near: (Character, Character) -> Bool,
                           isWord: (String) -> Bool, deadline: Date) -> String? {
        guard let letters = alphabet[lang] else { return nil }
        let w = Array(word), n = w.count
        // Stretched words (hmmm, sooo, ахааа) are written that way on purpose.
        for i in 2 ..< n where w[i] == w[i - 1] && w[i] == w[i - 2] { return nil }
        var found = Set<String>()
        var checked = Set<String>()
        func consider(_ c: [Character]) -> Bool {
            let s = String(c)
            guard s != word, checked.insert(s).inserted else { return true }
            if Date() > deadline { return false }
            if isWord(s) { found.insert(s) }
            return found.count < 2                                   // a second hit: ambiguous, stop
        }
        for i in 0 ..< n - 1 where w[i] != w[i + 1] {
            var c = w; c.swapAt(i, i + 1); if !consider(c) { return nil }
        }
        // Neighbouring-key slips only inside words of 5+ letters: an unknown short word, or a first or
        // last letter (slang, names, Ukrainian endings), too easily turns into some other real word.
        if n >= 5 {
            for i in 1 ..< n - 1 {
                for ch in letters where ch != w[i] && near(w[i], ch) {
                    var c = w; c[i] = ch; if !consider(c) { return nil }
                }
            }
        }
        for i in 1 ..< n where w[i] == w[i - 1] {
            var c = w; c.remove(at: i); if !consider(c) { return nil }
        }
        for i in 0 ..< n {
            var c = w; c.insert(w[i], at: i); if !consider(c) { return nil }
        }
        return found.count == 1 ? found.first : nil
    }
}

// MARK: - Smart typo fixing (shared C++ engine, ../engine)

private func withOptionalCString<R>(_ s: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
    if let s = s { return s.withCString { body($0) } }
    return body(nil)
}

/// English and Ukrainian language models (word frequencies + word pairs, ../model/*.kbm), loaded in
/// the background so starting the app stays instant. Used on the main thread only.
final class SmartCorrector {
    private var en: OpaquePointer?
    private var uk: OpaquePointer?
    private var loading = false
    private var generation = 0                       // bumped by unload(): a load in flight is discarded
    var ready: Bool { en != nil && uk != nil }

    /// Frees the language data (about 20 MB) and gives the memory back to macOS.
    func unload() {
        generation += 1
        loading = false
        guard en != nil || uk != nil else { return }
        if let e = en { kb_free(e) }
        if let u = uk { kb_free(u) }
        en = nil
        uk = nil
        malloc_zone_pressure_relief(nil, 0)
        DebugLog.write("smart typo fixing: language data unloaded")
    }

    func load(keys: [(lang: String, code: UInt32, row: Int32, col: Int32)], learned: [String]) {
        guard !ready, !loading else { learn(learned); return }
        loading = true
        let gen = generation
        DispatchQueue.global(qos: .utility).async {
            let e = Bundle.main.path(forResource: "en", ofType: "kbm").flatMap { kb_load($0) }
            let u = Bundle.main.path(forResource: "uk", ofType: "kbm").flatMap { kb_load($0) }
            DispatchQueue.main.async {
                guard gen == self.generation else {          // turned off while loading
                    if let e = e { kb_free(e) }
                    if let u = u { kb_free(u) }
                    malloc_zone_pressure_relief(nil, 0)
                    return
                }
                self.en = e
                self.uk = u
                self.loading = false
                for k in keys { kb_set_key(k.lang == "en" ? e : u, k.code, k.row, k.col) }
                self.learn(learned)
                DebugLog.write("smart typo fixing: language data \(self.ready ? "loaded" : "MISSING")")
            }
        }
    }

    /// Words the user writes on purpose: never corrected, may be suggested.
    func learn(_ words: [String]) {
        for w in words { kb_learn(en, w); kb_learn(uk, w) }
    }

    /// `valid`: the word is in the dictionary (then only a rare word one slip from a very common one changes).
    /// How plausible `word` is as meant in `lang` (itself, or its best correction minus the slip).
    func reading(_ word: String, lang: String, prev: String?) -> Double {
        guard let m = lang == "en" ? en : uk else { return -1e9 }
        return withOptionalCString(prev) { p in kb_reading(m, word, p) }
    }

    func correct(_ word: String, lang: String, prev: String?, next: String?, valid: Bool = false) -> String? {
        guard let m = lang == "en" ? en : uk else { return nil }
        var out = [CChar](repeating: 0, count: 256)
        let size = Int32(out.count)
        let ok = withOptionalCString(prev) { p in
            withOptionalCString(next) { n in kb_correct(m, word, p, n, valid ? 1 : 0, &out, size, nil) }
        }
        return ok == 1 ? String(cString: out) : nil
    }
}

// MARK: - Dictionary (offline macOS spell checker + optional word lists)

final class Lexicon {
    private let checker = NSSpellChecker.shared
    private var spellCode: [String: String] = [:]     // "en" -> code the macOS spell checker understands
    private var extra: [String: Set<String>] = [:]    // optional ~/.config/kbswitch/words_<lang>.txt
    /// Ukrainian is checked with Hunspell and the LibreOffice uk_UA dictionary bundled in the app:
    /// macOS only partly understands that dictionary and rejects many valid forms (заплітала).
    private var hunspell: OpaquePointer?
    private var hunspellSource = ""

    init() {
        let available = checker.availableLanguages
        for lang in ["en", "uk"] {
            let exact = available.first(where: { $0 == lang })
            spellCode[lang] = exact ?? available.first(where: { $0.hasPrefix(lang + "_") || $0.hasPrefix(lang + "-") })
        }
        if let code = spellCode["en"] {      // warm up so the first real check is fast
            _ = checker.checkSpelling(of: "test", startingAt: 0, language: code, wrap: false,
                                      inSpellDocumentWithTag: 0, wordCount: nil)
        }
        reloadWordLists()
    }

    /// Loads the Ukrainian dictionary (about 30 MB in memory). Only while KBSwitch is enabled.
    func load() {
        guard hunspell == nil else { return }
        let candidates = [Bundle.main.resourceURL, FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Spelling")].compactMap { $0 }
        for dir in candidates {
            let aff = dir.appendingPathComponent("uk_UA.aff"), dic = dir.appendingPathComponent("uk_UA.dic")
            guard FileManager.default.fileExists(atPath: aff.path), FileManager.default.fileExists(atPath: dic.path)
            else { continue }
            if let h = Hunspell_create(aff.path, dic.path) { hunspell = h; hunspellSource = dic.path; break }
        }
    }

    /// Frees the dictionary and gives the memory back to macOS.
    func unload() {
        guard let h = hunspell else { return }
        Hunspell_destroy(h)
        hunspell = nil
        malloc_zone_pressure_relief(nil, 0)
    }

    func reloadWordLists() {
        for lang in ["en", "uk"] {
            extra[lang] = Set(Files.lines(Files.words(lang)).map { $0.lowercased() })
        }
    }

    func describe(_ lang: String) -> String {
        if lang == "uk", hunspell != nil { return "hunspell \(hunspellSource), extra words: \(extra[lang]?.count ?? 0)" }
        return "spell checker: \(spellCode[lang] ?? "MISSING"), extra words: \(extra[lang]?.count ?? 0)"
    }

    /// Without a dictionary for a language, every word would look "misspelled": never act then.
    func supports(_ lang: String) -> Bool {
        (lang == "uk" && hunspell != nil) || spellCode[lang] != nil || !(extra[lang]?.isEmpty ?? true)
    }

    /// A checker only has an opinion about words in its own alphabet (the macOS English checker,
    /// for one, accepts any Cyrillic word).
    private func inScript(_ word: String, _ lang: String) -> Bool {
        word.allSatisfy { c in
            guard c.isLetter else { return "'’ʼ-`".contains(c) }
            guard let v = c.unicodeScalars.first?.value, c.unicodeScalars.count == 1 else { return false }
            return lang == "uk" ? (0x0400...0x04FF).contains(v) : (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v)
        }
    }

    func isWord(_ word: String, _ lang: String) -> Bool {
        guard !word.isEmpty, inScript(word, lang) else { return false }
        let variants = word == word.lowercased() ? [word] : [word, word.lowercased()]
        for v in variants {
            if extra[lang]?.contains(v.lowercased()) == true { return true }
            if lang == "uk", let h = hunspell {
                if Hunspell_spell(h, v.replacingOccurrences(of: "’", with: "'")) != 0 { return true }
                continue
            }
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

    /// Letters of one alphabet (inner apostrophe/hyphen allowed) in natural casing: word, Word, WORD.
    static func isCleanWord(_ w: String, _ lang: String) -> Bool {
        guard let first = w.first, let last = w.last, isLetter(first, lang), isLetter(last, lang),
              w.allSatisfy({ isLetter($0, lang) || innerMarks.contains($0) }) else { return false }
        let letters = w.filter { $0.isLetter }
        let capitalized = letters.prefix(1).uppercased() + letters.dropFirst().lowercased()
        return letters == letters.lowercased() || letters == letters.uppercased() || letters == capitalized
    }

    /// nil = convert; otherwise the reason not to (used for the diagnostic log).
    static func rejection(typed: String, converted: String, fromLang: String, toLang: String,
                          minLength: Int, exceptions: Set<String>,
                          isWord: (String, String) -> Bool) -> String? {
        if typed == converted { return "same text in both layouts" }
        if typed.contains(where: { $0.isNumber }) { return "contains digits" }
        let src = core(typed), dst = core(converted)
        if src.isEmpty { return "only punctuation" }
        if dst.count < minLength { return "result '\(dst)' shorter than \(minLength)" }

        // The result must be a clean word in the target script (letters, inner apostrophe/hyphen).
        guard let first = dst.first, let last = dst.last,
              isLetter(first, toLang), isLetter(last, toLang),
              dst.allSatisfy({ isLetter($0, toLang) || innerMarks.contains($0) }) else {
            return "result '\(dst)' is not a clean \(toLang) word"
        }
        // Natural casing only: word, Word or WORD.
        let letters = dst.filter { $0.isLetter }
        let capitalized = letters.prefix(1).uppercased() + letters.dropFirst().lowercased()
        guard letters == letters.lowercased() || letters == letters.uppercased() || letters == capitalized
        else { return "unusual casing '\(dst)'" }

        for w in [typed, src, dst] where exceptions.contains(w.lowercased()) { return "'\(w)' is in exceptions" }

        // Strict rule: what you typed is not a word, and what it becomes is a word.
        if isWord(src, fromLang) { return "'\(src)' is a real \(fromLang) word" }
        if !isWord(dst, toLang) { return "'\(dst)' is not a \(toLang) word" }
        return nil
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

    static var detail = ""         // what the last check saw (diagnostic log)
    /// Index of the candidate found before the caret by the last `check` that returned `.verified`.
    static var matched = -1

    /// Checks that the focused element is an editable text field and that the text right before
    /// the caret is exactly `word`, preceded by whitespace / an opening bracket / start of text.
    static func check(expect word: String) -> FieldState { check(candidates: [word]) }

    /// Same, for several possible spellings of the same keys (one per layout): `matched` tells
    /// which one is really in the field. This is the ground truth for what was typed.
    static func check(candidates: [String]) -> FieldState {
        detail = ""
        matched = -1
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
        detail = "role=\(role) editable=\(editable)"
        guard textRoles.contains(role) || editable else { return .notText }

        // Apps draw keystrokes asynchronously: when typing fast the last letters may not be in the
        // field yet. Re-read a few times before deciding the text doesn't match.
        var result = FieldState.mismatch
        for attempt in 0..<4 {
            if attempt > 0 { usleep(15_000) }
            result = compare(el, candidates)
            if result != .mismatch { break }
        }
        return result
    }

    /// The word right before the caret (back to whitespace, an opening bracket or the start of the
    /// text), or nil if the focused element isn't a readable text field or there's a selection.
    static func wordBeforeCaret(maxLength: Int = 48) -> String? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.08)
        guard let f = attr(system, kAXFocusedUIElementAttribute),
              CFGetTypeID(f) == AXUIElementGetTypeID() else { return nil }
        let el = f as! AXUIElement
        AXUIElementSetMessagingTimeout(el, 0.08)
        if (attr(el, kAXSubroleAttribute) as? String) == kAXSecureTextFieldSubrole { return nil }
        guard let rv = attr(el, kAXSelectedTextRangeAttribute), CFGetTypeID(rv) == AXValueGetTypeID() else { return nil }
        var sel = CFRange()
        guard AXValueGetValue(rv as! AXValue, .cfRange, &sel), sel.length == 0 else { return nil }
        usleep(15_000)                                   // let the app draw the last keystrokes
        let from = max(0, sel.location - maxLength - 1)
        guard let text = string(el, CFRange(location: from, length: sel.location - from)) else { return nil }
        if let i = text.lastIndex(where: { $0.isWhitespace || openers.contains($0) }) {
            return String(text[text.index(after: i)...])
        }
        return from == 0 ? text : nil                    // no boundary within reach: give up
    }

    private static func compare(_ el: AXUIElement, _ candidates: [String]) -> FieldState {
        guard let rv = attr(el, kAXSelectedTextRangeAttribute),
              CFGetTypeID(rv) == AXValueGetTypeID() else { return .unverified }
        var sel = CFRange()
        guard AXValueGetValue(rv as! AXValue, .cfRange, &sel) else { return .unverified }
        guard sel.length == 0 else { detail += " selection"; return .mismatch }
        let longest = candidates.map { $0.utf16.count }.max() ?? 0
        let from = max(0, sel.location - longest - 1)
        guard let text = string(el, CFRange(location: from, length: sel.location - from)) else {
            detail += " caret=\(sel.location) text=unreadable"; return .unverified
        }
        detail += " caret=\(sel.location) before-caret='\(text)'"
        for (i, word) in candidates.enumerated() where !word.isEmpty && text.hasSuffix(word) {
            let start = sel.location - word.utf16.count
            let before = text.dropLast(word.count)
            let boundary: Bool
            if start == 0 { boundary = true }
            else if let c = before.last { boundary = c.isWhitespace || openers.contains(c) }
            else { boundary = false }
            if boundary { matched = i; return .verified }
        }
        return .mismatch
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
    let words: [String]       // the original word(s), for exceptions when undone
    let time: Date
}

final class Engine: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let marker: Int64 = 0x4B42_5357          // tags our own synthetic events
    private var settings = Config()
    private var stamps: [Date?] = [nil, nil]
    private let layouts = Layouts()
    private let lexicon = Lexicon()
    private let smart = SmartCorrector()
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
    private var wordEdited = false      // Backspace was used in this word: re-read it from the field
    /// Words (and empty gaps) before each Space typed since the last reset, so that backspacing
    /// over a Space brings the previous word back and editing it still works.
    private var history: [(keys: [Key], atStart: Bool, changed: Bool)] = []
    private var last: Correction?
    /// The key that ended the word being checked: Space, or Return (with Shift if held). A fix types
    /// it again after the corrected word, so a message is sent (or a line broken) with the fixed text.
    private var endKey: (code: UInt16, shift: Bool) = (UInt16(kVK_Space), false)

    private var active: Bool { settings.enabled }

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
                if self?.installTap() ?? true { t.invalidate(); self?.updateMenu(); logLine("running") }
            }
        } else { logLine("running") }
    }

    func report() {
        headless = true
        reloadIfChanged(force: true)
        lexicon.load()
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
        CGEvent.tapEnable(tap: t, enable: settings.enabled)
        DebugLog.write("event tap installed (pid \(ProcessInfo.processInfo.processIdentifier), Accessibility \(AXIsProcessTrusted()))")
        return true
    }

    private func observeSystem() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            self?.reset("switched app")
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.exposeElectron(app)
            }
        }
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
                        object: nil, queue: .main) { [weak self] _ in
            // The user changed layout mid-word: the tracked keys no longer describe the text.
            // Our own switch after a fix is ignored (keys typed since then are re-checked anyway).
            guard let self = self else { return }
            let own = Date() <= self.ownSwitchUntil
            DebugLog.write("layout changed to \(Layouts.currentID())\(own ? " (by KBSwitch)" : " (by you)")")
            // Nothing to discard: keys are matched against both layouts when Space is pressed.
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
        let wasLogging = DebugLog.on
        DebugLog.on = settings.debugLog
        stamps = [Files.modified(Files.settings), Files.modified(Files.exceptions)]
        layouts.reload(settings)
        lexicon.reloadWordLists()
        applyEnabled()
        if DebugLog.on && !wasLogging { DebugLog.start(diagnostics()) }
        updateMenu()
    }

    /// Only what's switched on is loaded. Disabled: the event tap is off (no key ever reaches
    /// KBSwitch), both dictionaries are freed and App Nap may suspend the app. Smart typo fixing
    /// off: its language data is freed. Transliteration and Careful mode use small built-in tables.
    private func applyEnabled() {
        let on = settings.enabled
        if let t = tap, CGEvent.tapIsEnabled(tap: t) != on { CGEvent.tapEnable(tap: t, enable: on) }
        if on {
            lexicon.load()
            // App Nap would delay the event tap after a while in the background.
            if activity == nil {
                activity = ProcessInfo.processInfo.beginActivity(
                    options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "Watching typing")
            }
        } else {
            buffer.removeAll(); history.removeAll(); atWordStart = false; last = nil
            lexicon.unload()
            if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
        }
        if on && settings.typoFixing == "smart" { startSmart() } else { smart.unload() }
    }

    /// Loads the language data (once) and tells it the keyboard and the user's own words.
    private func startSmart() {
        var keys: [(lang: String, code: UInt32, row: Int32, col: Int32)] = []
        for (lang, layout) in [("en", layouts.english), ("uk", layouts.ukrainian)] {
            guard let layout = layout, let letters = Typos.alphabet[lang] else { continue }
            for ch in letters where ch != "'" {
                guard let k = layout.keyFor[String(ch)], let p = Typos.grid[k.code],
                      let scalar = ch.unicodeScalars.first else { continue }
                keys.append((lang, scalar.value, Int32(p.row), Int32(p.col)))
            }
        }
        smart.load(keys: keys, learned: Array(settings.exceptions.union(sessionIgnore)))
    }

    private func diagnostics() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersionString
        let app = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return """
        macOS \(v) · KBSwitch \(app) · pid \(ProcessInfo.processInfo.processIdentifier)
        English layout: \(layouts.english?.id ?? "NOT FOUND") · Ukrainian layout: \(layouts.ukrainian?.id ?? "NOT FOUND") · current: \(Layouts.currentID())
        en: \(lexicon.describe("en")) · uk: \(lexicon.describe("uk"))
        Accessibility: \(AXIsProcessTrusted()) · event tap: \(tap != nil) · secure input: \(IsSecureEventInputEnabled() == true)
        typo fixing: \(settings.typoFixing)\(settings.typoFixing == "smart" ? (smart.ready ? " (language data loaded)" : " (loading)") : "")
        min=\(settings.minLength) max=\(settings.maxLength) undo=\(settings.undoKey) textFieldsOnly=\(settings.requireTextField) excluded=\(settings.excludedApps.sorted())
        """
    }

    // MARK: Event handling

    private func reset(_ why: String) {
        translitStreak = false
        if DebugLog.on, !buffer.isEmpty || !history.isEmpty || atWordStart {
            DebugLog.write("forget word \(spell(buffer)): \(why)")
        }
        buffer.removeAll(); atWordStart = false; last = nil; history.removeAll(); wordEdited = false
    }

    private var ownSwitchUntil = Date.distantPast

    private func selectLayout(_ source: TISInputSource) {
        ownSwitchUntil = Date().addingTimeInterval(1.5)
        TISSelectInputSource(source)
        // macOS can drop a switch asked for right after another one (fix, then undo within a second):
        // check that it took, and ask again up to three times.
        let wanted = tisValue(source, kTISPropertyInputSourceID) as? String
        layoutRequest += 1
        let request = layoutRequest
        func verify(_ tries: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self = self, request == self.layoutRequest, let wanted = wanted else { return }
                let now = Layouts.currentID()
                guard now != wanted else { return }
                DebugLog.write("layout is \(now), not \(wanted): switching again")
                self.ownSwitchUntil = Date().addingTimeInterval(1.5)
                TISSelectInputSource(source)
                if tries > 1 { verify(tries - 1) }
            }
        }
        verify(3)
    }
    private var layoutRequest = 0

    /// "en|uk" spelling of keys, for the log.
    private func spell(_ keys: [Key]) -> String {
        let e = keys.map { layouts.english?.char(for: $0) ?? "?" }.joined()
        let u = keys.map { layouts.ukrainian?.char(for: $0) ?? "?" }.joined()
        return "'\(e)|\(u)'"
    }

    /// `changed`: KBSwitch converted this word (or the user undid a conversion): leave it alone later.
    private func pushWord(_ keys: [Key], changed: Bool = false) {
        wordEdited = false
        history.append((keys, atWordStart, changed))
        if history.count > 10 { history.removeFirst() }
    }

    fileprivate func handle(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .keyDown: break
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let t = tap { CGEvent.tapEnable(tap: t, enable: settings.enabled) }
            DebugLog.write("event tap was disabled by macOS (\(type.rawValue)); re-enabled")
            reset("event tap re-enabled"); return pass
        default:                                   // mouse click: the caret may have moved
            reset("mouse click"); return pass
        }
        if event.getIntegerValueField(.eventSourceUserData) == Engine.marker { return pass }

        let pending = last
        last = nil
        guard active else { reset("disabled"); return pass }

        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let shortcut = !flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty

        if let p = pending, !isRepeat, !shortcut, isUndoKey(code),
           Date().timeIntervalSince(p.time) < 10, undo(p, proxy, learn: code == kVK_Escape) {
            return nil
        }
        if shortcut {
            // ⌃Space / ⌃⌥Space etc. switch the layout: the cursor doesn't move, so keep the word.
            // (Keys from two layouts in one word are rejected later anyway.)
            if code == kVK_Space { DebugLog.write("modifier+Space (layout switch?): keeping word"); return pass }
            reset("shortcut ⌘/⌃/⌥ + key \(code)"); return pass                     // shortcuts are not typing
        }

        defer {
            if DebugLog.on {
                DebugLog.write("key \(code)\(isRepeat ? " (held)" : "") → word \(spell(buffer)) wordStartSeen=\(atWordStart) history=\(history.count)")
            }
        }
        switch code {
        case kVK_Space:
            if isRepeat { reset("held Space"); atWordStart = true; return pass }
            if settings.enabled, wordEdited || (!atWordStart && !buffer.isEmpty) { rereadWord() }
            let previousFixed = settings.enabled && settings.typoFixing == "smart" && fixPreviousWord(proxy)
            if !buffer.isEmpty, correct(proxy) { return nil }
            if questionMark(proxy) { pushWord(buffer); buffer.removeAll(); atWordStart = true; return nil }
            pushWord(buffer)
            buffer.removeAll(); atWordStart = true
            if previousFixed { post(UInt16(kVK_Space), " ", shift: false, proxy); return nil }   // keep the order
        case kVK_Delete:
            // Held Backspace repeats: each repeat deletes one character, like a single press.
            // The word is re-read from the field at Space/Return anyway (`wordEdited`).
            wordEdited = true
            if !buffer.isEmpty { buffer.removeLast() }
            else if let prev = history.popLast() {           // deleted a Space: back into the previous word
                buffer = prev.keys; atWordStart = prev.atStart
                DebugLog.write("backspace over Space: back into \(spell(buffer))")
            }
            else { atWordStart = false }                     // deleting into text we never saw
        case kVK_Return, kVK_ANSI_KeypadEnter:
            // Check the last word first, like Space does: the fix goes in before the Return.
            if settings.enabled, !isRepeat, wordEdited || (!atWordStart && !buffer.isEmpty) { rereadWord() }
            if !isRepeat, !buffer.isEmpty {
                endKey = (UInt16(code), flags.contains(.maskShift))
                let fixed = correct(proxy)
                let question = !fixed && questionMark(proxy)
                endKey = (UInt16(kVK_Space), false)
                if fixed || question {
                    buffer.removeAll(); history.removeAll(); atWordStart = true; last = nil
                    return nil
                }
            }
            // A new line starts, or a message was sent: earlier words can't be returned to safely.
            buffer.removeAll(); history.removeAll(); atWordStart = true
        default:
            // Arrows, F-keys, Tab, Esc, held keys, over-long words: not part of a word we can trust.
            guard !isRepeat, let ch = printable(event), buffer.count < settings.maxLength else {
                reset(isRepeat ? "held key" : "non-typing key \(code)"); return pass
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
        let shortest = settings.transliteration ? 1 : settings.minLength   // translit: я, ти, і, в…
        guard buffer.count >= shortest, buffer.count <= settings.maxLength else {
            return skip("length \(buffer.count) outside \(settings.minLength)…\(settings.maxLength)")
        }
        // "Writing Ukrainian in Latin" lasts only while each word keeps being transliterated.
        let streak = translitStreak
        translitStreak = false
        let appID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
        if settings.excludedApps.contains(appID) { return skip("excluded app \(appID)") }
        guard let en = layouts.english, let uk = layouts.ukrainian else {
            return skip("need both an English and a Ukrainian layout enabled")
        }
        guard lexicon.supports("en"), lexicon.supports("uk") else {
            return skip("no dictionary — en: \(lexicon.describe("en")); uk: \(lexicon.describe("uk"))")
        }
        // The same keys spelled in each layout. Computed from key codes only: the characters macOS
        // reports to a background app can lag one layout switch behind.
        var enChars: [String] = [], ukChars: [String] = []
        for key in buffer {
            guard let e = en.char(for: key), let u = uk.char(for: key) else {
                return skip("key \(key.code) has no single character in \(en.id) / \(uk.id)")
            }
            enChars.append(e); ukChars.append(u)
        }
        let enText = enChars.joined(), ukText = ukChars.joined()

        // Cheap first: does converting make sense in either direction?
        let exceptions = settings.exceptions.union(sessionIgnore)
        let enToUk = Decision.rejection(typed: enText, converted: ukText, fromLang: "en", toLang: "uk",
                                        minLength: settings.minLength, exceptions: exceptions, isWord: lexicon.isWord)
        let ukToEn = Decision.rejection(typed: ukText, converted: enText, fromLang: "uk", toLang: "en",
                                        minLength: settings.minLength, exceptions: exceptions, isWord: lexicon.isWord)
        if let a = enToUk, let b = ukToEn {
            if settings.transliteration, transliterate(enChars, appID, streak: streak, proxy) { return true }
            if settings.typoFixing == "careful", fixTypo(enChars, ukChars, appID, proxy) { return true }
            if settings.typoFixing == "smart", smartFix(enChars, ukChars, appID, proxy) { return true }
            return skip("en '\(enText)' / uk '\(ukText)': nothing to fix (en→uk: \(a); uk→en: \(b))")
        }

        // What is actually on screen decides which layout was used.
        let field = FocusedField.check(candidates: [enText, ukText])
        DebugLog.write("  field: \(field) \(FocusedField.detail) · wordStartSeen=\(atWordStart)")
        let typedInEnglish: Bool
        switch field {
        case .verified:
            typedInEnglish = FocusedField.matched == 0
            if let why = typedInEnglish ? enToUk : ukToEn {
                // A Latin word that is fine as English may still be transliterated (in context).
                if typedInEnglish, settings.transliteration, transliterate(enChars, appID, streak: streak, proxy) { return true }
                // A rare word one slip from a very common one (kike → like).
                if settings.typoFixing == "smart", smartFix(enChars, ukChars, appID, proxy) { return true }
                // This word shows which language you're writing in: fix a short word before it.
                if convertShortPrevious(inEnglish: typedInEnglish, current: typedInEnglish ? enChars : ukChars, proxy) { return true }
                return skip("'\(typedInEnglish ? enText : ukText)' is on screen and is fine: \(why)")
            }
        case .unverified, .unknown, .notText:
            if field != .unverified && settings.requireTextField { return skip("not a text field (\(field)) in \(appID)") }
            guard atWordStart else { return skip("text unreadable in \(appID) and word start not seen") }
            // Can't read the text, and macOS's idea of the layout may be stale. Use the only direction
            // that makes sense: if the screen already shows the result, it is retyped unchanged.
            guard (enToUk == nil) != (ukToEn == nil) else { return skip("text unreadable and both directions possible") }
            typedInEnglish = enToUk == nil
        case .secure, .mismatch:
            return skip("field check: \(field) in \(appID)")
        }
        let pair = typedInEnglish ? (from: en, to: uk) : (from: uk, to: en)
        let fromChars = typedInEnglish ? enChars : ukChars
        let newChars = typedInEnglish ? ukChars : enChars
        let typed = fromChars.joined(), converted = newChars.joined()
        // Smart: you were writing in this language and the word is a typo of a word in it that
        // happens to spell a word in the other layout (wdsnt → цвіте, meant wasnt): don't convert.
        if settings.typoFixing == "smart", smart.ready, field == .verified,
           let before = earlierWord(1, in: pair.from, pair.from.lang), lexicon.isWord(before, pair.from.lang) {
            let asTypo = smart.reading(typed.lowercased(), lang: pair.from.lang, prev: before)
            let asLayout = smart.reading(converted.lowercased(), lang: pair.to.lang, prev: nil)
            if asTypo > asLayout - 7.5 {
                return skip("'\(typed)' after '\(before)' looks like a \(pair.from.lang) typo, not '\(converted)' (\(Int(asTypo)) vs \(Int(asLayout)))")
            }
        }
        // From here on the keys carry the characters that are really on screen.
        buffer = zip(buffer, fromChars).map { Key(code: $0.code, shift: $0.shift, caps: $0.caps, char: $1) }

        // Words just before this one, typed in the same wrong layout but left alone because they
        // were also fine as they were (s → і, d → в, ne → те): now that the context is clear,
        // convert them too. Only words KBSwitch didn't change, up to 3, and only if the field
        // shows exactly "those words + this word".
        var previous: [(from: [Key], to: [Key], fromText: String, toText: String)] = []
        if field == .verified {
            let exceptions = settings.exceptions.union(sessionIgnore)
            for entry in history.reversed() {
                guard previous.count < 3, !entry.changed, !entry.keys.isEmpty else { break }
                let f = entry.keys.compactMap { pair.from.char(for: $0) }
                let t = entry.keys.compactMap { pair.to.char(for: $0) }
                guard f.count == entry.keys.count, t.count == entry.keys.count else { break }
                let fromText = f.joined(), toText = t.joined()
                guard fromText != toText, Decision.isCleanWord(toText, pair.to.lang),
                      lexicon.isWord(toText, pair.to.lang),
                      !exceptions.contains(fromText.lowercased()), !exceptions.contains(toText.lowercased())
                else { break }
                previous.insert((zip(entry.keys, f).map { Key(code: $0.code, shift: $0.shift, caps: $0.caps, char: $1) },
                                 zip(entry.keys, t).map { Key(code: $0.code, shift: $0.shift, caps: $0.caps, char: $1) },
                                 fromText, toText), at: 0)
            }
            // Confirm on screen; if the full run doesn't match, try with fewer words.
            while !previous.isEmpty {
                let expect = (previous.map { $0.fromText } + [typed]).joined(separator: " ")
                if FocusedField.check(expect: expect) == .verified { break }
                previous.removeFirst()
            }
        }
        let before = previous.map { $0.fromText + " " }.joined()
        let beforeNew = previous.map { $0.toText + " " }.joined()
        DebugLog.write("fix: '\(before)\(typed)' → '\(beforeNew)\(converted)' in \(appID)")

        let deleteCount = buffer.count + previous.reduce(0) { $0 + $1.from.count + 1 }
        for _ in 0 ..< deleteCount { post(UInt16(kVK_Delete), nil, shift: false, proxy) }
        for p in previous {
            for k in p.to { post(k.code, k.char, shift: k.shift, proxy) }
            post(UInt16(kVK_Space), " ", shift: false, proxy)
        }
        for (key, c) in zip(buffer, newChars) { post(key.code, c, shift: key.shift, proxy) }
        postEnd(proxy)
        selectLayout(pair.to.source)

        let space = Key(code: UInt16(kVK_Space), shift: false, caps: false, char: " ")
        last = Correction(typed: previous.flatMap { $0.from + [space] } + buffer,
                          inserted: beforeNew + converted, from: pair.from.source,
                          words: previous.map { $0.fromText } + [Decision.core(typed)], time: Date())
        translitStreak = false
        // Remember the words as they now appear, so backspacing into them keeps working.
        if !previous.isEmpty {
            let starts = history.suffix(previous.count).map { $0.atStart }
            history.removeLast(previous.count)
            for (p, start) in zip(previous, starts) { history.append((p.to, start, true)) }
        }
        pushWord(zip(buffer, newChars).map { Key(code: $0.code, shift: $0.shift, caps: $0.caps, char: $1) }, changed: true)
        buffer.removeAll()
        atWordStart = true
        return true
    }

    /// The previous word was transliterated: you're writing Ukrainian in Latin right now.
    private var translitStreak = false

    /// Cyrillic reading of a Latin word typed with the English layout (trailing punctuation kept),
    /// or nil with the reason in `why`.
    private func ukrainianReading(of enText: String, allowEnglish: Bool, why: inout String) -> (output: String, word: String)? {
        let trail = String(enText.reversed().prefix(while: { ".,!?;:".contains($0) }).reversed())
        let word = String(enText.dropLast(trail.count))
        // Short words: two letters always (ya → я), one letter only mid-sentence (i → і, v → в).
        guard word.count >= (allowEnglish ? 1 : 2),
              word.allSatisfy({ ($0.isASCII && $0.isLetter) || $0 == "'" || $0 == "`" }),
              let first = word.first, first.isLetter else { why = "'\(enText)' is not a plain Latin word"; return nil }
        let lower = word.lowercased(), upper = word.uppercased()
        let capitalized = String(word.prefix(1)).uppercased() + String(word.dropFirst()).lowercased()
        guard word == lower || word == upper || word == capitalized else { why = "unusual casing '\(word)'"; return nil }
        let exceptions = settings.exceptions.union(sessionIgnore)
        guard !exceptions.contains(lower) else { why = "'\(word)' is in exceptions"; return nil }
        if !allowEnglish && lexicon.isWord(word, "en") { why = "'\(word)' is English"; return nil }
        guard var cyr = Translit.convert(lower, isWord: { self.lexicon.isWord($0, "uk") }) else {
            why = "no Ukrainian reading of '\(word)'"; return nil
        }
        guard !exceptions.contains(cyr) else { why = "'\(cyr)' is in exceptions"; return nil }
        if word == upper { cyr = cyr.uppercased() } else if word == capitalized && word != lower {
            cyr = String(cyr.prefix(1)).uppercased() + String(cyr.dropFirst())
        }
        return (cyr + trail, word)
    }

    /// Optional mode: a word typed in Latin that reads as Ukrainian (privit → привіт). Words that are
    /// also English (yak → як) are converted only in context: right after a converted word, or
    /// together with the next word once that one converts. Only in fields whose text can be read;
    /// the layout is left as it is.
    private func transliterate(_ enChars: [String], _ appID: String, streak: Bool, _ proxy: CGEventTapProxy) -> Bool {
        func skip(_ why: String) -> Bool { DebugLog.write("translit skip: \(why)"); return false }
        guard let uk = layouts.ukrainian, let en = layouts.english else { return false }
        let enText = enChars.joined()
        var why = ""
        guard let current = ukrainianReading(of: enText, allowEnglish: streak, why: &why) else { return skip(why) }

        // The word before, if it was left in Latin only because it is also English (yak spravy).
        var previous: (output: String, keys: [Key], latin: String)?
        if !streak, let prev = history.last, !prev.keys.isEmpty, !prev.changed {
            let prevLatin = prev.keys.map { en.char(for: $0) ?? "\u{0}" }.joined()
            var ignored = ""
            if let p = ukrainianReading(of: prevLatin, allowEnglish: true, why: &ignored),
               FocusedField.check(expect: prevLatin + " " + enText) == .verified {
                let keys = zip(prev.keys, prevLatin.map(String.init))
                    .map { Key(code: $0.code, shift: $0.shift, caps: $0.caps, char: $1) }
                previous = (p.output, keys, p.word)
            }
        }
        if previous == nil {
            // The field must really show the Latin word (typed in the English layout).
            let field = FocusedField.check(expect: enText)
            DebugLog.write("  translit '\(enText)' → '\(current.output)' · field: \(field) \(FocusedField.detail)")
            guard field == .verified else { return skip("field check: \(field) in \(appID)") }
        }
        let output = (previous.map { $0.output + " " } ?? "") + current.output
        DebugLog.write("translit: '\(previous.map { $0.latin + " " } ?? "")\(enText)' → '\(output)' in \(appID)")

        let deleteCount = buffer.count + (previous.map { $0.keys.count + 1 } ?? 0)
        for _ in 0 ..< deleteCount { post(UInt16(kVK_Delete), nil, shift: false, proxy) }
        var wordKeys: [[Key]] = [[]]
        var allMapped = true
        for ch in output.map(String.init) {
            if ch == " " { post(UInt16(kVK_Space), " ", shift: false, proxy); wordKeys.append([]); continue }
            if let k = uk.keyFor[ch] {
                post(k.code, ch, shift: k.shift, proxy)
                wordKeys[wordKeys.count - 1].append(Key(code: k.code, shift: k.shift, caps: false, char: ch))
            } else {
                post(0, ch, shift: false, proxy)
                allMapped = false
            }
        }
        postEnd(proxy)

        var typedKeys = zip(buffer, enChars).map { Key(code: $0.code, shift: $0.shift, caps: $0.caps, char: $1) }
        var words = [current.word]
        if let p = previous {
            typedKeys = p.keys + [Key(code: UInt16(kVK_Space), shift: false, caps: false, char: " ")] + typedKeys
            words.insert(p.latin, at: 0)
        }
        last = Correction(typed: typedKeys, inserted: output, from: en.source, words: words, time: Date())

        // Keep backspacing into the result working (only if every character came from a real key).
        if previous != nil, let prev = history.popLast() {
            if allMapped { history.append((wordKeys[0], prev.atStart, true)) } else { history.removeAll() }
        }
        if allMapped, let lastWord = wordKeys.last { pushWord(lastWord, changed: true) } else { history.removeAll() }
        translitStreak = true
        buffer.removeAll()
        atWordStart = true
        return true
    }

    /// Optional mode: a word that is not a word in either layout, but one letter away from exactly
    /// one word (implemnet → implement, привіи → привіт). Tried on the spelling on screen first, then
    /// on the other layout's spelling (a typo typed in the wrong layout too). Only plain lowercase
    /// words of 4+ letters, only in fields whose text can be read; ambiguous cases are left alone.
    private func fixTypo(_ enChars: [String], _ ukChars: [String], _ appID: String, _ proxy: CGEventTapProxy) -> Bool {
        func skip(_ why: String) -> Bool { DebugLog.write("typo skip: \(why)"); return false }
        guard buffer.count >= 4, let en = layouts.english, let uk = layouts.ukrainian else { return false }
        let enText = enChars.joined(), ukText = ukChars.joined()
        let enPlain = Typos.isPlain(enText, "en"), ukPlain = Typos.isPlain(ukText, "uk")
        guard enPlain || ukPlain else { return skip("'\(enText)' / '\(ukText)' is not a plain lowercase word") }
        let exceptions = settings.exceptions.union(sessionIgnore)
        guard !exceptions.contains(enText), !exceptions.contains(ukText) else { return skip("in exceptions") }
        // Never touch a real word: only words that are words in neither layout.
        guard !lexicon.isWord(enText, "en"), !lexicon.isWord(ukText, "uk") else { return false }

        let field = FocusedField.check(candidates: [enText, ukText])
        guard field == .verified else { return skip("field check: \(field) in \(appID)") }
        let onScreenEnglish = FocusedField.matched == 0
        let enSide: Side = (enText, "en", en, enPlain, enChars), ukSide: Side = (ukText, "uk", uk, ukPlain, ukChars)
        let screen = onScreenEnglish ? enSide : ukSide, other = onScreenEnglish ? ukSide : enSide

        let deadline = Date().addingTimeInterval(0.04)       // never hold up typing for long
        func search(_ side: Side) -> String? {
            guard side.plain else { return nil }
            return Typos.correction(of: side.text, lang: side.lang, near: { a, b in
                guard let ka = side.layout.keyFor[String(a)], let kb = side.layout.keyFor[String(b)],
                      let pa = Typos.grid[ka.code], let pb = Typos.grid[kb.code] else { return false }
                return Typos.adjacent(pa, pb)
            }, isWord: { self.lexicon.isWord($0, side.lang) }, deadline: deadline)
        }
        var target = screen
        var fix = search(screen)
        if fix == nil, let f = search(other) { fix = f; target = other }   // wrong layout and a typo
        guard let fixed = fix else { return skip("no single word one letter away from '\(screen.text)'") }
        guard !exceptions.contains(fixed) else { return skip("'\(fixed)' is in exceptions") }
        DebugLog.write("typo: '\(screen.text)' → '\(fixed)' in \(appID)")
        return replaceWord(screen: screen, target: target, fixed: fixed, proxy)
    }

    typealias Side = (text: String, lang: String, layout: KeyLayout, plain: Bool, chars: [String])

    /// Deletes the word on screen and types `fixed` (switching layout if it's in the other language).
    private func replaceWord(screen: Side, target: Side, fixed: String, _ proxy: CGEventTapProxy) -> Bool {
        for _ in buffer { post(UInt16(kVK_Delete), nil, shift: false, proxy) }
        var newKeys: [Key] = []
        for ch in fixed.map(String.init) {
            if let k = target.layout.keyFor[ch] {
                post(k.code, ch, shift: k.shift, proxy)
                newKeys.append(Key(code: k.code, shift: k.shift, caps: false, char: ch))
            } else {
                post(0, ch, shift: false, proxy)
            }
        }
        postEnd(proxy)
        if target.lang != screen.lang { selectLayout(target.layout.source) }

        let typedKeys = zip(buffer, screen.chars).map { Key(code: $0.code, shift: $0.shift, caps: $0.caps, char: $1) }
        last = Correction(typed: typedKeys, inserted: fixed, from: screen.layout.source, words: [screen.text], time: Date())
        if newKeys.count == fixed.count {
            // A missed Space fixed (andthe → and the): two words in the history.
            let parts = newKeys.split(whereSeparator: { $0.char == " " })
            for part in parts { pushWord(Array(part), changed: true) }
        } else { history.removeAll() }
        translitStreak = false
        buffer.removeAll()
        atWordStart = true
        return true
    }

    /// Smart mode: the language model picks the most likely word for a non-word, using the word
    /// before it, word frequencies (including slang) and a keyboard-aware typing model. Tried on the
    /// spelling on screen first, then on the other layout's spelling (wrong layout and a typo).
    private func smartFix(_ enChars: [String], _ ukChars: [String], _ appID: String, _ proxy: CGEventTapProxy) -> Bool {
        func skip(_ why: String) -> Bool { DebugLog.write("smart skip: \(why)"); return false }
        guard smart.ready else { return skip("language data still loading") }
        guard buffer.count >= 3, let en = layouts.english, let uk = layouts.ukrainian else { return false }
        let enText = enChars.joined(), ukText = ukChars.joined()
        let enPlain = Typos.isPlain(enText, "en"), ukPlain = Typos.isPlain(ukText, "uk")
        guard enPlain || ukPlain else { return skip("'\(enText)' / '\(ukText)' is not a plain lowercase word") }
        let exceptions = settings.exceptions.union(sessionIgnore)
        guard !exceptions.contains(enText), !exceptions.contains(ukText) else { return skip("in exceptions") }
        let enWord = lexicon.isWord(enText, "en"), ukWord = lexicon.isWord(ukText, "uk")
        guard !(enWord && ukWord) else { return false }
        let enSide: Side = (enText, "en", en, enPlain, enChars), ukSide: Side = (ukText, "uk", uk, ukPlain, ukChars)

        // Ask the engine first: it's fast and needs no access to the text field. A dictionary word
        // only changes if it's a rare word one slip from a very common one (kike → like).
        func attempt(_ side: Side, valid: Bool) -> String? {
            guard side.plain else { return nil }
            return smart.correct(side.text, lang: side.lang, prev: earlierWord(1, in: side.layout, side.lang), next: nil, valid: valid)
        }
        let enFix = attempt(enSide, valid: enWord), ukFix = attempt(ukSide, valid: ukWord)
        guard enFix != nil || ukFix != nil else {
            return enWord || ukWord ? false : skip("no confident correction for '\(enText)' / '\(ukText)'")
        }

        let field = FocusedField.check(candidates: [enText, ukText])
        guard field == .verified else { return skip("field check: \(field) in \(appID)") }
        let onScreenEnglish = FocusedField.matched == 0
        let screen = onScreenEnglish ? enSide : ukSide, other = onScreenEnglish ? ukSide : enSide
        let screenWord = onScreenEnglish ? enWord : ukWord, otherWord = onScreenEnglish ? ukWord : enWord

        var target = screen
        var fix = onScreenEnglish ? enFix : ukFix
        if fix == nil, !screenWord, !otherWord {                  // wrong layout and a typo
            fix = onScreenEnglish ? ukFix : enFix
            target = other
        }
        guard let fixed = fix else { return skip("no confident correction for '\(screen.text)'") }
        guard !exceptions.contains(fixed) else { return skip("'\(fixed)' is in exceptions") }
        DebugLog.write("smart: '\(screen.text)' → '\(fixed)' in \(appID)")
        return replaceWord(screen: screen, target: target, fixed: fixed, proxy)
    }

    /// The word `back` places before the current one, spelled in a layout, if it's a plain word.
    private func earlierWord(_ back: Int, in layout: KeyLayout, _ lang: String) -> String? {
        guard history.count >= back else { return nil }
        let keys = history[history.count - back].keys
        let chars = keys.compactMap { layout.char(for: $0) }
        guard !keys.isEmpty, chars.count == keys.count else { return nil }
        let w = chars.joined().lowercased()
        return Typos.isPlain(w, lang) ? w : nil
    }

    /// Smart mode, on Space: the previous word, if KBSwitch left it unchanged and it's a word in neither
    /// layout, is checked again now that the word after it is known (context on both sides). The field
    /// must show exactly "previous word + this word". Returns true if it was replaced.
    private func fixPreviousWord(_ proxy: CGEventTapProxy) -> Bool {
        guard smart.ready, let en = layouts.english, let uk = layouts.ukrainian,
              let prev = history.last, !prev.changed, !prev.keys.isEmpty, !buffer.isEmpty else { return false }
        func spell(_ keys: [Key], _ l: KeyLayout) -> String? {
            let c = keys.compactMap { l.char(for: $0) }
            return c.count == keys.count ? c.joined() : nil
        }
        guard let pEn = spell(prev.keys, en), let pUk = spell(prev.keys, uk),
              let cEn = spell(buffer, en), let cUk = spell(buffer, uk) else { return false }
        let exceptions = settings.exceptions.union(sessionIgnore)
        // Cheap checks first: almost every previous word is a real word and stops here.
        guard Typos.isPlain(pEn, "en") || Typos.isPlain(pUk, "uk"),
              !lexicon.isWord(pEn, "en"), !lexicon.isWord(pUk, "uk"),
              !exceptions.contains(pEn), !exceptions.contains(pUk) else { return false }
        let combos = [(pEn, cEn), (pUk, cUk), (pEn, cUk), (pUk, cEn)]
        guard FocusedField.check(candidates: combos.map { $0.0 + " " + $0.1 }) == .verified else { return false }
        let i = FocusedField.matched
        let prevEnglish = i == 0 || i == 2
        let layout = prevEnglish ? en : uk, lang = prevEnglish ? "en" : "uk"
        let prevText = prevEnglish ? pEn : pUk
        let current = combos[i].1, currentLayout = (i == 0 || i == 3) ? en : uk
        guard Typos.isPlain(prevText, lang) else { return false }
        let meant = (prevEnglish ? cEn : cUk).lowercased()                  // this word, as meant in that language
        guard let fixed = smart.correct(prevText, lang: lang, prev: earlierWord(2, in: layout, lang),
                                        next: Typos.isPlain(meant, lang) ? meant : nil),
              !exceptions.contains(fixed) else { return false }
        DebugLog.write("smart (with the next word): '\(prevText) \(current)' → '\(fixed) \(current)'")

        for _ in 0 ..< buffer.count + 1 + prev.keys.count { post(UInt16(kVK_Delete), nil, shift: false, proxy) }
        var newKeys: [Key] = []
        for ch in fixed.map(String.init) {
            if let k = layout.keyFor[ch] {
                post(k.code, ch, shift: k.shift, proxy)
                newKeys.append(Key(code: k.code, shift: k.shift, caps: false, char: ch))
            } else {
                post(0, ch, shift: false, proxy)
            }
        }
        post(UInt16(kVK_Space), " ", shift: false, proxy)
        let currentKeys = buffer.map { Key(code: $0.code, shift: $0.shift, caps: $0.caps, char: currentLayout.char(for: $0) ?? $0.char) }
        for k in currentKeys { post(k.code, k.char, shift: k.shift, proxy) }
        buffer = currentKeys

        history.removeLast()
        if newKeys.count == fixed.count { history.append((newKeys, prev.atStart, true)) } else { history.removeAll() }
        let prevKeys = zip(prev.keys, prevText.map(String.init)).map { Key(code: $0.code, shift: $0.shift, caps: $0.caps, char: $1) }
        let space = Key(code: UInt16(kVK_Space), shift: false, caps: false, char: " ")
        last = Correction(typed: prevKeys + [space] + currentKeys, inserted: fixed + " " + current,
                          from: layout.source, words: [prevText], time: Date())
        return true
    }

    /// A word too short to convert on its own (jr? → ок?) is converted once the next word shows the
    /// language: you then typed a correct word in the other layout. The short word must be a word in
    /// that language and not one in its own, KBSwitch must have left it alone, and the field must
    /// show exactly "short word + this word".
    private func convertShortPrevious(inEnglish: Bool, current: [String], _ proxy: CGEventTapProxy) -> Bool {
        guard let en = layouts.english, let uk = layouts.ukrainian,
              let prev = history.last, !prev.changed, !prev.keys.isEmpty, prev.keys.count <= 4 else { return false }
        let here = inEnglish ? en : uk, there = inEnglish ? uk : en
        let fromChars = prev.keys.compactMap { there.char(for: $0) }
        guard fromChars.count == prev.keys.count else { return false }
        // Letters change layout; punctuation around them stays as typed (jr? → ок?, not ок,).
        let toChars = zip(prev.keys, fromChars).map { key, ch in
            ch.first.map { Decision.isLetter($0, there.lang) } == true ? (here.char(for: key) ?? ch) : ch
        }
        let from = fromChars.joined(), to = toChars.joined(), cur = current.joined()
        let exceptions = settings.exceptions.union(sessionIgnore)
        if let why = Decision.rejection(typed: from, converted: to, fromLang: there.lang, toLang: here.lang,
                                        minLength: min(2, settings.minLength), exceptions: exceptions, isWord: lexicon.isWord) {
            DebugLog.write("short previous '\(from)': \(why)")
            return false
        }
        guard FocusedField.check(candidates: [from + " " + cur]) == .verified else {
            DebugLog.write("short previous '\(from)': field doesn't show '\(from) \(cur)'")
            return false
        }
        DebugLog.write("short previous: '\(from) \(cur)' → '\(to) \(cur)'")

        for _ in 0 ..< current.count + 1 + fromChars.count { post(UInt16(kVK_Delete), nil, shift: false, proxy) }
        let newPrev = zip(prev.keys, toChars).map { Key(code: $0.code, shift: $0.shift, caps: $0.caps, char: $1) }
        let curKeys = zip(buffer, current).map { Key(code: $0.code, shift: $0.shift, caps: $0.caps, char: $1) }
        let space = Key(code: UInt16(kVK_Space), shift: false, caps: false, char: " ")
        for k in newPrev + [space] + curKeys { post(k.code, k.char, shift: k.shift, proxy) }
        postEnd(proxy)

        let oldPrev = zip(prev.keys, fromChars).map { Key(code: $0.code, shift: $0.shift, caps: $0.caps, char: $1) }
        last = Correction(typed: oldPrev + [space] + curKeys, inserted: to + " " + cur,
                          from: here.source, words: [from], time: Date())
        history.removeLast()
        history.append((newPrev, prev.atStart, true))
        buffer = curKeys
        pushWord(curKeys)
        buffer.removeAll()
        atWordStart = true
        return true
    }

    /// Reverts the last correction. Returns false (and lets the key through) if the text no longer matches.
    private func undo(_ c: Correction, _ proxy: CGEventTapProxy, learn: Bool) -> Bool {
        switch FocusedField.check(expect: c.inserted + " ") {
        case .mismatch, .secure, .notText: return false
        default: break
        }
        for _ in 0 ..< c.inserted.count + 1 { post(UInt16(kVK_Delete), nil, shift: false, proxy) }
        for key in c.typed { post(key.code, key.char, shift: key.shift, proxy) }
        post(UInt16(kVK_Space), " ", shift: false, proxy)
        selectLayout(c.from)

        if c.typed.contains(where: { $0.code == UInt16(kVK_Space) }) {
            history.removeAll()                                    // two words came back: start fresh
        } else if let top = history.popLast() {
            history.append((c.typed, top.atStart, true))           // the original is back (user's choice)
        }
        smart.learn(c.words.map { $0.lowercased() })
        for w in c.words {
            sessionIgnore.insert(w.lowercased())
            // Backspace is also plain editing, so only an Esc undo is remembered for good.
            if learn && settings.learnOnUndo { addException(w) }
        }
        translitStreak = false
        buffer.removeAll()
        atWordStart = true
        return true
    }

    /// "word&" + Space/Return → "word?": & is Shift+7 in English, where Ukrainian has ?. Only an &
    /// stuck to the end of a word; "you & me" and "&&" stay.
    private func questionMark(_ proxy: CGEventTapProxy) -> Bool {
        guard settings.enabled, buffer.count >= 2, let en = layouts.english,
              en.char(for: buffer[buffer.count - 1]) == "&",
              let before = en.char(for: buffer[buffer.count - 2])?.first, before.isLetter else { return false }
        let chars = buffer.compactMap { en.char(for: $0) }
        guard chars.count == buffer.count, FocusedField.check(candidates: [chars.joined()]) == .verified else {
            DebugLog.write("? skip: field doesn't show '\(chars.joined())'")
            return false
        }
        DebugLog.write("'\(chars.joined())' → '\(chars.dropLast().joined())?'")
        post(UInt16(kVK_Delete), nil, shift: false, proxy)
        post(buffer[buffer.count - 1].code, "?", shift: true, proxy)
        postEnd(proxy)
        let typed = zip(buffer, chars).map { Key(code: $0.code, shift: $0.shift, caps: $0.caps, char: $1) }
        last = Correction(typed: typed, inserted: chars.dropLast().joined() + "?", from: en.source, words: [], time: Date())
        buffer = Array(typed.dropLast()) + [Key(code: typed[typed.count - 1].code, shift: true, caps: false, char: "?")]
        return true
    }

    /// After Backspace, arrows or clicks the keys we saw may not be the word on screen (typos fixed
    /// by hand, a word whose start we missed). Read the word before the caret and rebuild its keys:
    /// each character from the layout that has it, preferring the layout most of its letters are in.
    private func rereadWord() {
        wordEdited = false
        guard let en = layouts.english, let uk = layouts.ukrainian,
              let word = FocusedField.wordBeforeCaret(), !word.isEmpty, word.count <= settings.maxLength else {
            DebugLog.write("re-read: field unreadable, keeping \(spell(buffer))")
            return
        }
        let chars = word.map(String.init)
        let inUk = chars.filter { $0.first.map { Decision.isLetter($0, "uk") } == true }.count
        let inEn = chars.filter { $0.first.map { Decision.isLetter($0, "en") } == true }.count
        let order = inUk > inEn ? [uk, en] : [en, uk]
        var keys: [Key] = []
        for ch in chars {
            guard let k = order[0].keyFor[ch] ?? order[1].keyFor[ch] else {
                DebugLog.write("re-read: '\(ch)' in '\(word)' has no key, keeping \(spell(buffer))")
                return
            }
            keys.append(Key(code: k.code, shift: k.shift, caps: false, char: ch))
        }
        if keys.map({ $0.char }) != buffer.map({ $0.char }) || !atWordStart {
            DebugLog.write("re-read: \(spell(buffer)) → '\(word)' from the field")
        }
        buffer = keys
        atWordStart = true
    }

    /// Types the key that ended the word (see `endKey`).
    private func postEnd(_ proxy: CGEventTapProxy) {
        post(endKey.code, endKey.code == UInt16(kVK_Space) ? " " : nil, shift: endKey.shift, proxy)
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
            add("Diagnostic Log", #selector(toggleLog), tag: 5)
            add("Show Log", #selector(showLog), tag: 6)
            menu.addItem(NSMenuItem.separator())
            add("Quit KBSwitch", #selector(quit))
            item.menu = menu
            statusItem = item
        }
        let trusted = AXIsProcessTrusted()
        statusItem?.button?.appearsDisabled = !active || !trusted
        statusItem?.menu?.item(withTag: 3)?.isHidden = trusted
        statusItem?.menu?.item(withTag: 5)?.state = settings.debugLog ? .on : .off
        statusItem?.menu?.item(withTag: 6)?.isHidden = !settings.debugLog
        let secureInput: Bool = IsSecureEventInputEnabled() == true   // compiles whether Bool or DarwinBoolean
        statusItem?.menu?.item(withTag: 4)?.isHidden = !secureInput
        statusItem?.menu?.item(withTag: 1)?.state = active ? .on : .off
    }

    @objc private func toggleEnabled() {
        var c = Config.load()
        c.enabled.toggle()
        c.save()
        reset("toggled Enabled")
        reloadIfChanged(force: true)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func toggleLog() {
        var c = Config.load()
        c.debugLog.toggle()
        c.save()
        reloadIfChanged(force: true)
    }

    @objc private func showLog() { NSWorkspace.shared.open(DebugLog.url) }

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
                Toggle("Never convert words undone with Esc", isOn: $model.config.learnOnUndo)
                Toggle("Ukrainian typed in Latin → Cyrillic (privit → привіт)", isOn: $model.config.transliteration)
                Picker("Fix typos", selection: $model.config.typoFixing) {
                    Text("Off").tag("off")
                    Text("Careful: one slip (implemnet)").tag("careful")
                    Text("Smart: context, slang, badly mangled words").tag("smart")
                }
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
if let i = CommandLine.arguments.firstIndex(of: "--spell") {      // kbswitch --spell word…
    let lexicon = Lexicon()
    for w in CommandLine.arguments.dropFirst(i + 1) {
        print("\(w): en=\(lexicon.isWord(w, "en")) uk=\(lexicon.isWord(w, "uk"))")
    }
    exit(0)
}
if CommandLine.arguments.contains("--check") {
    engine.report()
    exit(0)
}
let me = ProcessInfo.processInfo.processIdentifier
if let other = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
    .first(where: { $0.processIdentifier != me }) {
    other.activate(options: [])     // only one KBSwitch may watch the keyboard
    exit(0)
}
engine.start()
app.run()
