#!/usr/bin/env python3
# Adds a `pinyin` column to BirdCountInfo in
# apps/mac-client/SuperPickyInference/Resources/bird_reference.sqlite,
# populating it by joining ~/projects/superpicky/ioc/birdname.db#birds
# on scientific_name == latin_name. Pinyin syllables are concatenated
# (spaces stripped) to match the keyword-search convention.
#
# Idempotent: running twice leaves the column in place and re-populates.

import argparse
import os
import sqlite3
import sys


def main() -> int:
    default_target = os.path.join(
        os.path.dirname(os.path.abspath(__file__)),
        "..", "apps", "mac-client", "SuperPickyInference", "Resources",
        "bird_reference.sqlite",
    )
    default_source = os.path.expanduser("~/projects/superpicky/ioc/birdname.db")

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", default=default_target,
                        help="bird_reference.sqlite to mutate")
    parser.add_argument("--source", default=default_source,
                        help="birdname.db with birds.pinyin_name column")
    args = parser.parse_args()

    target = os.path.abspath(args.target)
    source = os.path.abspath(args.source)

    if not os.path.exists(target):
        print(f"target not found: {target}", file=sys.stderr)
        return 1
    if not os.path.exists(source):
        print(f"source not found: {source}", file=sys.stderr)
        return 1

    con = sqlite3.connect(target)
    try:
        cur = con.cursor()
        cols = {r[1] for r in cur.execute("PRAGMA table_info(BirdCountInfo)")}
        if "pinyin" not in cols:
            cur.execute("ALTER TABLE BirdCountInfo ADD COLUMN pinyin TEXT")

        # Pull {latin -> pinyin_no_spaces} from the superpicky ioc db.
        src = sqlite3.connect(f"file:{source}?mode=ro", uri=True)
        try:
            rows = src.execute(
                "SELECT latin_name, pinyin_name FROM birds "
                "WHERE latin_name IS NOT NULL AND pinyin_name IS NOT NULL"
            ).fetchall()
        finally:
            src.close()

        by_latin = {}
        for latin, pinyin in rows:
            by_latin[latin] = "".join(pinyin.split())

        target_rows = cur.execute(
            "SELECT id, scientific_name FROM BirdCountInfo"
        ).fetchall()
        updated = 0
        missing = 0
        for row_id, scientific in target_rows:
            pinyin = by_latin.get(scientific)
            if pinyin is None:
                missing += 1
                continue
            cur.execute(
                "UPDATE BirdCountInfo SET pinyin = ? WHERE id = ?",
                (pinyin, row_id),
            )
            updated += 1

        con.commit()

        print(f"rows processed: {len(target_rows)}")
        print(f"rows updated:   {updated}")
        print(f"rows missing pinyin: {missing}")

        # Fail loudly if too many rows lack pinyin. The bundled DB gates
        # XMP keyword output and the search widget; a silent regression
        # (e.g. source DB renamed, Latin mismatch) would ship empty
        # pinyin to users. 3% is the current soft ceiling — the source
        # DB is missing a small tail of rarely-photographed species
        # (e.g. some subspecies); bumping this materially means the
        # join key drifted and most rows are silently empty.
        max_missing_fraction = 0.03
        if len(target_rows) > 0:
            missing_fraction = missing / len(target_rows)
            if missing_fraction > max_missing_fraction:
                print(
                    f"ERROR: {missing_fraction:.1%} of rows missing pinyin "
                    f"(ceiling {max_missing_fraction:.1%}). Check that "
                    f"{source} still has expected Latin names.",
                    file=sys.stderr,
                )
                return 2
    finally:
        con.close()

    return 0


if __name__ == "__main__":
    sys.exit(main())
