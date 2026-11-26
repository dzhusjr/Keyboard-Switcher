#!/bin/bash
# Downloads everything tools/build_model.py needs into ./corpora and ./dict (a few hundred MB).
# Then:  python3 tools/build_model.py corpora dict model
set -euo pipefail
mkdir -p corpora dict
pip install wordfreq==3.1.1
UD=https://raw.githubusercontent.com/UniversalDependencies
for s in train dev test; do
  curl -fsSL -o corpora/en_ewt-ud-$s.conllu $UD/UD_English-EWT/master/en_ewt-ud-$s.conllu
  curl -fsSL -o corpora/uk_parlamint-ud-$s.conllu $UD/UD_Ukrainian-ParlaMint/master/uk_parlamint-ud-$s.conllu
done
curl -fsSL -o corpora/2grams_english.csv https://raw.githubusercontent.com/orgtre/google-books-ngram-frequency/main/ngrams/2grams_english.csv
pip download ua-gec==2.1.3 --no-deps -d corpora
python3 -c "import zipfile,glob; zipfile.ZipFile(glob.glob('corpora/ua_gec-*.whl')[0]).extractall('corpora/uagec')"
DICT=https://raw.githubusercontent.com/LibreOffice/dictionaries/master
for f in en/en_US.aff en/en_US.dic uk_UA/uk_UA.aff uk_UA/uk_UA.dic; do curl -fsSL -o dict/$(basename $f) $DICT/$f; done
