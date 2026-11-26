# Typo-correction models (`en.kbm`, `uk.kbm`)

Built by `tools/build_model.py` from the sources below (download them with `tools/get_corpora.sh`).
The model files are derived data and are shared under **CC BY-SA 4.0**, as required by the
share-alike sources.

**Format.** `"KBM1"`, then three little-endian u32 (word count, pair count, start-of-sentence id).
Each word is stored as u8 `-ln P(word)·8`, a u8 "Hunspell knows it" flag, a u8 byte length and UTF-8 bytes,
most frequent first. Then the pair keys follow as sorted u64 `(prev id << 32) | word id`, and the u8
values `-ln P(word | prev)·8`.

**Sources**
- Word frequencies: [wordfreq](https://github.com/rspeer/wordfreq) 3.1.1 data, by Robyn Speer, under
  CC BY-SA 4.0. It is built from Wikipedia, subtitles, news, books, web text, Twitter and Reddit, which
  is why everyday slang is in it.
- Dictionary flags: [LibreOffice dictionaries](https://github.com/LibreOffice/dictionaries) en_US and uk_UA.
- English word pairs:
  - [UD English-EWT](https://github.com/UniversalDependencies/UD_English-EWT) train and dev, CC BY-SA 4.0
  - Google Books Ngram (v3) top 2-grams via
    [orgtre/google-books-ngram-frequency](https://github.com/orgtre/google-books-ngram-frequency), CC BY 3.0
- Ukrainian word pairs:
  - [UA-GEC](https://github.com/grammarly/ua-gec) 2.1 corrected texts, train split, CC BY 4.0, by Grammarly
  - [UD Ukrainian-ParlaMint](https://github.com/UniversalDependencies/UD_Ukrainian-ParlaMint) train and dev, CC BY-SA 4.0

**Evaluation.** The models are tested on held-out data: UA-GEC test split (real spelling errors), UD EWT
test split (clean text plus simulated typos), and a slang/names list.
