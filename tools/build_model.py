#!/usr/bin/env python3
"""Builds the typo-correction language models (model/en.kbm, model/uk.kbm).

Each model holds, for one language:
  - a vocabulary: words with a unigram log-probability (from wordfreq) and a flag saying whether
    Hunspell knows the word;
  - bigram log-probabilities P(word | previous word) for context, counted from open corpora.

Sources (all allow redistribution; see model/SOURCES.md):
  wordfreq 3.1 data (CC BY-SA 4.0), Hunspell en_US / uk_UA (LibreOffice),
  English: UD English-EWT (CC BY-SA 4.0), Google Books Ngram top 2-grams via orgtre (CC BY 3.0),
  Ukrainian: UA-GEC 2.1 corrected texts, train split (CC BY 4.0), UD Ukrainian-ParlaMint (CC BY-SA 4.0).

Usage: python3 tools/build_model.py <corpora dir> <hunspell dict dir> <output dir>
Needs: pip install wordfreq; the `hunspell` command; the corpora downloaded as in tools/get_corpora.sh.
"""
import collections, csv, glob, math, os, re, struct, subprocess, sys

ALPHABET = {
    "en": "abcdefghijklmnopqrstuvwxyz'",
    "uk": "абвгґдеєжзиіїйклмнопрстуфхцчшщьюя'",
}
MIN_ZIPF = 1.0            # vocabulary cut-off (Zipf frequency); rare words are only suggested if Hunspell knows them
GOOGLE_TOKENS = 2.838e11  # English Google Books 2010-2019 tokens (orgtre README)
START = "<s>"

def plain(word, lang):
    a = ALPHABET[lang]
    return bool(word) and all(c in a for c in word) and word[0] != "'" and word[-1] != "'"

def normalize(text):
    return text.replace("’", "'").replace("ʼ", "'").replace("`", "'").lower()

TOKEN = re.compile(r"[^\W\d_]+(?:'[^\W\d_]+)*", re.UNICODE)
SENTENCE = re.compile(r"[.!?\n…]+")

def sentences(text):
    for s in SENTENCE.split(normalize(text)):
        toks = TOKEN.findall(s)
        if toks:
            yield toks

def conllu_texts(path):
    with open(path, encoding="utf-8") as f:
        for line in f:
            if line.startswith("# text = "):
                yield line[9:].strip()

def hunspell_known(words, dic):
    bad = set()
    chunk = 20000
    for i in range(0, len(words), chunk):
        out = subprocess.run(["hunspell", "-i", "UTF-8", "-d", dic, "-l"], input="\n".join(words[i:i + chunk]),
                             capture_output=True, text=True, check=True).stdout
        bad.update(out.split())
    return {w for w in words if w not in bad}

def quantize(logp):
    return max(0, min(255, round(-logp * 8)))   # stored as -ln(p) * 8

def build(lang, corpora, dicts, out):
    import wordfreq
    freq = wordfreq.get_frequency_dict(lang, "large")
    vocab = [(w, p) for w, p in freq.items() if plain(w, lang) and p >= 10 ** (MIN_ZIPF - 9)]
    vocab.sort(key=lambda x: -x[1])
    words = [w for w, _ in vocab]
    index = {w: i for i, w in enumerate(words)}
    known = hunspell_known(words, os.path.join(dicts, "en_US" if lang == "en" else "uk_UA"))
    print(f"{lang}: {len(words)} words, {len(known)} known to Hunspell")

    # --- bigram counts from corpora ---
    if lang == "en":
        texts = [t for f in sorted(glob.glob(os.path.join(corpora, "en_ewt-ud-*.conllu"))) if "test" not in f
                 for t in conllu_texts(f)]
    else:
        texts = [t for f in sorted(glob.glob(os.path.join(corpora, "uk_parlamint-ud-*.conllu"))) if "test" not in f
                 for t in conllu_texts(f)]
        for f in glob.glob(os.path.join(corpora, "uagec/ua_gec/data/gec-fluency/train/target/*.txt")):
            texts.append(open(f, encoding="utf-8").read())
    uni = collections.Counter()
    bi = collections.Counter()
    tokens = 0
    for t in texts:
        for toks in sentences(t):
            prev = START
            uni[START] += 1
            for w in toks:
                tokens += 1
                uni[w] += 1
                bi[(prev, w)] += 1
                prev = w
    print(f"{lang}: corpus {tokens} tokens, {len(bi)} distinct bigrams")

    START_ID = len(words)                      # id used for "start of sentence"
    def wid(w):
        return START_ID if w == START else index.get(w)

    probs = {}
    for (a, b), c in bi.items():
        if c < 2:
            continue
        ia, ib = wid(a), wid(b)
        if ia is None or ib is None or ib == START_ID:
            continue
        probs[(ia, ib)] = math.log((c - 0.5) / uni[a])          # absolutely discounted estimate
    if lang == "en":
        p_of = dict(vocab)
        with open(os.path.join(corpora, "2grams_english.csv"), encoding="utf-8") as f:
            for row in csv.DictReader(f):
                parts = normalize(row["ngram"]).split()
                if len(parts) != 2 or parts[0] not in index or parts[1] not in index:
                    continue
                p = int(row["freq"]) / (p_of[parts[0]] * GOOGLE_TOKENS)
                if 0 < p < 1:
                    probs[(index[parts[0]], index[parts[1]])] = math.log(p)   # much larger sample: wins
    print(f"{lang}: {len(probs)} bigrams kept")

    # --- write ---
    os.makedirs(out, exist_ok=True)
    path = os.path.join(out, f"{lang}.kbm")
    keys = sorted(probs)
    with open(path, "wb") as f:
        f.write(b"KBM1")
        f.write(struct.pack("<III", len(words), len(keys), START_ID))
        for w, p in vocab:
            b = w.encode("utf-8")
            f.write(struct.pack("<BBB", quantize(math.log(p)), 1 if w in known else 0, len(b)))
            f.write(b)
        for k in keys:
            f.write(struct.pack("<Q", (k[0] << 32) | k[1]))
        f.write(bytes(quantize(probs[k]) for k in keys))
    print(f"{lang}: wrote {path} ({os.path.getsize(path) / 1e6:.1f} MB)")

if __name__ == "__main__":
    corpora, dicts, out = sys.argv[1:4]
    for lang in ("en", "uk"):
        build(lang, corpora, dicts, out)
