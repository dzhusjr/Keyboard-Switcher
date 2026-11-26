// KBSwitch typo-correction engine. See kbcorrect.h for what it does.

#include "kbcorrect.h"

#include <algorithm>
#ifndef KB_E1
#define KB_E1 5
#endif
#ifndef KB_E3
#define KB_E3 99
#endif
#ifndef KB_E2
#define KB_E2 9
#endif
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <unordered_map>
#include <vector>

namespace {

using u32 = std::u32string;

// ---- tuning (log-probability units; see tools/eval_engine for how these were chosen) --------------

#ifndef KB_UNK
#define KB_UNK -19.0
#endif
const double kUnknownWord   = KB_UNK;  // log P of a word that isn't in the vocabulary
const double kBackoff       = -0.9;   // stupid backoff when a word pair was never seen
const double kRightWeight   = 0.7;    // how much the next word counts
#ifndef KB_MARGIN
#define KB_MARGIN 3.0
#endif
#ifndef KB_SEEN_MARGIN
#define KB_SEEN_MARGIN 6.0
#endif
const double kNonWordMargin = KB_MARGIN;  // a non-word is replaced if the winner is this far ahead of keeping it
const double kSeenWordMargin = KB_SEEN_MARGIN; // extra lead needed if the typed word occurs in real text
                                              // (a variant spelling - проєкт/проект - more often than a typo)
#ifndef KB_EXTRA
#define KB_EXTRA 1.0
#endif
const double kExtraEditMargin = KB_EXTRA;  // ... plus this much for every edit beyond the first
const double kAmbiguity     = 1.6;    // ... and only if the runner-up is this far behind
const double kCommonWord    = std::log(std::pow(10.0, 3.0 - 9));   // Zipf 3: common enough to suggest
                                                                    // without being in the dictionary (slang)
#ifndef KB_RW_RARE
#define KB_RW_RARE 2.5
#endif
#ifndef KB_RW_COMMON
#define KB_RW_COMMON 4.0
#endif
#ifndef KB_RW_MARGIN
#define KB_RW_MARGIN 4.0
#endif
const double kRareRealWord = std::log(std::pow(10.0, KB_RW_RARE - 9));     // a dictionary word rarer than this...
const double kCommonRealWord = std::log(std::pow(10.0, KB_RW_COMMON - 9)); // ...may become a word this common
const double kRealWordMargin = KB_RW_MARGIN;                               // ...if it wins by this much
#ifndef KB_AMB_FAR
#define KB_AMB_FAR 0.5
#endif
#ifndef KB_RARE
#define KB_RARE 2.0
#endif
const double kRareWord     = std::log(std::pow(10.0, KB_RARE - 9));  // rarer than this: seen in text, but likely a typo there too
const double kLearnedWord   = std::log(std::pow(10.0, 3.5 - 9));   // user's own words
#ifndef KB_SHRINK
#define KB_SHRINK 3.0
#endif
#ifndef KB_SPLIT_LEN
#define KB_SPLIT_LEN 1.5
#endif
#ifndef KB_SPACE
#define KB_SPACE 2.0
#endif
const double kMissedSpace = KB_SPACE;                              // two words typed without the Space
const double kSplitTiny  = std::log(std::pow(10.0, 5.5 - 9));     // a/i/в/і...: only very common ones
const double kSplitShort = std::log(std::pow(10.0, 4.5 - 9));     // 2-letter parts: common ones
const double kKeepBonus     = 1.0;    // typing what you meant is likelier than any particular slip
const double kNotInDictionary = 3.0;  // a word the dictionary doesn't know is often a frequent misspelling

// Typing costs (negative log-probabilities of the slip).
const double kSwap = 2.2, kNearKey = 2.6, kFarKey = 5.5, kDoubled = 1.6, kExtraNear = 3.2,
             kExtra = 4.2, kMissing = 4.0, kFirstLetter = 1.5;

// Spelling confusions that have nothing to do with the keyboard (sound / orthography), per language.
struct Confusion { char32_t a, b; double cost; };
const Confusion kUkrainianPairs[] = {
    {U'і', U'и', 2.0}, {U'и', U'і', 2.0}, {U'е', U'и', 2.4}, {U'и', U'е', 2.4}, {U'е', U'є', 2.0}, {U'є', U'е', 2.0},
    {U'і', U'ї', 2.0}, {U'ї', U'і', 2.0}, {U'г', U'ґ', 1.8}, {U'ґ', U'г', 1.8}, {U'ш', U'щ', 2.2}, {U'щ', U'ш', 2.2},
    {U'о', U'а', 3.0}, {U'а', U'о', 3.0}, {U'й', U'і', 2.6}, {U'і', U'й', 2.6},
    {U'а', U'я', 2.6}, {U'я', U'а', 2.6}, {U'у', U'ю', 2.6}, {U'ю', U'у', 2.6},
};
const Confusion kEnglishPairs[] = {
    {U'a', U'e', 3.0}, {U'e', U'a', 3.0}, {U'e', U'i', 3.0}, {U'i', U'e', 3.0}, {U'i', U'y', 3.0}, {U'y', U'i', 3.0},
    {U'o', U'u', 3.4}, {U'u', U'o', 3.4}, {U'a', U'o', 3.4}, {U'o', U'a', 3.4}, {U'c', U's', 3.2}, {U's', U'c', 3.2},
};
const double kSoftSign = 1.8;      // ь added or left out (Ukrainian)
const double kApostrophe = 1.5;    // ' left out or added

u32 decode(const char* s) {
    u32 out;
    if (!s) return out;
    const unsigned char* p = (const unsigned char*)s;
    while (*p) {
        char32_t c;
        if (*p < 0x80) c = *p++;
        else if ((*p >> 5) == 6 && p[1]) { c = ((p[0] & 0x1F) << 6) | (p[1] & 0x3F); p += 2; }
        else if ((*p >> 4) == 14 && p[1] && p[2]) { c = ((p[0] & 0x0F) << 12) | ((p[1] & 0x3F) << 6) | (p[2] & 0x3F); p += 3; }
        else if ((*p >> 3) == 30 && p[1] && p[2] && p[3]) {
            c = ((p[0] & 0x07) << 18) | ((p[1] & 0x3F) << 12) | ((p[2] & 0x3F) << 6) | (p[3] & 0x3F); p += 4;
        } else { p++; continue; }
        out += c;
    }
    return out;
}

std::string encode(const u32& s) {
    std::string out;
    for (char32_t c : s) {
        if (c < 0x80) out += (char)c;
        else if (c < 0x800) { out += (char)(0xC0 | (c >> 6)); out += (char)(0x80 | (c & 0x3F)); }
        else if (c < 0x10000) { out += (char)(0xE0 | (c >> 12)); out += (char)(0x80 | ((c >> 6) & 0x3F)); out += (char)(0x80 | (c & 0x3F)); }
        else { out += (char)(0xF0 | (c >> 18)); out += (char)(0x80 | ((c >> 12) & 0x3F)); out += (char)(0x80 | ((c >> 6) & 0x3F)); out += (char)(0x80 | (c & 0x3F)); }
    }
    return out;
}

struct Node {                 // 12 bytes; letters are all in the Basic Multilingual Plane
    uint32_t first = 0;       // index of first child
    int32_t word = -1;        // vocabulary id if a word ends here
    uint16_t count = 0;       // number of children (contiguous, sorted by letter)
    char16_t ch = 0;
};

struct Candidate { int id; u32 text; };

}  // namespace

struct KBModel {
    std::vector<float> uni;          // ln P(word)
    std::vector<uint8_t> known;      // Hunspell knows it
    std::vector<uint64_t> pairKeys;  // (prev << 32) | word, sorted
    std::vector<uint8_t> pairVals;   // -ln P(word | prev) * 8
    uint32_t startId = 0;
    std::vector<Node> nodes;
    std::vector<u32> learned;
    std::unordered_map<char32_t, std::pair<int, int>> keys;
    std::unordered_map<uint64_t, double> confusions;    // (typed << 32 | meant) -> cost
    bool ukrainian = false;
    int budget = 20000;
};

namespace {

// ---- loading ----------------------------------------------------------------------------------

bool readAll(FILE* f, std::vector<uint8_t>& data) {
    if (!f) return false;
    uint8_t buf[1 << 16];
    size_t n;
    while ((n = fread(buf, 1, sizeof buf, f)) > 0) data.insert(data.end(), buf, buf + n);
    fclose(f);
    return true;
}

/// Builds the letter tree from all words (flat UTF-16 letters + offsets), then the letters are freed.
void buildTrie(KBModel* m, const std::vector<char16_t>& letters, const std::vector<uint32_t>& offset) {
    size_t n = offset.size() - 1;
    auto len = [&](uint32_t w) { return offset[w + 1] - offset[w]; };
    auto at = [&](uint32_t w, size_t d) { return letters[offset[w] + d]; };
    std::vector<uint32_t> order(n);
    for (size_t i = 0; i < n; i++) order[i] = (uint32_t)i;
    std::sort(order.begin(), order.end(), [&](uint32_t a, uint32_t b) {
        return std::lexicographical_compare(letters.begin() + offset[a], letters.begin() + offset[a + 1],
                                            letters.begin() + offset[b], letters.begin() + offset[b + 1]);
    });
    m->nodes.clear();
    m->nodes.emplace_back();
    struct Job { uint32_t node; size_t lo, hi, depth; };
    std::vector<Job> queue{{0, 0, n, 0}};
    for (size_t q = 0; q < queue.size(); q++) {
        Job j = queue[q];
        size_t i = j.lo;
        while (i < j.hi && len(order[i]) == j.depth) { m->nodes[j.node].word = (int32_t)order[i]; i++; }
        uint32_t first = (uint32_t)m->nodes.size(), count = 0;
        while (i < j.hi) {
            char16_t c = at(order[i], j.depth);
            size_t k = i;
            while (k < j.hi && at(order[k], j.depth) == c) k++;
            Node node;
            node.ch = c;
            m->nodes.push_back(node);
            queue.push_back({first + count, i, k, j.depth + 1});
            count++;
            i = k;
        }
        m->nodes[j.node].first = first;
        m->nodes[j.node].count = (uint16_t)count;
        if (q > 4096 && q * 2 > queue.size()) {          // keep the queue small
            queue.erase(queue.begin(), queue.begin() + q + 1);
            q = (size_t)-1;
        }
    }
    m->nodes.shrink_to_fit();
}

KBModel* parse(const std::vector<uint8_t>& d) {
    if (d.size() < 16 || memcmp(d.data(), "KBM1", 4) != 0) return nullptr;
    auto u32le = [&](size_t o) { return (uint32_t)d[o] | ((uint32_t)d[o + 1] << 8) | ((uint32_t)d[o + 2] << 16) | ((uint32_t)d[o + 3] << 24); };
    uint32_t nWords = u32le(4), nPairs = u32le(8);
    KBModel* m = new KBModel();
    m->startId = u32le(12);
    size_t o = 16;
    std::vector<char16_t> letters;
    std::vector<uint32_t> offset{0};
    letters.reserve((size_t)nWords * 9);
    offset.reserve(nWords + 1);
    m->uni.reserve(nWords);
    m->known.reserve(nWords);
    for (uint32_t i = 0; i < nWords; i++) {
        if (o + 3 > d.size()) { delete m; return nullptr; }
        uint8_t q = d[o], k = d[o + 1], len = d[o + 2];
        o += 3;
        if (o + len > d.size()) { delete m; return nullptr; }
        std::string w((const char*)&d[o], len);
        o += len;
        for (char32_t c : decode(w.c_str())) letters.push_back((char16_t)c);
        offset.push_back((uint32_t)letters.size());
        m->uni.push_back(-q / 8.0f);
        m->known.push_back(k);
        if (i < 100 && !w.empty() && (unsigned char)w[0] >= 0xD0) m->ukrainian = true;   // Cyrillic
    }
    if (o + (size_t)nPairs * 9 > d.size()) { delete m; return nullptr; }
    m->pairKeys.resize(nPairs);
    for (uint32_t i = 0; i < nPairs; i++) {
        uint64_t v = 0;
        for (int b = 7; b >= 0; b--) v = (v << 8) | d[o + i * 8 + b];
        m->pairKeys[i] = v;
    }
    o += (size_t)nPairs * 8;
    m->pairVals.assign(d.begin() + o, d.begin() + o + nPairs);
    buildTrie(m, letters, offset);
    if (m->ukrainian) for (const Confusion& c : kUkrainianPairs) m->confusions[((uint64_t)c.a << 32) | c.b] = c.cost;
    else for (const Confusion& c : kEnglishPairs) m->confusions[((uint64_t)c.a << 32) | c.b] = c.cost;
    return m;
}

// ---- model lookups ----------------------------------------------------------------------------

int findWord(const KBModel* m, const u32& w) {
    uint32_t n = 0;
    for (char32_t c : w) {
        const Node& node = m->nodes[n];
        uint32_t lo = node.first, hi = node.first + node.count;
        while (lo < hi) {
            uint32_t mid = (lo + hi) / 2;
            if ((char32_t)m->nodes[mid].ch < c) lo = mid + 1; else hi = mid;
        }
        if (lo == node.first + node.count || (char32_t)m->nodes[lo].ch != c) return -1;
        n = lo;
    }
    return m->nodes[n].word;
}

bool isLearned(const KBModel* m, const u32& w) {
    return std::find(m->learned.begin(), m->learned.end(), w) != m->learned.end();
}

double unigram(const KBModel* m, int id, const u32& w) {
    if (id >= 0) return m->uni[id];
    return isLearned(m, w) ? kLearnedWord : kUnknownWord;
}

/// ln P(w | prev) with stupid backoff; prev < 0 means "no context".
double conditional(const KBModel* m, int prev, int id, const u32& w) {
    double u = unigram(m, id, w);
    if (prev < 0 || id < 0) return u;
    uint64_t key = ((uint64_t)prev << 32) | (uint32_t)id;
    auto it = std::lower_bound(m->pairKeys.begin(), m->pairKeys.end(), key);
    if (it != m->pairKeys.end() && *it == key) return -m->pairVals[it - m->pairKeys.begin()] / 8.0;
    return kBackoff + u;
}

bool suggestable(const KBModel* m, int id) { return m->known[id] || m->uni[id] >= kCommonWord; }
// Only the dictionary (or the user) can vouch for a word: frequency lists also contain frequent
// misspellings (teh, untill, recieve), so other words just compete with their own frequency.
bool trusted(const KBModel* m, int id) { return m->known[id] != 0; }

bool near(const KBModel* m, char32_t a, char32_t b) {
    auto pa = m->keys.find(a), pb = m->keys.find(b);
    if (pa == m->keys.end() || pb == m->keys.end()) return false;
    int ra = pa->second.first, ca = pa->second.second, rb = pb->second.first, cb = pb->second.second;
    switch (rb - ra) {
        case 0: return std::abs(cb - ca) == 1;
        case -1: return cb == ca || cb == ca + 1;
        case 1: return cb == ca || cb == ca - 1;
        default: return false;
    }
}

/// Cost (negative log-probability) of typing `t` when `c` was meant: weighted Damerau-Levenshtein.
double typingCost(const KBModel* m, const u32& t, const u32& c) {
    size_t n = t.size(), k = c.size();
    std::vector<std::vector<double>> d(n + 1, std::vector<double>(k + 1, 1e9));
    d[0][0] = 0;
    for (size_t i = 0; i <= n; i++) {
        for (size_t j = 0; j <= k; j++) {
            double here = d[i][j];
            if (here >= 1e9) continue;
            double first = (i == 0 || j == 0) ? kFirstLetter : 0;
            if (i < n && j < k) {                                   // same or substituted letter
                double s = 0;
                if (t[i] != c[j]) {
                    auto conf = m->confusions.find(((uint64_t)t[i] << 32) | c[j]);
                    s = near(m, c[j], t[i]) ? kNearKey : kFarKey;
                    if (conf != m->confusions.end()) s = std::min(s, conf->second);
                    s += first;
                }
                d[i + 1][j + 1] = std::min(d[i + 1][j + 1], here + s);
            }
            if (i + 1 < n && j + 1 < k && t[i] == c[j + 1] && t[i + 1] == c[j] && t[i] != t[i + 1])
                d[i + 2][j + 2] = std::min(d[i + 2][j + 2], here + kSwap + first);   // swapped
            if (i < n) {                                            // extra letter typed
                bool doubled = (i > 0 && t[i] == t[i - 1]) || (i + 1 < n && t[i] == t[i + 1]);
                bool nearby = (j > 0 && near(m, t[i], c[j - 1])) || (j < k && near(m, t[i], c[j]));
                double cost = doubled ? kDoubled : nearby ? kExtraNear : kExtra;
                if (t[i] == U'\'') cost = std::min(cost, kApostrophe);
                if (m->ukrainian && t[i] == U'ь') cost = std::min(cost, kSoftSign);
                d[i + 1][j] = std::min(d[i + 1][j], here + cost + first);
            }
            if (j < k) {                                            // letter left out
                bool doubled = (j > 0 && c[j] == c[j - 1]) || (j + 1 < k && c[j] == c[j + 1]);
                double cost = doubled ? kDoubled : kMissing;
                if (c[j] == U'\'') cost = std::min(cost, kApostrophe);
                if (m->ukrainian && c[j] == U'ь') cost = std::min(cost, kSoftSign);
                d[i][j + 1] = std::min(d[i][j + 1], here + cost + first);
            }
        }
    }
    return d[n][k];
}

/// Words within `maxEdits` (Damerau-Levenshtein, unweighted) of `w`, via the letter tree.
void search(const KBModel* m, const u32& w, int maxEdits, std::vector<Candidate>& out) {
    size_t n = w.size();
    struct Frame { uint32_t node; size_t depth; };
    std::vector<std::vector<int>> rows(1, std::vector<int>(n + 1));
    for (size_t i = 0; i <= n; i++) rows[0][i] = (int)i;
    u32 prefix;
    int visited = 0;
    // Iterative depth-first search with one DP row per depth.
    std::vector<std::pair<uint32_t, uint32_t>> stack;   // (node, next child offset)
    stack.push_back({0, 0});
    while (!stack.empty()) {
        if (++visited > m->budget * 8) return;
        auto& top = stack.back();
        const Node& parent = m->nodes[top.first];
        if (top.second >= parent.count) {
            stack.pop_back();
            if (!prefix.empty()) { prefix.pop_back(); rows.pop_back(); }
            continue;
        }
        uint32_t child = parent.first + top.second++;
        const Node& node = m->nodes[child];
        size_t depth = prefix.size() + 1;
        const std::vector<int>& prev = rows.back();
        std::vector<int> row(n + 1);
        row[0] = (int)depth;
        int best = row[0];
        for (size_t i = 1; i <= n; i++) {
            int v = std::min({prev[i] + 1, row[i - 1] + 1, prev[i - 1] + (w[i - 1] != node.ch)});
            if (depth > 1 && i > 1 && w[i - 1] == prefix.back() && w[i - 2] == node.ch)
                v = std::min(v, rows[rows.size() - 2][i - 2] + 1);
            row[i] = v;
            best = std::min(best, v);
        }
        if (best > maxEdits) continue;
        prefix.push_back(node.ch);
        rows.push_back(row);
        if (node.word >= 0 && row[n] <= maxEdits && suggestable(m, node.word))
            out.push_back({node.word, prefix});
        stack.push_back({child, 0});
    }
}

/// Unweighted Damerau-Levenshtein (for the user's learned words).
int distance(const u32& a, const u32& b) {
    size_t n = a.size(), k = b.size();
    std::vector<std::vector<int>> d(n + 1, std::vector<int>(k + 1));
    for (size_t i = 0; i <= n; i++) d[i][0] = (int)i;
    for (size_t j = 0; j <= k; j++) d[0][j] = (int)j;
    for (size_t i = 1; i <= n; i++)
        for (size_t j = 1; j <= k; j++) {
            d[i][j] = std::min({d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (a[i - 1] != b[j - 1])});
            if (i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1]) d[i][j] = std::min(d[i][j], d[i - 2][j - 2] + 1);
        }
    return d[n][k];
}

/// Ukrainian spelling variants that are both correct (проєкт / проект, ґ / г, -ся / -сь): never "fixed".
u32 orthographyKey(u32 w) {
    for (char32_t& c : w) { if (c == U'є') c = U'е'; else if (c == U'ґ') c = U'г'; }
    if (w.size() > 2 && w[w.size() - 2] == U'с' && w.back() == U'я') w.back() = U'ь';
    return w;
}

bool isSubsequence(const u32& a, const u32& b) {
    size_t i = 0;
    for (char32_t c : b) if (i < a.size() && a[i] == c) i++;
    return i == a.size();
}

#ifndef KB_SKIP_MIN
#define KB_SKIP_MIN 4
#endif
int maxEditsFor(size_t len) { return len <= KB_E1 ? 1 : len <= KB_E2 ? 2 : len <= KB_E3 ? 3 : 4; }
#ifndef KB_E2
#endif

}  // namespace

// ---- C API ------------------------------------------------------------------------------------

extern "C" {

KBModel* kb_load(const char* path) {
    std::vector<uint8_t> data;
    if (!readAll(fopen(path, "rb"), data)) return nullptr;
    return parse(data);
}

#ifdef _WIN32
KBModel* kb_load_w(const wchar_t* path) {
    std::vector<uint8_t> data;
    if (!readAll(_wfopen(path, L"rb"), data)) return nullptr;
    return parse(data);
}
#endif

void kb_free(KBModel* m) { delete m; }

void kb_set_key(KBModel* m, unsigned int codepoint, int row, int col) {
    if (m) m->keys[(char32_t)codepoint] = {row, col};
}

void kb_learn(KBModel* m, const char* word) {
    if (!m) return;
    u32 w = decode(word);
    if (!w.empty() && !isLearned(m, w)) m->learned.push_back(w);
}

int kb_knows(KBModel* m, const char* word) {
    if (!m) return 0;
    u32 w = decode(word);
    int id = findWord(m, w);
    return (id >= 0 && trusted(m, id)) || isLearned(m, w);
}

void kb_set_budget(KBModel* m, int candidates) { if (m && candidates > 0) m->budget = candidates; }

double kb_reading(KBModel* m, const char* typedUtf8, const char* prevUtf8) {
    if (!m || !typedUtf8) return -1e9;
    u32 typed = decode(typedUtf8);
    if (typed.empty()) return -1e9;
    int prev = -1;
    if (prevUtf8) prev = prevUtf8[0] ? findWord(m, decode(prevUtf8)) : (int)m->startId;
    int typedId = findWord(m, typed);
    double best = -1e9;
    if ((typedId >= 0 && (trusted(m, typedId) || m->uni[typedId] >= kCommonWord)) || isLearned(m, typed))
        best = conditional(m, prev, typedId, typed);
    if (typed.size() < 3) return best;
    std::vector<Candidate> cands;
    search(m, typed, std::min(2, maxEditsFor(typed.size())), cands);
    int looked = 0;
    for (const Candidate& c : cands) {
        if (c.text == typed || c.text.size() < 3) continue;
        if (++looked > m->budget) break;
        best = std::max(best, conditional(m, prev, c.id, c.text) - typingCost(m, typed, c.text));
    }
    return best;
}

int kb_correct(KBModel* m, const char* typedUtf8, const char* prevUtf8, const char* nextUtf8, int typedValid,
               char* out, int outSize, double* margin) {
    if (margin) *margin = 0;
    if (!m || !typedUtf8 || !out || outSize <= 0) return 0;
    u32 typed = decode(typedUtf8);
    if (typed.size() < 3 || isLearned(m, typed)) return 0;

    int typedId = findWord(m, typed);
    // A dictionary word is normally never changed: "fixing" real words (form -> from) changes more
    // correct text than it fixes. The exception is a rare word (лата, kike) one slip away from a
    // very common one (дата, like): the common word is almost always what was meant.
    bool realWord = typedValid || (typedId >= 0 && trusted(m, typedId));
    if (realWord && typedId >= 0 && m->uni[typedId] >= kRareRealWord) return 0;
    int prev = -1;
    if (prevUtf8) prev = prevUtf8[0] ? findWord(m, decode(prevUtf8)) : (int)m->startId;
    u32 next = decode(nextUtf8);
    int nextId = next.empty() ? -1 : findWord(m, next);

    auto score = [&](int id, const u32& w) {
        double s = conditional(m, prev, id, w);
        if (nextId >= 0) s += kRightWeight * (conditional(m, id, nextId, next) - m->uni[nextId]);
        return s;
    };
    // Leaving the word as typed: frequent non-dictionary words (slang: thx, лол, норм) keep their
    // weight; rare ones are often misspellings.
    bool common = realWord || (typedId >= 0 && m->uni[typedId] >= kCommonWord);
    double keep = score(typedId, typed) + kKeepBonus - (common ? 0 : kNotInDictionary);

    std::vector<Candidate> cands;
    // Short words: one slip, or two letters left out (звзок -> зв'язок).
    bool shortWord = (int)maxEditsFor(typed.size()) == 1 && typed.size() >= KB_SKIP_MIN;
    search(m, typed, realWord ? 1 : shortWord ? 2 : maxEditsFor(typed.size()), cands);
    for (const u32& l : m->learned)
        if (distance(typed, l) <= maxEditsFor(typed.size())) cands.push_back({-1, l});

    double best = -1e18, second = -1e18;
    u32 winner, runnerUp;
    int looked = 0;
    for (const Candidate& c : cands) {
        if (c.text == typed || c.text.size() < 3) continue;          // never "fix" into a tiny word
        if (typed.size() == 3) {                                       // 3 letters: swapped letters only (teh)
            u32 a = typed, b = c.text;
            std::sort(a.begin(), a.end()); std::sort(b.begin(), b.end());
            if (a != b || distance(typed, c.text) != 1) continue;
        }
        if (shortWord && c.text.size() != typed.size() + 2 && distance(typed, c.text) > 1) continue;
        if (shortWord && c.text.size() == typed.size() + 2 && !isSubsequence(typed, c.text)) continue;
        if (realWord && (c.id < 0 || m->uni[c.id] < kCommonRealWord || distance(typed, c.text) != 1)) continue;
        if (++looked > m->budget) return 0;
        double s = score(c.id, c.text) - typingCost(m, typed, c.text);
        // Typing two or more letters too many is rarer than each extra letter alone suggests
        // (bwteen is between, not been).
        if (typed.size() >= c.text.size() + 2) s -= KB_SHRINK * (typed.size() - c.text.size() - 1);
        if (s > best) { second = best; runnerUp = winner; best = s; winner = c.text; }
        else if (s > second) { second = s; runnerUp = c.text; }
    }
    // A missed Space: two common dictionary words run together (andthe -> and the).
    if (!realWord && typed.size() >= 4) {
        auto part = [&](const u32& w) {
            int id = findWord(m, w);
            if (id < 0 || !trusted(m, id)) return -1;
            double need = w.size() == 1 ? kSplitTiny : w.size() == 2 ? kSplitShort : kCommonWord;
            return m->uni[id] >= need ? id : -1;
        };
        for (size_t i = 1; i < typed.size(); i++) {
            u32 a = typed.substr(0, i), b = typed.substr(i);
            if (a.back() == U'\'' || b.front() == U'\'' || b.front() == U'-' || a.back() == U'-') continue;
            int ia = part(a), ib = part(b);
            if (ia < 0 || ib < 0) continue;
            // One long unknown string is less likely than an unknown short one: the longer the run,
            // the more two real words explain it.
            double s = conditional(m, prev, ia, a) + conditional(m, ia, ib, b) - kMissedSpace +
                       KB_SPLIT_LEN * std::max(0, (int)typed.size() - 6);
            if (nextId >= 0) s += kRightWeight * (conditional(m, ib, nextId, next) - m->uni[nextId]);
            u32 text = a + U" " + b;
            if (s > best) { second = best; runnerUp = winner; best = s; winner = text; }
            else if (s > second) { second = s; runnerUp = text; }
        }
    }
    if (winner.empty()) return 0;
    if (m->ukrainian && orthographyKey(winner) == orthographyKey(typed)) return 0;
    double lead = best - keep;
    if (margin) *margin = lead;
    bool split = winner.find(U' ') != u32::npos;
    double needed = split ? kNonWordMargin + (typedId >= 0 ? kSeenWordMargin / 2 : 0) : realWord ? kRealWordMargin : kNonWordMargin + kExtraEditMargin * (distance(typed, winner) - 1) + (typedId < 0 ? 0 : m->uni[typedId] >= kRareWord ? kSeenWordMargin : kSeenWordMargin / 2);
    if (lead < needed) return 0;
    // Too close to call - unless the runner-up needs more edits than the winner (mistakess: mistakes
    // vs mistake), where the nearer word is the safer reading.
    if (best - second < kAmbiguity && (runnerUp.empty() || distance(typed, runnerUp) <= distance(typed, winner) ||
                                       best - second < KB_AMB_FAR)) return 0;

    std::string s = encode(winner);
    if ((int)s.size() + 1 > outSize) return 0;
    memcpy(out, s.c_str(), s.size() + 1);
    return 1;
}

}  // extern "C"
