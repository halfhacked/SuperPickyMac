#!/usr/bin/env python3
# Backfills `pinyin_initials` on a committed bird_reference.sqlite whose
# `pinyin` column is already populated (no-spaces form) but whose initials
# column is missing or NULL. Used for one-time migration when the ioc
# source db (~/projects/superpicky/ioc/birdname.db) is not available.
#
# Primary path: greedy/DP tokenization of the IOC concatenated `pinyin`
# string into Mandarin syllables, taking the first letter of each. This
# stays consistent with the existing `pinyin` column (so initials search
# agrees with full-pinyin search even when IOC has idiosyncratic
# romanizations).
#
# Fallback: for rows whose IOC pinyin can't be tokenized, derive initials
# from `chinese_simplified` via pypinyin (Style.FIRST_LETTER).
#
# The canonical tool is build_species_db_add_pinyin.py; prefer that when
# the ioc source is available. This script exists so the committed
# sqlite can be brought up to date without ioc access.

import argparse
import os
import sqlite3
import sys
import unicodedata

try:
    from pypinyin import lazy_pinyin, pinyin_dict, Style
except ImportError:
    print("pypinyin is required: pip install pypinyin", file=sys.stderr)
    sys.exit(1)


def build_syllable_set() -> set[str]:
    """Valid Mandarin syllables (no tone), including both `u` and `v` for ü."""
    out: set[str] = set()
    for _cp, readings in pinyin_dict.pinyin_dict.items():
        for raw in readings.split(","):
            stripped = "".join(
                ch for ch in unicodedata.normalize("NFD", raw.strip())
                if unicodedata.category(ch) != "Mn"
            ).lower()
            if not stripped or not all(c.isalpha() for c in stripped):
                continue
            out.add(stripped.replace("ü", "u"))
            out.add(stripped.replace("ü", "v"))
    return out


def tokenize(pinyin: str, syllables: set[str], expected: int | None) -> list[str] | None:
    """Split concatenated pinyin into syllables. When `expected` is given,
    prefer a split with exactly that many tokens (aligns with Chinese char
    count); otherwise any full tokenization wins."""
    L = len(pinyin)
    if expected is None:
        dp = [False] * (L + 1)
        back = [0] * (L + 1)
        dp[0] = True
        for i in range(1, L + 1):
            for j in range(max(0, i - 6), i):
                if dp[j] and pinyin[j:i] in syllables:
                    dp[i] = True
                    back[i] = j
                    break
        if not dp[L]:
            return None
        out = []
        i = L
        while i > 0:
            out.append(pinyin[back[i]:i])
            i = back[i]
        return list(reversed(out))

    dp = [[False] * (expected + 1) for _ in range(L + 1)]
    back = [[0] * (expected + 1) for _ in range(L + 1)]
    dp[0][0] = True
    for i in range(1, L + 1):
        for k in range(1, expected + 1):
            for j in range(max(0, i - 6), i):
                if dp[j][k - 1] and pinyin[j:i] in syllables:
                    dp[i][k] = True
                    back[i][k] = j
                    break
    if dp[L][expected]:
        out, i, k = [], L, expected
        while k > 0:
            j = back[i][k]
            out.append(pinyin[j:i])
            i, k = j, k - 1
        return list(reversed(out))
    return tokenize(pinyin, syllables, expected=None)


def cjk_count(text: str) -> int:
    def is_cjk(ch: str) -> bool:
        o = ord(ch)
        return (
            0x4E00 <= o <= 0x9FFF
            or 0x3400 <= o <= 0x4DBF
            or 0x20000 <= o <= 0x2A6DF
            or 0x2A700 <= o <= 0x2EBEF
        )
    return sum(1 for ch in text if is_cjk(ch))


def main() -> int:
    default_target = os.path.join(
        os.path.dirname(os.path.abspath(__file__)),
        "..", "app", "SuperPickyInference", "Resources",
        "bird_reference.sqlite",
    )
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", default=default_target,
                        help="bird_reference.sqlite to mutate")
    args = parser.parse_args()

    target = os.path.abspath(args.target)
    if not os.path.exists(target):
        print(f"target not found: {target}", file=sys.stderr)
        return 1

    syllables = build_syllable_set()
    con = sqlite3.connect(target)
    try:
        cur = con.cursor()
        cols = {r[1] for r in cur.execute("PRAGMA table_info(BirdCountInfo)")}
        if "pinyin_initials" not in cols:
            cur.execute("ALTER TABLE BirdCountInfo ADD COLUMN pinyin_initials TEXT")

        rows = cur.execute(
            "SELECT id, chinese_simplified, pinyin FROM BirdCountInfo"
        ).fetchall()

        n_tokenized = 0
        n_pypinyin = 0
        n_null = 0
        for row_id, cn, py in rows:
            initials: str | None = None
            if py:
                toks = tokenize(py, syllables, cjk_count(cn) if cn else None)
                if toks is not None:
                    initials = "".join(t[0] for t in toks)
                    n_tokenized += 1
            if initials is None and cn:
                letters = lazy_pinyin(cn, style=Style.FIRST_LETTER, errors="ignore")
                joined = "".join(letters).lower()
                if joined:
                    initials = joined
                    n_pypinyin += 1
            if initials is None:
                n_null += 1
            cur.execute(
                "UPDATE BirdCountInfo SET pinyin_initials = ? WHERE id = ?",
                (initials, row_id),
            )

        con.commit()
        print(f"rows processed: {len(rows)}")
        print(f"initials from ioc pinyin: {n_tokenized}")
        print(f"initials from pypinyin:    {n_pypinyin}")
        print(f"rows left NULL:            {n_null}")
    finally:
        con.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
