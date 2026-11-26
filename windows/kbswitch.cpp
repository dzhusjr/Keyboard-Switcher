// KBSwitch for Windows: fixes words typed in the wrong keyboard layout (English <-> Ukrainian).
//
// How it works:
//   A low-level keyboard hook records the physical keys of the word being typed. On Space, the same
//   keys are spelled in both layouts (ToUnicodeEx with the installed English and Ukrainian layouts)
//   and checked with Hunspell. If one spelling is not a word and the other is, the text before the
//   caret is read through UI Automation on a worker thread (the hook must never block: Windows
//   silently removes slow hooks). Meanwhile the Space and any further keys are held back. If the
//   field shows exactly the wrong-layout word, it is deleted and the right word is typed, followed by
//   the held-back keys, in one SendInput call, so nothing can be reordered. No polling, no network:
//   idle cost is zero.
//
// Build: see windows/README section in the repository README (GitHub Actions builds releases).

#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#define NOMINMAX
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00      // Windows 10
#endif

#include <windows.h>
#include <shellapi.h>
#include <shlobj.h>
#include <commctrl.h>
#include <ole2.h>
#include <uiautomation.h>

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <vector>

#include "hunspell.h"
#include "resource.h"

using std::wstring;
using std::vector;

// ============================================================================================
// Constants and small helpers
// ============================================================================================

static const ULONG_PTR kOwnInput = 0x4B425357;   // our synthetic keys: the hook ignores them
static const ULONG_PTR kReplay   = 0x4B425352;   // keys held back during a check: handled as typing
static const UINT WM_APP_TRAY     = WM_APP + 1;
static const UINT WM_APP_FIELD    = WM_APP + 2;
static const UINT WM_APP_SETTINGS = WM_APP + 3;
static const UINT WM_APP_QUIT     = WM_APP + 4;
static const UINT_PTR kTimerCheck = 1;
static const wchar_t* kWindowClass = L"KBSwitchMessageWindow";
static const wchar_t* kSettingsClass = L"KBSwitchSettingsWindow";

static std::string utf8(const wstring& w) {
    if (w.empty()) return {};
    int n = WideCharToMultiByte(CP_UTF8, 0, w.data(), (int)w.size(), nullptr, 0, nullptr, nullptr);
    std::string s(n, '\0');
    WideCharToMultiByte(CP_UTF8, 0, w.data(), (int)w.size(), s.data(), n, nullptr, nullptr);
    return s;
}

static wstring wide(const std::string& s) {
    if (s.empty()) return {};
    int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), nullptr, 0);
    wstring w(n, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), w.data(), n);
    return w;
}

static wstring lower(wstring s) { if (!s.empty()) CharLowerBuffW(s.data(), (DWORD)s.size()); return s; }
static wstring upper(wstring s) { if (!s.empty()) CharUpperBuffW(s.data(), (DWORD)s.size()); return s; }

static wstring trim(const wstring& s) {
    size_t a = s.find_first_not_of(L" \t\r\n"), b = s.find_last_not_of(L" \t\r\n");
    return a == wstring::npos ? wstring() : s.substr(a, b - a + 1);
}

static bool isAlpha(wchar_t c) { return IsCharAlphaW(c) != 0; }
static bool isSpace(wchar_t c) { return c == L' ' || c == L'\t' || c == L'\r' || c == L'\n' || c == 0xA0 || c == 0x2009 || c == 0x202F; }
static bool isEdgePunct(wchar_t c) { return !isAlpha(c) && !(c >= L'0' && c <= L'9') && !isSpace(c); }

static bool endsWith(const wstring& s, const wstring& end) {
    return s.size() >= end.size() && s.compare(s.size() - end.size(), end.size(), end) == 0;
}

static wstring joinWords(const vector<wstring>& words) {
    wstring r;
    for (size_t i = 0; i < words.size(); i++) { if (i) r += L' '; r += words[i]; }
    return r;
}

static wstring knownFolder(const wchar_t* env, const wchar_t* sub) {
    wchar_t buf[MAX_PATH * 2];
    DWORD n = GetEnvironmentVariableW(env, buf, MAX_PATH * 2);
    wstring dir = (n > 0 && n < MAX_PATH * 2) ? wstring(buf, n) : wstring(L".");
    dir += L"\\";
    dir += sub;
    CreateDirectoryW(dir.c_str(), nullptr);
    return dir;
}

static wstring exeDir() {
    wchar_t buf[MAX_PATH * 2];
    DWORD n = GetModuleFileNameW(nullptr, buf, MAX_PATH * 2);
    wstring p(buf, n);
    return p.substr(0, p.find_last_of(L"\\/"));
}

static wstring readFile(const wstring& path) {
    HANDLE f = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING, 0, nullptr);
    if (f == INVALID_HANDLE_VALUE) return {};
    std::string data;
    char buf[8192];
    DWORD got = 0;
    while (ReadFile(f, buf, sizeof buf, &got, nullptr) && got > 0) data.append(buf, got);
    CloseHandle(f);
    if (data.size() >= 3 && (unsigned char)data[0] == 0xEF && (unsigned char)data[1] == 0xBB && (unsigned char)data[2] == 0xBF) data.erase(0, 3);
    return wide(data);
}

static void writeFile(const wstring& path, const wstring& text) {
    std::string data = utf8(text);
    wstring tmp = path + L".tmp";
    HANDLE f = CreateFileW(tmp.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, 0, nullptr);
    if (f == INVALID_HANDLE_VALUE) return;
    DWORD put = 0;
    WriteFile(f, data.data(), (DWORD)data.size(), &put, nullptr);
    CloseHandle(f);
    MoveFileExW(tmp.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING);
}

/// Non-empty lines with `#` comments removed.
static vector<wstring> fileLines(const wstring& path) {
    vector<wstring> out;
    wstring text = readFile(path), line;
    for (size_t i = 0; i <= text.size(); i++) {
        if (i == text.size() || text[i] == L'\n') {
            size_t hash = line.find(L'#');
            if (hash != wstring::npos) line.erase(hash);
            line = trim(line);
            if (!line.empty()) out.push_back(line);
            line.clear();
        } else line += text[i];
    }
    return out;
}

// ============================================================================================
// Settings  (%APPDATA%\KBSwitch\settings.txt and exceptions.txt, same format as the macOS app)
// ============================================================================================

struct Paths {
    wstring dir = knownFolder(L"APPDATA", L"KBSwitch");
    wstring settings = dir + L"\\settings.txt";
    wstring exceptions = dir + L"\\exceptions.txt";
    wstring log = knownFolder(L"LOCALAPPDATA", L"KBSwitch") + L"\\KBSwitch.log";
};
static Paths* g_paths;

struct Config {
    bool enabled = true;
    int minLength = 3;
    int maxLength = 30;
    wstring undoKey = L"escape";               // escape | backspace | none
    bool learnOnUndo = true;
    bool transliteration = false;
    bool autocorrect = false;
    bool debugLog = false;
    std::set<wstring> excludedApps = {L"cmd.exe", L"powershell.exe", L"pwsh.exe", L"windowsterminal.exe", L"conhost.exe"};
    std::set<wstring> exceptions;              // lowercase

    static bool flag(const wstring& v) { wstring l = lower(v); return l == L"true" || l == L"yes" || l == L"on" || l == L"1"; }

    static Config load(bool* firstRun = nullptr) {
        Config c;
        bool exists = GetFileAttributesW(g_paths->settings.c_str()) != INVALID_FILE_ATTRIBUTES;
        if (firstRun) *firstRun = !exists;
        if (!exists) c.save();
        if (GetFileAttributesW(g_paths->exceptions.c_str()) == INVALID_FILE_ATTRIBUTES)
            writeFile(g_paths->exceptions, L"# Words that are never converted: one per line, in either layout.\r\n");
        for (const wstring& line : fileLines(g_paths->settings)) {
            size_t eq = line.find(L'=');
            if (eq == wstring::npos) continue;
            wstring key = lower(trim(line.substr(0, eq))), v = trim(line.substr(eq + 1));
            if (key == L"enabled") c.enabled = flag(v);
            else if (key == L"min_length") c.minLength = std::max(1, _wtoi(v.c_str()) ? _wtoi(v.c_str()) : c.minLength);
            else if (key == L"max_length") c.maxLength = std::max(1, _wtoi(v.c_str()) ? _wtoi(v.c_str()) : c.maxLength);
            else if (key == L"undo_key") { wstring l = lower(v); c.undoKey = (l == L"none" || l == L"backspace") ? l : L"escape"; }
            else if (key == L"learn_on_undo") c.learnOnUndo = flag(v);
            else if (key == L"transliteration") c.transliteration = flag(v);
            else if (key == L"autocorrect") c.autocorrect = flag(v);
            else if (key == L"debug_log") c.debugLog = flag(v);
            else if (key == L"excluded_apps") {
                c.excludedApps.clear();
                size_t start = 0;
                while (start <= v.size()) {
                    size_t comma = v.find(L',', start);
                    wstring item = lower(trim(v.substr(start, comma == wstring::npos ? wstring::npos : comma - start)));
                    if (!item.empty()) c.excludedApps.insert(item);
                    if (comma == wstring::npos) break;
                    start = comma + 1;
                }
            }
        }
        c.maxLength = std::max(c.maxLength, c.minLength);
        for (const wstring& w : fileLines(g_paths->exceptions)) c.exceptions.insert(lower(w));
        return c;
    }

    void save() const {
        wstring apps;
        for (const wstring& a : excludedApps) { if (!apps.empty()) apps += L", "; apps += a; }
        wstring t = L"# KBSwitch settings. Change them in the app: tray icon -> Settings...\r\n";
        t += L"enabled = " + wstring(enabled ? L"true" : L"false") + L"\r\n";
        t += L"min_length = " + std::to_wstring(minLength) + L"\r\n";
        t += L"max_length = " + std::to_wstring(std::max(maxLength, minLength)) + L"\r\n";
        t += L"undo_key = " + undoKey + L"\r\n";
        t += L"learn_on_undo = " + wstring(learnOnUndo ? L"true" : L"false") + L"\r\n";
        t += L"transliteration = " + wstring(transliteration ? L"true" : L"false") + L"\r\n";
        t += L"autocorrect = " + wstring(autocorrect ? L"true" : L"false") + L"\r\n";
        t += L"debug_log = " + wstring(debugLog ? L"true" : L"false") + L"\r\n";
        t += L"excluded_apps = " + apps + L"\r\n";
        writeFile(g_paths->settings, t);
    }
};

// ============================================================================================
// Diagnostic log (%LOCALAPPDATA%\KBSwitch\KBSwitch.log), only when enabled in Settings
// ============================================================================================

static bool g_logOn = false;

static void logLine(const wstring& message) {
    if (!g_logOn) return;
    SYSTEMTIME t;
    GetLocalTime(&t);
    wchar_t stamp[64];
    swprintf(stamp, 64, L"%04d-%02d-%02d %02d:%02d:%02d.%03d ", t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond, t.wMilliseconds);
    std::string line = utf8(stamp + message + L"\r\n");
    HANDLE f = CreateFileW(g_paths->log.c_str(), FILE_APPEND_DATA, FILE_SHARE_READ, nullptr, OPEN_ALWAYS, 0, nullptr);
    if (f == INVALID_HANDLE_VALUE) return;
    DWORD put = 0;
    WriteFile(f, line.data(), (DWORD)line.size(), &put, nullptr);
    CloseHandle(f);
}

// ============================================================================================
// Keyboard layouts
// ============================================================================================

/// One physical key press that produced one printable character.
struct Key {
    WORD vk = 0;
    WORD scan = 0;
    bool shift = false;
    bool caps = false;
};

struct Layouts {
    HKL en = nullptr, uk = nullptr;

    void reload() {
        en = uk = nullptr;
        HKL list[64];
        int n = GetKeyboardLayoutList(64, list);
        for (int i = 0; i < n; i++) {
            WORD lang = PRIMARYLANGID(LOWORD((UINT_PTR)list[i]));
            if (lang == LANG_ENGLISH && !en) en = list[i];
            if (lang == LANG_UKRAINIAN && !uk) uk = list[i];
        }
    }

    /// The single character the key types in a layout, or "" (dead key, control, several chars).
    static wstring charFor(const Key& k, HKL hkl) {
        if (!hkl) return {};
        BYTE state[256] = {0};
        if (k.shift) state[VK_SHIFT] = 0x80;
        if (k.caps) state[VK_CAPITAL] = 0x01;
        wchar_t buf[8] = {0};
        int n = ToUnicodeEx(k.vk, k.scan, state, buf, 8, 0x4 /* don't change keyboard state */, hkl);
        if (n != 1 || buf[0] < 0x20 || buf[0] == 0x7F) return {};
        return wstring(1, buf[0]);
    }

    /// Spells keys in a layout; false if any key has no single character there.
    static bool spell(const vector<Key>& keys, HKL hkl, wstring& out) {
        out.clear();
        for (const Key& k : keys) {
            wstring c = charFor(k, hkl);
            if (c.empty()) return false;
            out += c;
        }
        return true;
    }
};
static Layouts g_layouts;

// ============================================================================================
// Dictionaries: Hunspell with the LibreOffice en_US and uk_UA dictionaries (dict\ next to the exe)
// ============================================================================================

struct Speller {
    Hunhandle* h = nullptr;

    void load(const wstring& base) {
        wstring aff = base + L".aff", dic = base + L".dic";
        if (GetFileAttributesW(dic.c_str()) == INVALID_FILE_ATTRIBUTES) return;
#ifdef _MSC_VER
        // Hunspell opens "\\?\"-prefixed UTF-8 paths with the wide API (works for any user name).
        h = Hunspell_create(utf8(L"\\\\?\\" + aff).c_str(), utf8(L"\\\\?\\" + dic).c_str());
#else
        wchar_t shortAff[MAX_PATH], shortDic[MAX_PATH];
        GetShortPathNameW(aff.c_str(), shortAff, MAX_PATH);
        GetShortPathNameW(dic.c_str(), shortDic, MAX_PATH);
        std::string a, d;
        for (wchar_t* p = shortAff; *p; p++) a += (char)*p;
        for (wchar_t* p = shortDic; *p; p++) d += (char)*p;
        h = Hunspell_create(a.c_str(), d.c_str());
#endif
    }
    bool ok() const { return h != nullptr; }
    bool spell(const wstring& w) const { return h && Hunspell_spell(h, utf8(w).c_str()) != 0; }
};

struct Lexicon {
    Speller en, uk;

    void load() {
        wstring dir = exeDir() + L"\\dict\\";
        en.load(dir + L"en_US");
        uk.load(dir + L"uk_UA");
    }

    bool supports(const wstring& lang) const { return lang == L"uk" ? uk.ok() : en.ok(); }

    static bool letterOf(wchar_t c, const wstring& lang) {
        if (lang == L"uk") return c >= 0x0400 && c <= 0x04FF && isAlpha(c);
        return (c >= L'A' && c <= L'Z') || (c >= L'a' && c <= L'z');
    }

    /// Only words in the dictionary's own alphabet are judged.
    bool isWord(const wstring& w, const wstring& lang) const {
        if (w.empty()) return false;
        for (wchar_t c : w)
            if (!letterOf(c, lang) && c != L'\'' && c != 0x2019 && c != 0x02BC && c != L'-') return false;
        const Speller& s = lang == L"uk" ? uk : en;
        wstring normalized = w;
        std::replace(normalized.begin(), normalized.end(), (wchar_t)0x2019, L'\'');
        if (s.spell(normalized)) return true;
        wstring l = lower(normalized);
        return l != normalized && s.spell(l);
    }
};
static Lexicon g_lexicon;

// ============================================================================================
// Decision (pure logic, same rules as the macOS app)
// ============================================================================================

namespace Decision {

static bool innerMark(wchar_t c) { return c == L'\'' || c == 0x2019 || c == 0x02BC || c == L'-'; }

static wstring core(const wstring& s) {
    size_t a = 0, b = s.size();
    while (a < b && isEdgePunct(s[a])) a++;
    while (b > a && isEdgePunct(s[b - 1])) b--;
    return s.substr(a, b - a);
}

static bool naturalCase(const wstring& w) {
    wstring letters;
    for (wchar_t c : w) if (isAlpha(c)) letters += c;
    if (letters.empty()) return false;
    wstring cap = upper(letters.substr(0, 1)) + lower(letters.substr(1));
    return letters == lower(letters) || letters == upper(letters) || letters == cap;
}

/// Letters of one alphabet (inner apostrophe/hyphen allowed) in natural casing: word, Word, WORD.
static bool isCleanWord(const wstring& w, const wstring& lang) {
    if (w.empty() || !Lexicon::letterOf(w.front(), lang) || !Lexicon::letterOf(w.back(), lang)) return false;
    for (wchar_t c : w) if (!Lexicon::letterOf(c, lang) && !innerMark(c)) return false;
    return naturalCase(w);
}

/// nullopt = convert; otherwise the reason not to.
static std::optional<wstring> rejection(const wstring& typed, const wstring& converted,
                                        const wstring& fromLang, const wstring& toLang,
                                        int minLength, const std::set<wstring>& exceptions) {
    if (typed == converted) return L"same text in both layouts";
    for (wchar_t c : typed) if (c >= L'0' && c <= L'9') return L"contains digits";
    wstring src = core(typed), dst = core(converted);
    if (src.empty()) return L"only punctuation";
    if ((int)dst.size() < minLength) return L"result '" + dst + L"' shorter than " + std::to_wstring(minLength);
    if (!isCleanWord(dst, toLang)) return L"result '" + dst + L"' is not a clean " + toLang + L" word";
    for (const wstring& w : {typed, src, dst})
        if (exceptions.count(lower(w))) return L"'" + w + L"' is in exceptions";
    if (g_lexicon.isWord(src, fromLang)) return L"'" + src + L"' is a real " + fromLang + L" word";
    if (!g_lexicon.isWord(dst, toLang)) return L"'" + dst + L"' is not a " + toLang + L" word";
    return std::nullopt;
}

}  // namespace Decision

// ============================================================================================
// Transliteration (optional): privit -> привіт
// ============================================================================================

namespace Translit {

struct Rule { const wchar_t* latin; vector<const wchar_t*> cyr; };

static const vector<Rule>& table() {
    static const vector<Rule> t = {
        {L"shch", {L"щ"}}, {L"sch", {L"щ"}},
        {L"zh", {L"ж"}}, {L"kh", {L"х"}}, {L"ch", {L"ч"}}, {L"sh", {L"ш", L"сх"}}, {L"ts", {L"ц", L"ць", L"тс"}}, {L"tz", {L"ц"}},
        {L"ya", {L"я"}}, {L"ja", {L"я"}}, {L"ia", {L"я", L"іа"}},
        {L"yu", {L"ю"}}, {L"ju", {L"ю"}}, {L"iu", {L"ю", L"іу"}},
        {L"ye", {L"є"}}, {L"je", {L"є"}}, {L"ie", {L"є", L"іе"}},
        {L"yi", {L"ї"}}, {L"ji", {L"ї"}}, {L"yo", {L"йо"}}, {L"jo", {L"йо"}},
        {L"a", {L"а"}}, {L"b", {L"б"}}, {L"c", {L"ц", L"к"}}, {L"d", {L"д", L"дь"}}, {L"e", {L"е", L"є"}}, {L"f", {L"ф"}},
        {L"g", {L"г", L"ґ"}}, {L"h", {L"г", L"х"}}, {L"i", {L"і", L"и", L"ї", L"й"}}, {L"j", {L"й"}}, {L"k", {L"к"}},
        {L"l", {L"л", L"ль"}}, {L"m", {L"м"}}, {L"n", {L"н", L"нь"}}, {L"o", {L"о"}}, {L"p", {L"п"}}, {L"q", {L"к"}},
        {L"r", {L"р"}}, {L"s", {L"с", L"сь"}}, {L"t", {L"т", L"ть"}}, {L"u", {L"у"}}, {L"v", {L"в"}}, {L"w", {L"в"}},
        {L"x", {L"кс", L"х"}}, {L"y", {L"и", L"й"}}, {L"z", {L"з", L"зь"}}, {L"'", {L"ь", L"ʼ"}}, {L"`", {L"ь"}},
    };
    return t;
}

/// First reading of a lowercase Latin word that is a Ukrainian word (at most 300 tries).
static std::optional<wstring> convert(const wstring& latin) {
    int tries = 0;
    std::optional<wstring> found;
    std::function<void(size_t, const wstring&)> walk = [&](size_t i, const wstring& acc) {
        if (found || tries >= 300) return;
        if (i == latin.size()) {
            tries++;
            if (g_lexicon.isWord(acc, L"uk")) found = acc;
            return;
        }
        for (const Rule& r : table()) {
            size_t len = wcslen(r.latin);
            if (latin.compare(i, len, r.latin) != 0) continue;
            for (const wchar_t* o : r.cyr) { walk(i + len, acc + o); if (found) return; }
        }
    };
    walk(0, L"");
    return found;
}

}  // namespace Translit

// ============================================================================================
// Typos (optional): one letter off. Same rules as the macOS app.
// ============================================================================================

namespace Typos {

static const wchar_t* alphabet(const wstring& lang) {
    return lang == L"uk" ? L"абвгґдеєжзиіїйклмнопрстуфхцчшщьюя'" : L"abcdefghijklmnopqrstuvwxyz";
}

static bool isPlain(const wstring& w, const wstring& lang) {
    if (w.empty() || w != lower(w) || w.front() == L'\'' || w.back() == L'\'') return false;
    for (wchar_t c : w) if (!wcschr(alphabet(lang), c)) return false;
    return true;
}

/// Row/column of the key that types `c` in a layout (letter rows), or false.
static bool position(wchar_t c, HKL hkl, int& row, int& col) {
    SHORT r = VkKeyScanExW(c, hkl);
    if (r == -1) return false;
    UINT scan = MapVirtualKeyExW(LOBYTE(r), MAPVK_VK_TO_VSC, hkl);
    if (scan >= 0x10 && scan <= 0x1B) { row = 0; col = (int)scan - 0x10; return true; }
    if (scan >= 0x1E && scan <= 0x28) { row = 1; col = (int)scan - 0x1E; return true; }
    if (scan >= 0x2C && scan <= 0x35) { row = 2; col = (int)scan - 0x2C; return true; }
    return false;
}

/// Keys that touch on a staggered keyboard: left/right, two above, two below.
static bool touching(wchar_t a, wchar_t b, HKL hkl) {
    int ra, ca, rb, cb;
    if (!position(a, hkl, ra, ca) || !position(b, hkl, rb, cb)) return false;
    switch (rb - ra) {
        case 0: return std::abs(cb - ca) == 1;
        case -1: return cb == ca || cb == ca + 1;
        case 1: return cb == ca || cb == ca - 1;
        default: return false;
    }
}

/// The one word `word` becomes by undoing a single common slip (two neighbouring letters swapped,
/// a key next to the intended one inside a 5+ letter word, a doubled letter, a double typed once),
/// or nullopt if there is none, more than one, or the time budget runs out.
static std::optional<wstring> correction(const wstring& word, const wstring& lang, HKL hkl, ULONGLONG deadline) {
    size_t n = word.size();
    for (size_t i = 2; i < n; i++)                    // stretched words (hmmm, sooo) are on purpose
        if (word[i] == word[i - 1] && word[i] == word[i - 2]) return std::nullopt;
    std::set<wstring> found, checked;
    bool stop = false;
    auto consider = [&](const wstring& c) {
        if (stop || c == word || !checked.insert(c).second) return;
        if (GetTickCount64() > deadline) { stop = true; found.clear(); return; }
        if (g_lexicon.isWord(c, lang)) found.insert(c);
        if (found.size() > 1) stop = true;            // ambiguous
    };
    for (size_t i = 0; i + 1 < n; i++)
        if (word[i] != word[i + 1]) { wstring c = word; std::swap(c[i], c[i + 1]); consider(c); }
    if (n >= 5)
        for (size_t i = 1; i + 1 < n; i++)
            for (const wchar_t* p = alphabet(lang); *p; p++)
                if (*p != word[i] && touching(word[i], *p, hkl)) { wstring c = word; c[i] = *p; consider(c); }
    for (size_t i = 1; i < n; i++)
        if (word[i] == word[i - 1]) { wstring c = word; c.erase(i, 1); consider(c); }
    for (size_t i = 0; i < n; i++) { wstring c = word; c.insert(i, 1, word[i]); consider(c); }
    if (stop || found.size() != 1) return std::nullopt;
    return *found.begin();
}

}  // namespace Typos

// ============================================================================================
// Text field reader: UI Automation on its own thread (the hook thread must never block)
// ============================================================================================

enum class FieldState { Readable, NoText, Secure, Unreadable, NoFocus };

struct FieldRead {
    int job = 0;
    FieldState state = FieldState::NoFocus;
    wstring before;            // text right before the caret (up to kBack characters)
    bool atStart = false;      // `before` begins at the start of the text
    bool selection = false;    // something is selected (typing would replace it)
    wstring detail;
};

struct FieldRequest { int job = 0; vector<wstring> endings; };

class FieldReader {
public:
    void start(HWND notify) {
        notify_ = notify;
        InitializeCriticalSection(&lock_);
        wake_ = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        CreateThread(nullptr, 0, &FieldReader::threadMain, this, 0, nullptr);
    }

    void request(const FieldRequest& r) {
        EnterCriticalSection(&lock_);
        pending_ = r;
        hasPending_ = true;
        LeaveCriticalSection(&lock_);
        SetEvent(wake_);
    }

private:
    static const int kBack = 300;
    HWND notify_ = nullptr;
    CRITICAL_SECTION lock_;
    HANDLE wake_ = nullptr;
    FieldRequest pending_;
    bool hasPending_ = false;
    IUIAutomation* uia_ = nullptr;

    static DWORD WINAPI threadMain(LPVOID self) { static_cast<FieldReader*>(self)->run(); return 0; }

    void run() {
        CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        if (FAILED(CoCreateInstance(__uuidof(CUIAutomation8), nullptr, CLSCTX_INPROC_SERVER, __uuidof(IUIAutomation), (void**)&uia_)))
            CoCreateInstance(__uuidof(CUIAutomation), nullptr, CLSCTX_INPROC_SERVER, __uuidof(IUIAutomation), (void**)&uia_);
        IUIAutomation2* uia2 = nullptr;
        if (uia_ && SUCCEEDED(uia_->QueryInterface(__uuidof(IUIAutomation2), (void**)&uia2))) {
            uia2->put_ConnectionTimeout(300);
            uia2->put_TransactionTimeout(300);
            uia2->Release();
        }
        for (;;) {
            WaitForSingleObject(wake_, INFINITE);
            EnterCriticalSection(&lock_);
            bool has = hasPending_;
            FieldRequest r = pending_;
            hasPending_ = false;
            LeaveCriticalSection(&lock_);
            if (!has) continue;
            FieldRead* result = new FieldRead(readWithRetries(r));
            result->job = r.job;
            PostMessageW(notify_, WM_APP_FIELD, 0, (LPARAM)result);
        }
    }

    // Apps draw keystrokes asynchronously: when typing fast the last letters may not be in the
    // field yet, so re-read a few times before reporting text that doesn't match.
    FieldRead readWithRetries(const FieldRequest& r) {
        FieldRead f;
        for (int attempt = 0; attempt < 4; attempt++) {
            if (attempt) Sleep(15);
            f = readOnce();
            if (f.state != FieldState::Readable || f.selection || r.endings.empty()) return f;
            for (const wstring& e : r.endings) if (!e.empty() && endsWith(f.before, e)) return f;
        }
        return f;
    }

    FieldRead readOnce() {
        FieldRead f;
        if (!uia_) { f.detail = L"UI Automation unavailable"; return f; }
        IUIAutomationElement* el = nullptr;
        if (FAILED(uia_->GetFocusedElement(&el)) || !el) { f.detail = L"no focused element"; return f; }

        BOOL password = FALSE;
        el->get_CurrentIsPassword(&password);
        CONTROLTYPEID type = 0;
        el->get_CurrentControlType(&type);
        f.detail = L"control=" + std::to_wstring(type);
        if (password) { el->Release(); f.state = FieldState::Secure; return f; }

        IUIAutomationTextPattern* tp = nullptr;
        el->GetCurrentPatternAs(UIA_TextPatternId, __uuidof(IUIAutomationTextPattern), (void**)&tp);
        bool textish = type == UIA_EditControlTypeId || type == UIA_DocumentControlTypeId || type == UIA_ComboBoxControlTypeId;
        if (!tp) {
            el->Release();
            f.state = textish ? FieldState::Unreadable : FieldState::NoText;
            f.detail += L" no TextPattern";
            return f;
        }
        f.state = FieldState::Unreadable;
        IUIAutomationTextRangeArray* sel = nullptr;
        int count = 0;
        if (SUCCEEDED(tp->GetSelection(&sel)) && sel && SUCCEEDED(sel->get_Length(&count)) && count > 0) {
            IUIAutomationTextRange* caret = nullptr;
            if (SUCCEEDED(sel->GetElement(0, &caret)) && caret) {
                int cmp = 0;
                caret->CompareEndpoints(TextPatternRangeEndpoint_Start, caret, TextPatternRangeEndpoint_End, &cmp);
                f.selection = cmp != 0;
                IUIAutomationTextRange* back = nullptr;
                if (SUCCEEDED(caret->Clone(&back)) && back) {
                    int moved = 0;
                    // Collapse to the caret, then extend backwards.
                    back->MoveEndpointByRange(TextPatternRangeEndpoint_End, caret, TextPatternRangeEndpoint_Start);
                    back->MoveEndpointByUnit(TextPatternRangeEndpoint_Start, TextUnit_Character, -kBack, &moved);
                    BSTR text = nullptr;
                    if (SUCCEEDED(back->GetText(kBack + 16, &text))) {
                        f.before = text ? wstring(text, SysStringLen(text)) : wstring();
                        f.atStart = -moved < kBack;
                        f.state = FieldState::Readable;
                        SysFreeString(text);
                    }
                    back->Release();
                }
                caret->Release();
            }
        }
        if (sel) sel->Release();
        tp->Release();
        el->Release();
        return f;
    }
};
static FieldReader g_reader;

/// The text before the caret ends with exactly `words`, preceded by whitespace, an opening
/// bracket/quote, or the start of the text.
static bool fieldShows(const FieldRead& f, const wstring& words) {
    if (f.state != FieldState::Readable || f.selection || words.empty() || !endsWith(f.before, words)) return false;
    if (f.before.size() == words.size()) return f.atStart;
    wchar_t c = f.before[f.before.size() - words.size() - 1];
    return isSpace(c) || c == L'(' || c == 0x00AB || c == 0x201C || c == 0x201E;
}

static const wchar_t* stateName(FieldState s) {
    switch (s) {
        case FieldState::Readable: return L"readable";
        case FieldState::NoText: return L"not a text field";
        case FieldState::Secure: return L"password field";
        case FieldState::Unreadable: return L"text unreadable";
        default: return L"no focused element";
    }
}

// ============================================================================================
// Engine
// ============================================================================================

struct Entry { vector<Key> keys; bool changed = false; };   // a word before a Space

struct Correction {
    vector<Key> typedKeys;     // the original keys (incl. Space keys between words)
    wstring typedText;         // what was on screen before the fix
    wstring inserted;          // what the fix typed (without the trailing Space)
    HKL fromLayout = nullptr;
    vector<wstring> words;     // for exceptions when undone
    ULONGLONG time = 0;
};

struct Job {
    enum Kind { Word, Undo } kind = Word;
    int id = 0;
    vector<Key> keys;
    wstring enText, ukText;
    std::optional<wstring> enToUk, ukToEn;
    bool streak = false;
    wstring app;
    Correction undo;
    bool learn = false;
    WORD heldKey = VK_SPACE;   // the key we swallowed to start the job
};

class Engine {
public:
    Config config;
    HWND hwnd = nullptr;

    void reloadConfig() {
        config = Config::load();
        bool wasLogging = g_logOn;
        g_logOn = config.debugLog;
        if (g_logOn && !wasLogging) writeLogHeader();
    }

    void writeLogHeader() {
        DeleteFileW(g_paths->log.c_str());
        wchar_t en[32], uk[32];
        swprintf(en, 32, L"%08llX", (unsigned long long)(UINT_PTR)g_layouts.en);
        swprintf(uk, 32, L"%08llX", (unsigned long long)(UINT_PTR)g_layouts.uk);
        logLine(L"KBSwitch diagnostic log · pid " + std::to_wstring(GetCurrentProcessId()));
        logLine(L"English layout: " + wstring(g_layouts.en ? en : L"NOT FOUND") + L" · Ukrainian layout: " + wstring(g_layouts.uk ? uk : L"NOT FOUND"));
        logLine(L"dictionaries: en " + wstring(g_lexicon.en.ok() ? L"loaded" : L"MISSING") + L", uk " + wstring(g_lexicon.uk.ok() ? L"loaded" : L"MISSING"));
        logLine(L"min=" + std::to_wstring(config.minLength) + L" max=" + std::to_wstring(config.maxLength) + L" undo=" + config.undoKey +
                L" translit=" + wstring(config.transliteration ? L"on" : L"off"));
    }

    // ---- called from the keyboard hook (must be fast) ----------------------------------

    /// Returns true to swallow the event.
    bool onKey(const KBDLLHOOKSTRUCT* k, bool down) {
        DWORD vk = k->vkCode;
        if (!down) {
            if (dropKeyUp_ && vk == dropKeyUpVk_) { dropKeyUp_ = false; downKeys_.erase(vk); return true; }
            downKeys_.erase(vk);
            return false;
        }
        bool repeat = downKeys_.count(vk) > 0;
        downKeys_.insert(vk);

        if (!config.enabled) { reset(L"disabled"); return false; }
        if (vk == VK_CAPITAL) { if (!repeat) caps_ = !caps_; return false; }
        if (isModifier(vk)) return false;      // Shift / Ctrl / Alt / Win alone: not typing

        bool ctrl = GetAsyncKeyState(VK_CONTROL) & 0x8000, alt = GetAsyncKeyState(VK_MENU) & 0x8000;
        bool win = (GetAsyncKeyState(VK_LWIN) & 0x8000) || (GetAsyncKeyState(VK_RWIN) & 0x8000);
        bool shift = GetAsyncKeyState(VK_SHIFT) & 0x8000;

        std::optional<Correction> pending = last_;
        last_.reset();
        if (pending && !repeat && !ctrl && !alt && !win && isUndoKey(vk) && GetTickCount64() - pending->time < 10000) {
            if (startUndo(*pending, vk)) return true;
        }
        if (ctrl || alt || win) {
            // Win+Space / Alt+Shift switch the layout: the caret doesn't move, keep the word.
            if (vk == VK_SPACE) { logLine(L"modifier+Space (layout switch?): keeping word"); return false; }
            reset(L"shortcut + key " + std::to_wstring(vk));
            return false;
        }

        switch (vk) {
            case VK_SPACE:
                if (repeat) { reset(L"held Space"); atWordStart_ = true; return false; }
                if (!buffer_.empty() && startWordCheck()) return true;
                pushWord(buffer_, false);
                buffer_.clear();
                atWordStart_ = true;
                break;
            case VK_BACK:
                if (repeat) reset(L"held Backspace");
                else if (!buffer_.empty()) buffer_.pop_back();
                else if (!history_.empty()) {               // deleted a Space: back into the previous word
                    buffer_ = history_.back().keys;
                    history_.pop_back();
                    logLine(L"backspace over Space: back into " + spell(buffer_));
                } else atWordStart_ = false;
                break;
            case VK_RETURN:
                // A new line starts, or a message was sent: earlier words can't be returned to safely.
                buffer_.clear(); history_.clear(); atWordStart_ = true;
                break;
            default: {
                Key key{(WORD)vk, (WORD)k->scanCode, shift, caps_};
                bool typing = !Layouts::charFor(key, g_layouts.en).empty() || !Layouts::charFor(key, g_layouts.uk).empty();
                if (repeat || !typing || (int)buffer_.size() >= config.maxLength || vk == VK_PACKET) {
                    reset(repeat ? L"held key" : L"non-typing key " + std::to_wstring(vk));
                    return false;
                }
                buffer_.push_back(key);
            }
        }
        if (g_logOn) logLine(L"key " + std::to_wstring(vk) + L" -> word " + spell(buffer_) + L" history=" + std::to_wstring(history_.size()));
        return false;
    }

    void onFocusChanged() { reset(L"focus changed"); }

    // ---- held keys while a check is running ------------------------------------------------

    bool busy() const { return busy_; }

    void hold(const KBDLLHOOKSTRUCT* k, bool down) {
        if (!down && dropKeyUp_ && k->vkCode == dropKeyUpVk_) { dropKeyUp_ = false; return; }
        INPUT in{};
        in.type = INPUT_KEYBOARD;
        in.ki.wVk = (WORD)k->vkCode;
        in.ki.wScan = (WORD)k->scanCode;
        in.ki.dwFlags = (down ? 0 : KEYEVENTF_KEYUP) | ((k->flags & LLKHF_EXTENDED) ? KEYEVENTF_EXTENDEDKEY : 0);
        if (k->vkCode == VK_PACKET) { in.ki.wVk = 0; in.ki.dwFlags |= KEYEVENTF_UNICODE; }
        in.ki.dwExtraInfo = kReplay;
        held_.push_back(in);
    }

    // ---- results from the field reader (main thread) ----------------------------------

    void onFieldRead(FieldRead* f) {
        std::unique_ptr<FieldRead> guard(f);
        if (!busy_ || f->job != job_.id) return;                 // timed out already
        KillTimer(hwnd, kTimerCheck);
        logLine(L"  field: " + wstring(stateName(f->state)) + (f->selection ? L" (selection)" : L"") +
                L" " + f->detail + L" before-caret='" + tail(f->before) + L"'");
        if (job_.kind == Job::Undo) finishUndo(*f);
        else finishWord(*f);
    }

    void onTimeout() {
        KillTimer(hwnd, kTimerCheck);
        if (!busy_) return;
        logLine(L"skip: the text field didn't answer in time");
        if (job_.kind == Job::Undo) { send({}, job_.heldKey); reset(L"undo timed out"); finishJob(); return; }
        skipWord();
    }

private:
    vector<Key> buffer_;
    bool atWordStart_ = false;
    std::deque<Entry> history_;
    std::optional<Correction> last_;
    std::set<wstring> sessionIgnore_;
    bool translitStreak_ = false;
    bool caps_ = (GetKeyState(VK_CAPITAL) & 1) != 0;
    std::set<DWORD> downKeys_;
    bool busy_ = false;
    Job job_;
    int nextJob_ = 1;
    vector<INPUT> held_;
    bool dropKeyUp_ = false;
    DWORD dropKeyUpVk_ = 0;
    std::map<DWORD, wstring> appNames_;

    static bool isModifier(DWORD vk) {
        switch (vk) {
            case VK_SHIFT: case VK_LSHIFT: case VK_RSHIFT: case VK_CONTROL: case VK_LCONTROL: case VK_RCONTROL:
            case VK_MENU: case VK_LMENU: case VK_RMENU: case VK_LWIN: case VK_RWIN: return true;
            default: return false;
        }
    }

    bool isUndoKey(DWORD vk) const {
        return (config.undoKey == L"escape" && vk == VK_ESCAPE) || (config.undoKey == L"backspace" && vk == VK_BACK);
    }

    static wstring tail(const wstring& s) { return s.size() > 40 ? s.substr(s.size() - 40) : s; }

    wstring spell(const vector<Key>& keys) const {
        wstring e, u;
        Layouts::spell(keys, g_layouts.en, e);
        Layouts::spell(keys, g_layouts.uk, u);
        return L"'" + e + L"|" + u + L"'";
    }

    void reset(const wstring& why) {
        if (g_logOn && (!buffer_.empty() || !history_.empty())) logLine(L"forget word " + spell(buffer_) + L": " + why);
        buffer_.clear(); history_.clear(); atWordStart_ = false; last_.reset(); translitStreak_ = false;
    }

    void pushWord(const vector<Key>& keys, bool changed) {
        history_.push_back({keys, changed});
        if (history_.size() > 10) history_.pop_front();
    }

    std::set<wstring> exceptions() const {
        std::set<wstring> e = config.exceptions;
        e.insert(sessionIgnore_.begin(), sessionIgnore_.end());
        return e;
    }

    // ---- foreground app -------------------------------------------------------------------

    struct Foreground { wstring exe; bool elevated = false; };

    Foreground foreground() {
        Foreground fg;
        HWND w = GetForegroundWindow();
        DWORD pid = 0;
        GetWindowThreadProcessId(w, &pid);
        if (!pid) return fg;
        HANDLE p = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
        if (!p) { fg.elevated = true; return fg; }
        auto it = appNames_.find(pid);
        if (it != appNames_.end()) fg.exe = it->second;
        else {
            wchar_t path[MAX_PATH * 2];
            DWORD n = MAX_PATH * 2;
            if (QueryFullProcessImageNameW(p, 0, path, &n)) {
                wstring full(path, n);
                fg.exe = lower(full.substr(full.find_last_of(L"\\/") + 1));
                appNames_[pid] = fg.exe;
            }
        }
        // Keys can't be sent to an app running as administrator (Windows blocks it), so never
        // hold back keys there: they would be lost.
        HANDLE token = nullptr;
        if (OpenProcessToken(p, TOKEN_QUERY, &token)) {
            TOKEN_ELEVATION e{};
            DWORD size = 0;
            if (GetTokenInformation(token, TokenElevation, &e, sizeof e, &size)) fg.elevated = e.TokenIsElevated != 0;
            CloseHandle(token);
        } else fg.elevated = true;
        CloseHandle(p);
        static bool selfElevated = [] {
            HANDLE t = nullptr; TOKEN_ELEVATION e{}; DWORD s = 0; bool r = false;
            if (OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &t)) {
                if (GetTokenInformation(t, TokenElevation, &e, sizeof e, &s)) r = e.TokenIsElevated != 0;
                CloseHandle(t);
            }
            return r;
        }();
        if (selfElevated) fg.elevated = false;
        return fg;
    }

    // ---- starting checks (hook) -----------------------------------------------------------

    /// A Latin word read as Ukrainian (trailing punctuation kept), or nullopt with the reason.
    std::optional<std::pair<wstring, wstring>> ukrainianReading(const wstring& enText, bool allowEnglish, wstring& why) const {
        size_t end = enText.size();
        while (end > 0 && wcschr(L".,!?;:", enText[end - 1])) end--;
        wstring trail = enText.substr(end), word = enText.substr(0, end);
        // Short words: two letters always (ya -> я), one letter only mid-sentence (i -> і, v -> в).
        if ((int)word.size() < (allowEnglish ? 1 : 2) || !isAlpha(word[0])) { why = L"'" + enText + L"' is not a plain Latin word"; return std::nullopt; }
        for (wchar_t c : word)
            if (!((c >= L'a' && c <= L'z') || (c >= L'A' && c <= L'Z') || c == L'\'' || c == L'`')) { why = L"'" + enText + L"' is not a plain Latin word"; return std::nullopt; }
        if (!Decision::naturalCase(word)) { why = L"unusual casing '" + word + L"'"; return std::nullopt; }
        std::set<wstring> exc = exceptions();
        wstring l = lower(word);
        if (exc.count(l)) { why = L"'" + word + L"' is in exceptions"; return std::nullopt; }
        if (!allowEnglish && g_lexicon.isWord(word, L"en")) { why = L"'" + word + L"' is English"; return std::nullopt; }
        std::optional<wstring> cyr = Translit::convert(l);
        if (!cyr) { why = L"no Ukrainian reading of '" + word + L"'"; return std::nullopt; }
        if (exc.count(*cyr)) { why = L"'" + *cyr + L"' is in exceptions"; return std::nullopt; }
        wstring out = *cyr;
        if (word == upper(word) && word.size() > 1) out = upper(out);
        else if (word != l) out = upper(out.substr(0, 1)) + out.substr(1);
        return std::make_pair(out + trail, word);
    }

    bool startWordCheck() {
        bool streak = translitStreak_;
        translitStreak_ = false;
        int shortest = config.transliteration ? 1 : config.minLength;
        if ((int)buffer_.size() < shortest || (int)buffer_.size() > config.maxLength) return false;
        if (!g_layouts.en || !g_layouts.uk) { logLine(L"skip: need both an English and a Ukrainian layout"); return false; }
        if (!g_lexicon.en.ok() || !g_lexicon.uk.ok()) { logLine(L"skip: dictionaries missing next to the exe (dict\\)"); return false; }

        Job j;
        j.keys = buffer_;
        j.streak = streak;
        if (!Layouts::spell(buffer_, g_layouts.en, j.enText) || !Layouts::spell(buffer_, g_layouts.uk, j.ukText)) {
            logLine(L"skip: a key has no single character in one of the layouts");
            return false;
        }
        std::set<wstring> exc = exceptions();
        j.enToUk = Decision::rejection(j.enText, j.ukText, L"en", L"uk", config.minLength, exc);
        j.ukToEn = Decision::rejection(j.ukText, j.enText, L"uk", L"en", config.minLength, exc);
        bool layoutFix = !(j.enToUk && j.ukToEn);
        wstring why;
        bool translit = config.transliteration && ukrainianReading(j.enText, streak, why).has_value();
        bool typo = config.autocorrect && buffer_.size() >= 4 &&
                    (Typos::isPlain(j.enText, L"en") || Typos::isPlain(j.ukText, L"uk")) &&
                    !g_lexicon.isWord(j.enText, L"en") && !g_lexicon.isWord(j.ukText, L"uk");
        if (!layoutFix && !translit && !typo) {
            if (g_logOn) logLine(L"skip: en '" + j.enText + L"' / uk '" + j.ukText + L"': nothing to fix (en->uk: " +
                                 j.enToUk.value_or(L"") + L"; uk->en: " + j.ukToEn.value_or(L"") + L")");
            return false;
        }
        Foreground fg = foreground();
        j.app = fg.exe;
        if (config.excludedApps.count(fg.exe)) { logLine(L"skip: excluded app " + fg.exe); return false; }
        if (fg.elevated) { logLine(L"skip: " + fg.exe + L" runs as administrator"); return false; }

        j.kind = Job::Word;
        j.heldKey = VK_SPACE;
        begin(j, {j.enText, j.ukText});
        return true;
    }

    bool startUndo(const Correction& c, DWORD vk) {
        Foreground fg = foreground();
        if (fg.elevated) return false;
        Job j;
        j.kind = Job::Undo;
        j.undo = c;
        j.learn = vk == VK_ESCAPE;
        j.heldKey = (WORD)vk;
        begin(j, {c.inserted + L" "});
        return true;
    }

    void begin(Job& j, vector<wstring> endings) {
        j.id = nextJob_++;
        job_ = j;
        busy_ = true;
        held_.clear();
        dropKeyUp_ = true;
        dropKeyUpVk_ = j.heldKey;
        g_reader.request({j.id, std::move(endings)});
        SetTimer(hwnd, kTimerCheck, 700, nullptr);
    }

    // ---- finishing checks (main thread) ---------------------------------------------------

    static void addKey(vector<INPUT>& in, WORD vk) {
        INPUT a{};
        a.type = INPUT_KEYBOARD;
        a.ki.wVk = vk;
        a.ki.wScan = (WORD)MapVirtualKeyW(vk, MAPVK_VK_TO_VSC);
        a.ki.dwExtraInfo = kOwnInput;
        in.push_back(a);
        a.ki.dwFlags = KEYEVENTF_KEYUP;
        in.push_back(a);
    }

    static void addText(vector<INPUT>& in, const wstring& text) {
        for (wchar_t c : text) {
            if (c == L' ') { addKey(in, VK_SPACE); continue; }
            INPUT a{};
            a.type = INPUT_KEYBOARD;
            a.ki.wScan = c;
            a.ki.dwFlags = KEYEVENTF_UNICODE;
            a.ki.dwExtraInfo = kOwnInput;
            in.push_back(a);
            a.ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;
            in.push_back(a);
        }
    }

    /// One SendInput call: the edit, the swallowed key (if any), then everything typed meanwhile.
    void send(vector<INPUT> in, WORD swallowedKey) {
        if (swallowedKey) addKey(in, swallowedKey);
        in.insert(in.end(), held_.begin(), held_.end());
        held_.clear();
        if (!in.empty()) SendInput((UINT)in.size(), in.data(), sizeof(INPUT));
    }

    void finishJob() { busy_ = false; }

    static void switchLayout(HKL hkl) {
        HWND target = GetForegroundWindow();
        GUITHREADINFO gti{};
        gti.cbSize = sizeof gti;
        if (GetGUIThreadInfo(GetWindowThreadProcessId(target, nullptr), &gti) && gti.hwndFocus) target = gti.hwndFocus;
        PostMessageW(target, WM_INPUTLANGCHANGEREQUEST, 0, (LPARAM)hkl);
    }

    void skipWord() {
        pushWord(job_.keys, false);
        buffer_.clear();
        atWordStart_ = true;
        send({}, VK_SPACE);
        finishJob();
    }

    void finishWord(const FieldRead& f) {
        if (f.state != FieldState::Readable) { logLine(wstring(L"skip: ") + stateName(f.state) + L" in " + job_.app); skipWord(); return; }
        bool inEnglish = fieldShows(f, job_.enText), inUkrainian = fieldShows(f, job_.ukText);
        if (!inEnglish && !inUkrainian) { logLine(L"skip: the field doesn't show the typed word"); skipWord(); return; }

        const std::optional<wstring>& why = inEnglish ? job_.enToUk : job_.ukToEn;
        if (why) {
            // A Latin word that is fine as English may still be transliterated (in context).
            if (inEnglish && config.transliteration && transliterate(f)) return;
            if (config.autocorrect && fixTypo(inEnglish)) return;
            logLine(L"skip: '" + (inEnglish ? job_.enText : job_.ukText) + L"' is on screen and is fine: " + *why);
            skipWord();
            return;
        }
        layoutFix(f, inEnglish);
    }

    void layoutFix(const FieldRead& f, bool inEnglish) {
        HKL from = inEnglish ? g_layouts.en : g_layouts.uk, to = inEnglish ? g_layouts.uk : g_layouts.en;
        wstring toLang = inEnglish ? L"uk" : L"en";
        wstring typed = inEnglish ? job_.enText : job_.ukText, converted = inEnglish ? job_.ukText : job_.enText;

        // Words just before this one, typed in the same wrong layout but left alone because they were
        // also fine as they were (s -> і, d -> в): convert them too, if KBSwitch didn't change them
        // and the field shows exactly "those words + this word".
        struct Prev { vector<Key> keys; wstring fromText, toText; };
        vector<Prev> previous;
        std::set<wstring> exc = exceptions();
        for (auto it = history_.rbegin(); it != history_.rend(); ++it) {
            if (it->changed || it->keys.empty()) break;
            Prev p{it->keys, L"", L""};
            if (!Layouts::spell(p.keys, from, p.fromText) || !Layouts::spell(p.keys, to, p.toText)) break;
            if (p.fromText == p.toText || !Decision::isCleanWord(p.toText, toLang) || !g_lexicon.isWord(p.toText, toLang) ||
                exc.count(lower(p.fromText)) || exc.count(lower(p.toText))) break;
            previous.insert(previous.begin(), p);
        }
        while (!previous.empty()) {
            vector<wstring> words;
            for (const Prev& p : previous) words.push_back(p.fromText);
            words.push_back(typed);
            if (fieldShows(f, joinWords(words))) break;
            previous.erase(previous.begin());
        }

        vector<wstring> before, after, originals;
        for (const Prev& p : previous) { before.push_back(p.fromText); after.push_back(p.toText); originals.push_back(Decision::core(p.fromText)); }
        before.push_back(typed);
        after.push_back(converted);
        originals.push_back(Decision::core(typed));
        wstring oldText = joinWords(before), newText = joinWords(after);
        logLine(L"fix: '" + oldText + L"' -> '" + newText + L"' in " + job_.app);

        vector<INPUT> in;
        for (size_t i = 0; i < oldText.size(); i++) addKey(in, VK_BACK);
        addText(in, newText + L" ");
        send(in, 0);
        switchLayout(to);

        Correction c;
        for (const Prev& p : previous) { c.typedKeys.insert(c.typedKeys.end(), p.keys.begin(), p.keys.end()); c.typedKeys.push_back(Key{VK_SPACE, 0, false, false}); }
        c.typedKeys.insert(c.typedKeys.end(), job_.keys.begin(), job_.keys.end());
        c.typedText = oldText;
        c.inserted = newText;
        c.fromLayout = from;
        c.words = originals;
        c.time = GetTickCount64();
        last_ = c;

        for (size_t i = 0; i < previous.size() && !history_.empty(); i++) history_.pop_back();
        for (const Prev& p : previous) pushWord(p.keys, true);
        pushWord(job_.keys, true);
        buffer_.clear();
        atWordStart_ = true;
        finishJob();
    }

    /// Optional mode: a Latin word that reads as Ukrainian (privit -> привіт). Words that are also
    /// English (yak -> як) only in context: right after a converted word, or together with the next
    /// word once that one converts. The layout is left as it is.
    bool transliterate(const FieldRead& f) {
        wstring why;
        auto current = ukrainianReading(job_.enText, job_.streak, why);
        if (!current) { logLine(L"translit skip: " + why); return false; }

        std::optional<std::pair<wstring, wstring>> previous;   // (Cyrillic, Latin)
        vector<Key> prevKeys;
        if (!job_.streak && !history_.empty() && !history_.back().changed && !history_.back().keys.empty()) {
            wstring prevLatin, ignored;
            if (Layouts::spell(history_.back().keys, g_layouts.en, prevLatin)) {
                auto p = ukrainianReading(prevLatin, true, ignored);
                if (p && fieldShows(f, prevLatin + L" " + job_.enText)) { previous = std::make_pair(p->first, prevLatin); prevKeys = history_.back().keys; }
            }
        }
        if (!previous && !fieldShows(f, job_.enText)) { logLine(L"translit skip: the field doesn't show '" + job_.enText + L"'"); return false; }

        wstring oldText = (previous ? previous->second + L" " : L"") + job_.enText;
        wstring newText = (previous ? previous->first + L" " : L"") + current->first;
        logLine(L"translit: '" + oldText + L"' -> '" + newText + L"' in " + job_.app);

        vector<INPUT> in;
        for (size_t i = 0; i < oldText.size(); i++) addKey(in, VK_BACK);
        addText(in, newText + L" ");
        send(in, 0);

        Correction c;
        if (previous) { c.typedKeys = prevKeys; c.typedKeys.push_back(Key{VK_SPACE, 0, false, false}); c.words.push_back(previous->second); }
        c.typedKeys.insert(c.typedKeys.end(), job_.keys.begin(), job_.keys.end());
        c.words.push_back(current->second);
        c.typedText = oldText;
        c.inserted = newText;
        c.fromLayout = g_layouts.en;
        c.time = GetTickCount64();
        last_ = c;

        // The result has no key equivalent we track: backspacing into it starts fresh.
        history_.clear();
        translitStreak_ = true;
        buffer_.clear();
        atWordStart_ = true;
        finishJob();
        return true;
    }

    /// Optional mode: a word that is not a word in either layout but one common slip away from exactly
    /// one word (implemnet -> implement). Tried on the spelling on screen first, then on the other
    /// layout's spelling (a typo typed in the wrong layout too).
    bool fixTypo(bool inEnglish) {
        if (job_.keys.size() < 4) return false;
        wstring screen = inEnglish ? job_.enText : job_.ukText, other = inEnglish ? job_.ukText : job_.enText;
        wstring screenLang = inEnglish ? L"en" : L"uk", otherLang = inEnglish ? L"uk" : L"en";
        HKL screenHkl = inEnglish ? g_layouts.en : g_layouts.uk, otherHkl = inEnglish ? g_layouts.uk : g_layouts.en;
        std::set<wstring> exc = exceptions();
        if (exc.count(lower(screen)) || exc.count(lower(other))) { logLine(L"typo skip: in exceptions"); return false; }
        if (g_lexicon.isWord(screen, screenLang) || g_lexicon.isWord(other, otherLang)) return false;

        ULONGLONG deadline = GetTickCount64() + 40;     // never hold up typing for long
        std::optional<wstring> fix;
        bool otherLayout = false;
        if (Typos::isPlain(screen, screenLang)) fix = Typos::correction(screen, screenLang, screenHkl, deadline);
        if (!fix && Typos::isPlain(other, otherLang)) {
            fix = Typos::correction(other, otherLang, otherHkl, deadline);
            otherLayout = fix.has_value();
        }
        if (!fix) { logLine(L"typo skip: no single word one slip away from '" + screen + L"'"); return false; }
        if (exc.count(*fix)) { logLine(L"typo skip: '" + *fix + L"' is in exceptions"); return false; }
        logLine(L"typo: '" + screen + L"' -> '" + *fix + L"' in " + job_.app);

        vector<INPUT> in;
        for (size_t i = 0; i < screen.size(); i++) addKey(in, VK_BACK);
        addText(in, *fix + L" ");
        send(in, 0);
        if (otherLayout) switchLayout(otherHkl);

        Correction c;
        c.typedKeys = job_.keys;
        c.typedText = screen;
        c.inserted = *fix;
        c.fromLayout = screenHkl;
        c.words = {screen};
        c.time = GetTickCount64();
        last_ = c;
        history_.clear();
        translitStreak_ = false;
        buffer_.clear();
        atWordStart_ = true;
        finishJob();
        return true;
    }

    void finishUndo(const FieldRead& f) {
        const Correction& c = job_.undo;
        if (!fieldShows(f, c.inserted + L" ")) {
            logLine(L"undo skipped: the field no longer shows '" + c.inserted + L"'");
            send({}, job_.heldKey);
            reset(L"text changed before undo");
            finishJob();
            return;
        }
        logLine(L"undo: '" + c.inserted + L"' -> '" + c.typedText + L"'");
        vector<INPUT> in;
        for (size_t i = 0; i < c.inserted.size() + 1; i++) addKey(in, VK_BACK);
        addText(in, c.typedText + L" ");
        send(in, 0);
        switchLayout(c.fromLayout);
        for (const wstring& w : c.words) {
            sessionIgnore_.insert(lower(w));
            // Backspace is also plain editing, so only an Esc undo is remembered for good.
            if (job_.learn && config.learnOnUndo) {
                wstring text = readFile(g_paths->exceptions);
                if (!text.empty() && text.back() != L'\n') text += L"\r\n";
                writeFile(g_paths->exceptions, text + lower(w) + L"\r\n");
                config.exceptions.insert(lower(w));
            }
        }
        history_.clear();
        buffer_.clear();
        translitStreak_ = false;
        atWordStart_ = true;
        finishJob();
    }
};
static Engine g_engine;

// ============================================================================================
// Hooks
// ============================================================================================

static HHOOK g_keyboardHook = nullptr;
static HWND g_lastFocus = nullptr;

static LRESULT CALLBACK keyboardProc(int code, WPARAM wp, LPARAM lp) {
    if (code == HC_ACTION) {
        auto* k = reinterpret_cast<KBDLLHOOKSTRUCT*>(lp);
        bool ours = (k->flags & LLKHF_INJECTED) && k->dwExtraInfo == kOwnInput;
        if (!ours) {
            bool down = wp == WM_KEYDOWN || wp == WM_SYSKEYDOWN;
            if (g_engine.busy()) { g_engine.hold(k, down); return 1; }   // replayed after the check
            if (g_engine.onKey(k, down)) return 1;
        }
    }
    return CallNextHookEx(g_keyboardHook, code, wp, lp);
}

static void CALLBACK focusProc(HWINEVENTHOOK, DWORD event, HWND hwnd, LONG, LONG, DWORD, DWORD) {
    if (event == EVENT_SYSTEM_FOREGROUND || (event == EVENT_OBJECT_FOCUS && hwnd != g_lastFocus)) {
        g_lastFocus = hwnd;
        if (!g_engine.busy()) g_engine.onFocusChanged();
    }
}

// ============================================================================================
// Start with Windows (HKCU\...\Run)
// ============================================================================================

static const wchar_t* kRunKey = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";

static bool startsWithWindows() {
    HKEY key;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, kRunKey, 0, KEY_QUERY_VALUE, &key) != ERROR_SUCCESS) return false;
    bool on = RegQueryValueExW(key, L"KBSwitch", nullptr, nullptr, nullptr, nullptr) == ERROR_SUCCESS;
    RegCloseKey(key);
    return on;
}

static void setStartWithWindows(bool on) {
    HKEY key;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, kRunKey, 0, KEY_SET_VALUE, &key) != ERROR_SUCCESS) return;
    if (on) {
        wchar_t path[MAX_PATH * 2];
        DWORD n = GetModuleFileNameW(nullptr, path, MAX_PATH * 2);
        wstring value = L"\"" + wstring(path, n) + L"\"";
        RegSetValueExW(key, L"KBSwitch", 0, REG_SZ, (const BYTE*)value.c_str(), (DWORD)((value.size() + 1) * sizeof(wchar_t)));
    } else RegDeleteValueW(key, L"KBSwitch");
    RegCloseKey(key);
}

// ============================================================================================
// Install: the exe copies itself (with dict\) into %LOCALAPPDATA%\Programs\KBSwitch, adds a Start
// menu entry and runs from there, so it works like an installed app. Running a newer copy updates it.
// ============================================================================================

static wstring installDir() { return knownFolder(L"LOCALAPPDATA", L"Programs") + L"\\KBSwitch"; }

static wstring startMenuLink() {
    wchar_t* folder = nullptr;
    wstring path;
    if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_Programs, 0, nullptr, &folder))) path = wstring(folder) + L"\\KBSwitch.lnk";
    CoTaskMemFree(folder);
    return path;
}

static void createShortcut(const wstring& target, const wstring& link) {
    IShellLinkW* sl = nullptr;
    if (FAILED(CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER, IID_IShellLinkW, (void**)&sl))) return;
    sl->SetPath(target.c_str());
    sl->SetWorkingDirectory(target.substr(0, target.find_last_of(L'\\')).c_str());
    sl->SetDescription(L"Fixes words typed in the wrong keyboard layout (English / Ukrainian)");
    IPersistFile* pf = nullptr;
    if (SUCCEEDED(sl->QueryInterface(IID_IPersistFile, (void**)&pf))) { pf->Save(link.c_str(), TRUE); pf->Release(); }
    sl->Release();
}

/// Returns true if this copy installed itself and launched the installed copy.
static bool selfInstall() {
    wstring here = exeDir(), dir = installDir();
    if (lower(here) == lower(dir)) return false;
    wstring dictFrom = here + L"\\dict", dictTo = dir + L"\\dict";
    if (GetFileAttributesW((dictFrom + L"\\uk_UA.dic").c_str()) == INVALID_FILE_ATTRIBUTES) return false;   // not a release folder

    // Updating: ask a running copy to quit first so its exe can be replaced.
    if (HWND other = FindWindowW(kWindowClass, nullptr)) {
        DWORD pid = 0;
        GetWindowThreadProcessId(other, &pid);
        HANDLE p = OpenProcess(SYNCHRONIZE, FALSE, pid);
        PostMessageW(other, WM_APP_QUIT, 0, 0);
        if (p) { WaitForSingleObject(p, 5000); CloseHandle(p); }
    }
    CreateDirectoryW(dir.c_str(), nullptr);
    CreateDirectoryW(dictTo.c_str(), nullptr);
    wchar_t self[MAX_PATH * 2];
    DWORD n = GetModuleFileNameW(nullptr, self, MAX_PATH * 2);
    wstring exe = dir + L"\\KBSwitch.exe";
    bool ok = CopyFileW(wstring(self, n).c_str(), exe.c_str(), FALSE) != 0;
    for (const wchar_t* f : {L"en_US.aff", L"en_US.dic", L"uk_UA.aff", L"uk_UA.dic"})
        ok = CopyFileW((dictFrom + L"\\" + f).c_str(), (dictTo + L"\\" + f).c_str(), FALSE) && ok;
    if (!ok) {
        MessageBoxW(nullptr, (L"KBSwitch couldn't be installed into\n" + dir + L"\nIt will run from its current folder instead.").c_str(),
                    L"KBSwitch", MB_ICONWARNING);
        return false;
    }
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    createShortcut(exe, startMenuLink());
    ShellExecuteW(nullptr, L"open", exe.c_str(), L"--installed", dir.c_str(), SW_SHOWNORMAL);
    return true;
}

static void setStartWithWindows(bool on);

static void uninstall() {
    if (MessageBoxW(nullptr, L"Remove KBSwitch from this computer, including its settings?", L"Uninstall KBSwitch",
                    MB_YESNO | MB_ICONQUESTION | MB_DEFBUTTON2) != IDYES) return;
    setStartWithWindows(false);
    DeleteFileW(startMenuLink().c_str());
    wstring cmd = L"/c ping -n 3 127.0.0.1 >nul & rmdir /s /q \"" + g_paths->dir + L"\" & rmdir /s /q \"" +
                  knownFolder(L"LOCALAPPDATA", L"KBSwitch") + L"\"";
    if (lower(exeDir()) == lower(installDir())) cmd += L" & rmdir /s /q \"" + installDir() + L"\"";
    ShellExecuteW(nullptr, L"open", L"cmd.exe", cmd.c_str(), nullptr, SW_HIDE);
    PostQuitMessage(0);
}

// ============================================================================================
// Tray icon
// ============================================================================================

enum MenuId { ID_ENABLED = 1, ID_SETTINGS, ID_LOG, ID_SHOWLOG, ID_UNINSTALL, ID_QUIT };
static NOTIFYICONDATAW g_tray{};
static UINT g_taskbarCreated = 0;

static void updateTray(bool add) {
    g_tray.cbSize = sizeof g_tray;
    g_tray.hWnd = g_engine.hwnd;
    g_tray.uID = 1;
    g_tray.uFlags = NIF_ICON | NIF_TIP | NIF_MESSAGE;
    g_tray.uCallbackMessage = WM_APP_TRAY;
    int size = GetSystemMetrics(SM_CXSMICON);
    if (g_tray.hIcon) DestroyIcon(g_tray.hIcon);
    g_tray.hIcon = (HICON)LoadImageW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(g_engine.config.enabled ? IDI_TRAY_ON : IDI_TRAY_OFF),
                                     IMAGE_ICON, size, size, 0);
    wcscpy_s(g_tray.szTip, g_engine.config.enabled ? L"KBSwitch" : L"KBSwitch (off)");
    Shell_NotifyIconW(add ? NIM_ADD : NIM_MODIFY, &g_tray);
}

static void saveConfig(const Config& c) {
    c.save();
    g_engine.reloadConfig();
    updateTray(false);
}

static void showSettings();

static void showMenu() {
    HMENU m = CreatePopupMenu();
    AppendMenuW(m, MF_STRING | (g_engine.config.enabled ? MF_CHECKED : 0), ID_ENABLED, L"Enabled");
    AppendMenuW(m, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(m, MF_STRING, ID_SETTINGS, L"Settings\u2026");
    AppendMenuW(m, MF_STRING | (g_engine.config.debugLog ? MF_CHECKED : 0), ID_LOG, L"Diagnostic Log");
    if (g_engine.config.debugLog) AppendMenuW(m, MF_STRING, ID_SHOWLOG, L"Show Log");
    AppendMenuW(m, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(m, MF_STRING, ID_UNINSTALL, L"Uninstall\u2026");
    AppendMenuW(m, MF_STRING, ID_QUIT, L"Quit KBSwitch");
    POINT pt;
    GetCursorPos(&pt);
    SetForegroundWindow(g_engine.hwnd);
    int cmd = TrackPopupMenu(m, TPM_RETURNCMD | TPM_RIGHTBUTTON, pt.x, pt.y, 0, g_engine.hwnd, nullptr);
    DestroyMenu(m);
    Config c = Config::load();
    switch (cmd) {
        case ID_ENABLED: c.enabled = !c.enabled; saveConfig(c); break;
        case ID_SETTINGS: showSettings(); break;
        case ID_LOG: c.debugLog = !c.debugLog; saveConfig(c); break;
        case ID_SHOWLOG: ShellExecuteW(nullptr, L"open", g_paths->log.c_str(), nullptr, nullptr, SW_SHOWNORMAL); break;
        case ID_UNINSTALL: uninstall(); break;
        case ID_QUIT: PostQuitMessage(0); break;
    }
}

// ============================================================================================
// Settings window (plain Win32 controls, native look)
// ============================================================================================

enum SettingsId {
    IDC_ENABLED = 100, IDC_STARTUP, IDC_MIN, IDC_MAX, IDC_UNDO, IDC_LEARN, IDC_TRANSLIT, IDC_TYPOS,
    IDC_EXCEPTIONS, IDC_APPS, IDC_LOG, IDC_SAVE, IDC_CANCEL
};
static HWND g_settings = nullptr;
static HFONT g_font = nullptr;

static int dpiScale(int v) { return MulDiv(v, (int)GetDpiForSystem(), 96); }

static HWND control(HWND parent, const wchar_t* cls, const wchar_t* text, DWORD style, int x, int y, int w, int h, int id) {
    HWND c = CreateWindowExW(cls == wstring(L"EDIT") ? WS_EX_CLIENTEDGE : 0, cls, text, WS_CHILD | WS_VISIBLE | style,
                             dpiScale(x), dpiScale(y), dpiScale(w), dpiScale(h), parent, (HMENU)(INT_PTR)id, GetModuleHandleW(nullptr), nullptr);
    SendMessageW(c, WM_SETFONT, (WPARAM)g_font, TRUE);
    return c;
}

static wstring windowText(HWND w) {
    int n = GetWindowTextLengthW(w);
    wstring s(n, L'\0');
    if (n) GetWindowTextW(w, s.data(), n + 1);
    return s;
}

static void fillSettings(HWND w) {
    const Config& c = g_engine.config;
    CheckDlgButton(w, IDC_ENABLED, c.enabled ? BST_CHECKED : BST_UNCHECKED);
    CheckDlgButton(w, IDC_STARTUP, startsWithWindows() ? BST_CHECKED : BST_UNCHECKED);
    SetDlgItemInt(w, IDC_MIN, c.minLength, FALSE);
    SetDlgItemInt(w, IDC_MAX, c.maxLength, FALSE);
    HWND undo = GetDlgItem(w, IDC_UNDO);
    SendMessageW(undo, CB_SETCURSEL, c.undoKey == L"escape" ? 0 : c.undoKey == L"backspace" ? 1 : 2, 0);
    CheckDlgButton(w, IDC_LEARN, c.learnOnUndo ? BST_CHECKED : BST_UNCHECKED);
    CheckDlgButton(w, IDC_TRANSLIT, c.transliteration ? BST_CHECKED : BST_UNCHECKED);
    CheckDlgButton(w, IDC_TYPOS, c.autocorrect ? BST_CHECKED : BST_UNCHECKED);
    CheckDlgButton(w, IDC_LOG, c.debugLog ? BST_CHECKED : BST_UNCHECKED);
    wstring words;
    for (const wstring& line : fileLines(g_paths->exceptions)) words += line + L"\r\n";
    SetDlgItemTextW(w, IDC_EXCEPTIONS, words.c_str());
    wstring apps;
    for (const wstring& a : c.excludedApps) { if (!apps.empty()) apps += L", "; apps += a; }
    SetDlgItemTextW(w, IDC_APPS, apps.c_str());
}

static void saveSettings(HWND w) {
    Config c = Config::load();
    c.enabled = IsDlgButtonChecked(w, IDC_ENABLED) == BST_CHECKED;
    c.minLength = std::max(1, std::min(10, (int)GetDlgItemInt(w, IDC_MIN, nullptr, FALSE)));
    c.maxLength = std::max(c.minLength, std::min(60, (int)GetDlgItemInt(w, IDC_MAX, nullptr, FALSE)));
    int undo = (int)SendMessageW(GetDlgItem(w, IDC_UNDO), CB_GETCURSEL, 0, 0);
    c.undoKey = undo == 1 ? L"backspace" : undo == 2 ? L"none" : L"escape";
    c.learnOnUndo = IsDlgButtonChecked(w, IDC_LEARN) == BST_CHECKED;
    c.transliteration = IsDlgButtonChecked(w, IDC_TRANSLIT) == BST_CHECKED;
    c.autocorrect = IsDlgButtonChecked(w, IDC_TYPOS) == BST_CHECKED;
    c.debugLog = IsDlgButtonChecked(w, IDC_LOG) == BST_CHECKED;
    c.excludedApps.clear();
    wstring apps = windowText(GetDlgItem(w, IDC_APPS));
    size_t start = 0;
    while (start <= apps.size()) {
        size_t comma = apps.find(L',', start);
        wstring item = lower(trim(apps.substr(start, comma == wstring::npos ? wstring::npos : comma - start)));
        if (!item.empty()) c.excludedApps.insert(item);
        if (comma == wstring::npos) break;
        start = comma + 1;
    }
    wstring words = windowText(GetDlgItem(w, IDC_EXCEPTIONS)), out = L"# Words that are never converted: one per line, in either layout.\r\n", line;
    for (size_t i = 0; i <= words.size(); i++) {
        if (i == words.size() || words[i] == L'\n') { line = trim(line); if (!line.empty()) out += line + L"\r\n"; line.clear(); }
        else line += words[i];
    }
    writeFile(g_paths->exceptions, out);
    setStartWithWindows(IsDlgButtonChecked(w, IDC_STARTUP) == BST_CHECKED);
    saveConfig(c);
}

static LRESULT CALLBACK settingsProc(HWND w, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
        case WM_CREATE: {
            int y = 14;
            control(w, L"BUTTON", L"Enabled", BS_AUTOCHECKBOX | WS_TABSTOP, 16, y, 340, 22, IDC_ENABLED); y += 26;
            control(w, L"BUTTON", L"Start with Windows", BS_AUTOCHECKBOX | WS_TABSTOP, 16, y, 340, 22, IDC_STARTUP); y += 36;
            control(w, L"STATIC", L"Minimum word length", 0, 16, y + 3, 200, 20, 0);
            control(w, L"EDIT", L"", ES_NUMBER | WS_TABSTOP, 300, y, 56, 24, IDC_MIN); y += 30;
            control(w, L"STATIC", L"Maximum word length", 0, 16, y + 3, 200, 20, 0);
            control(w, L"EDIT", L"", ES_NUMBER | WS_TABSTOP, 300, y, 56, 24, IDC_MAX); y += 30;
            control(w, L"STATIC", L"Undo a fix with", 0, 16, y + 3, 200, 20, 0);
            HWND undo = control(w, L"COMBOBOX", L"", CBS_DROPDOWNLIST | WS_TABSTOP, 236, y, 120, 200, IDC_UNDO);
            for (const wchar_t* s : {L"Esc", L"Backspace", L"Off"}) SendMessageW(undo, CB_ADDSTRING, 0, (LPARAM)s);
            y += 32;
            control(w, L"BUTTON", L"Never convert words undone with Esc", BS_AUTOCHECKBOX | WS_TABSTOP, 16, y, 340, 22, IDC_LEARN); y += 26;
            control(w, L"BUTTON", L"Ukrainian typed in Latin \u2192 Cyrillic (privit \u2192 \u043f\u0440\u0438\u0432\u0456\u0442)", BS_AUTOCHECKBOX | WS_TABSTOP, 16, y, 360, 22, IDC_TRANSLIT); y += 26;
            control(w, L"BUTTON", L"Fix typos (one letter off: implemnet \u2192 implement)", BS_AUTOCHECKBOX | WS_TABSTOP, 16, y, 360, 22, IDC_TYPOS); y += 34;
            control(w, L"STATIC", L"Never convert (one word per line, either layout)", 0, 16, y, 340, 20, 0); y += 22;
            control(w, L"EDIT", L"", ES_MULTILINE | ES_AUTOVSCROLL | WS_VSCROLL | ES_WANTRETURN | WS_TABSTOP, 16, y, 340, 80, IDC_EXCEPTIONS); y += 92;
            control(w, L"STATIC", L"Ignored apps (program names, comma separated)", 0, 16, y, 340, 20, 0); y += 22;
            control(w, L"EDIT", L"", ES_AUTOHSCROLL | WS_TABSTOP, 16, y, 340, 24, IDC_APPS); y += 34;
            control(w, L"BUTTON", L"Write diagnostic log (includes what you type)", BS_AUTOCHECKBOX | WS_TABSTOP, 16, y, 340, 22, IDC_LOG); y += 38;
            control(w, L"BUTTON", L"Save", BS_DEFPUSHBUTTON | WS_TABSTOP, 176, y, 86, 28, IDC_SAVE);
            control(w, L"BUTTON", L"Cancel", BS_PUSHBUTTON | WS_TABSTOP, 270, y, 86, 28, IDC_CANCEL);
            fillSettings(w);
            return 0;
        }
        case WM_COMMAND:
            if (LOWORD(wp) == IDC_SAVE) { saveSettings(w); DestroyWindow(w); }
            else if (LOWORD(wp) == IDC_CANCEL || LOWORD(wp) == IDCANCEL) DestroyWindow(w);
            return 0;
        case WM_CTLCOLORSTATIC:
        case WM_CTLCOLORBTN:
            SetBkMode((HDC)wp, TRANSPARENT);
            return (LRESULT)GetSysColorBrush(COLOR_WINDOW);
        case WM_CLOSE: DestroyWindow(w); return 0;
        case WM_DESTROY: g_settings = nullptr; return 0;
    }
    return DefWindowProcW(w, msg, wp, lp);
}

static void showSettings() {
    if (g_settings) { SetForegroundWindow(g_settings); return; }
    if (!g_font) {
        NONCLIENTMETRICSW m{};
        m.cbSize = sizeof m;
        SystemParametersInfoW(SPI_GETNONCLIENTMETRICS, sizeof m, &m, 0);
        g_font = CreateFontIndirectW(&m.lfMessageFont);
    }
    RECT r{0, 0, dpiScale(376), dpiScale(566)};
    DWORD style = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX;
    AdjustWindowRect(&r, style, FALSE);
    int w = r.right - r.left, h = r.bottom - r.top;
    g_settings = CreateWindowExW(0, kSettingsClass, L"KBSwitch Settings", style,
                                 (GetSystemMetrics(SM_CXSCREEN) - w) / 2, (GetSystemMetrics(SM_CYSCREEN) - h) / 2, w, h,
                                 nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
    ShowWindow(g_settings, SW_SHOW);
    SetForegroundWindow(g_settings);
}

// ============================================================================================
// Message window and entry point
// ============================================================================================

static LRESULT CALLBACK mainProc(HWND w, UINT msg, WPARAM wp, LPARAM lp) {
    if (msg == g_taskbarCreated && g_taskbarCreated) { updateTray(true); return 0; }   // Explorer restarted
    switch (msg) {
        case WM_APP_TRAY:
            if (LOWORD(lp) == WM_RBUTTONUP || LOWORD(lp) == WM_LBUTTONUP) showMenu();
            return 0;
        case WM_APP_FIELD: g_engine.onFieldRead(reinterpret_cast<FieldRead*>(lp)); return 0;
        case WM_APP_SETTINGS: showSettings(); return 0;
        case WM_APP_QUIT: PostQuitMessage(0); return 0;
        case WM_TIMER: if (wp == kTimerCheck) g_engine.onTimeout(); return 0;
        case WM_INPUTLANGCHANGE:
        case WM_SETTINGCHANGE: g_layouts.reload(); return 0;
    }
    return DefWindowProcW(w, msg, wp, lp);
}

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE, PWSTR, int) {
    static Paths paths;
    g_paths = &paths;
    if (selfInstall()) return 0;

    HANDLE single = CreateMutexW(nullptr, TRUE, L"Local\\KBSwitch.SingleInstance");
    if (GetLastError() == ERROR_ALREADY_EXISTS) {        // already running: show its Settings
        HWND other = FindWindowW(kWindowClass, nullptr);
        if (other) PostMessageW(other, WM_APP_SETTINGS, 0, 0);
        return 0;
    }

    INITCOMMONCONTROLSEX icc{sizeof icc, ICC_STANDARD_CLASSES};
    InitCommonControlsEx(&icc);

    WNDCLASSW wc{};
    wc.lpfnWndProc = mainProc;
    wc.hInstance = inst;
    wc.lpszClassName = kWindowClass;
    RegisterClassW(&wc);
    WNDCLASSW sc{};
    sc.lpfnWndProc = settingsProc;
    sc.hInstance = inst;
    sc.lpszClassName = kSettingsClass;
    sc.hCursor = LoadCursor(nullptr, IDC_ARROW);
    sc.hbrBackground = GetSysColorBrush(COLOR_WINDOW);
    sc.hIcon = LoadIconW(inst, MAKEINTRESOURCEW(IDI_APP));
    RegisterClassW(&sc);

    // A hidden top-level window (not message-only) so it receives Explorer's broadcasts.
    g_engine.hwnd = CreateWindowExW(WS_EX_TOOLWINDOW, kWindowClass, L"KBSwitch", WS_POPUP, 0, 0, 0, 0, nullptr, nullptr, inst, nullptr);
    g_taskbarCreated = RegisterWindowMessageW(L"TaskbarCreated");

    bool firstRun = false;
    Config::load(&firstRun);
    if (firstRun) setStartWithWindows(true);         // start with Windows by default (toggle in Settings)
    g_layouts.reload();
    g_lexicon.load();
    g_engine.reloadConfig();
    g_reader.start(g_engine.hwnd);
    updateTray(true);
    if (firstRun || wcsstr(GetCommandLineW(), L"--installed")) {
        g_tray.uFlags = NIF_INFO;
        wcscpy_s(g_tray.szInfoTitle, L"KBSwitch is running");
        wcscpy_s(g_tray.szInfo, L"Type away: words typed in the wrong layout are fixed when you press Space. Settings: right-click the \u042fR icon.");
        g_tray.dwInfoFlags = NIIF_INFO;
        Shell_NotifyIconW(NIM_MODIFY, &g_tray);
    }

    g_keyboardHook = SetWindowsHookExW(WH_KEYBOARD_LL, keyboardProc, inst, 0);
    HWINEVENTHOOK fg = SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, nullptr, focusProc, 0, 0, WINEVENT_OUTOFCONTEXT);
    HWINEVENTHOOK focus = SetWinEventHook(EVENT_OBJECT_FOCUS, EVENT_OBJECT_FOCUS, nullptr, focusProc, 0, 0, WINEVENT_OUTOFCONTEXT);
    logLine(L"started");

    MSG msg;
    while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
        if (g_settings && IsDialogMessageW(g_settings, &msg)) continue;
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }

    UnhookWindowsHookEx(g_keyboardHook);
    UnhookWinEvent(fg);
    UnhookWinEvent(focus);
    Shell_NotifyIconW(NIM_DELETE, &g_tray);
    ReleaseMutex(single);
    return 0;
}
