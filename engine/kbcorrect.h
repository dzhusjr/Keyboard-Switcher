/* KBSwitch typo-correction engine: shared by the macOS (Swift) and Windows (C++) apps.
 *
 * A noisy-channel corrector: for a typed word it finds dictionary words within a few edits
 * (letter-tree search, Damerau-Levenshtein), scores each as
 *     log P(word | previous word) + log P(next word | word) - typing cost(typed -> word)
 * where the typing cost knows the keyboard (neighbouring keys, swapped and doubled letters), and
 * corrects only when the best word clearly beats both leaving the word alone and the runner-up.
 * Models are built by tools/build_model.py. All strings are UTF-8. Not thread-safe per model.
 */
#ifndef KBCORRECT_H
#define KBCORRECT_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct KBModel KBModel;

/** Loads a .kbm model (UTF-8 path), or returns NULL. */
KBModel* kb_load(const char* path);
#ifdef _WIN32
#include <wchar.h>
KBModel* kb_load_w(const wchar_t* path);
#endif
void kb_free(KBModel* m);

/** Tells the engine where a letter sits on the keyboard (row 0-2, column), for typing costs. */
void kb_set_key(KBModel* m, unsigned int codepoint, int row, int col);

/** A word the user writes on purpose (slang, names): never corrected, may be suggested. */
void kb_learn(KBModel* m, const char* word);

/** 1 if the word is a known word (vocabulary word that is in the dictionary or common, or learned). */
int kb_knows(KBModel* m, const char* word);

/** Number of times kb_correct may look at candidates before giving up (speed cap); default 20000. */
void kb_set_budget(KBModel* m, int candidates);

/**
 * Corrects one lowercase word. prev / next: the neighbouring words (lowercase) or NULL; prev may be
 * "" for "start of a sentence". typed_valid: the caller knows the typed word is a real word
 * (another dictionary, the user's exceptions); then it is only replaced on strong context evidence.
 * Returns 1 and writes the correction (NUL-terminated) to out when confident, otherwise 0.
 * margin (optional) receives how far the winner was ahead (log-probability units).
 */
int kb_correct(KBModel* m, const char* typed, const char* prev, const char* next, int typed_valid,
               char* out, int out_size, double* margin);

/**
 * How plausible `typed` is as something meant in this language: the log-probability of the word
 * itself (given prev) if it's a word, or of its best correction minus the cost of the typing slip.
 * Used to choose between "typed in the wrong layout" and "a typo in this language". Very negative
 * (about -1e9) if there's no reading at all.
 */
double kb_reading(KBModel* m, const char* typed, const char* prev);

#ifdef __cplusplus
}
#endif

#endif
