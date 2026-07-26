#!/usr/bin/env python3
"""Validate that the development food seed can build a searchable SQLite database."""

from __future__ import annotations

import json
import sqlite3
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
IMPORTER = ROOT / "scripts" / "import_food_db.py"
SEED_FILE = ROOT / "Densoso" / "Resources" / "seed_foods.json"


def main() -> None:
    items = json.loads(SEED_FILE.read_text(encoding="utf-8"))
    if not isinstance(items, list) or not items:
        raise SystemExit("seed_foods.json must contain a non-empty food array")

    with tempfile.TemporaryDirectory(prefix="densoso-food-db-") as temporary_directory:
        database_path = Path(temporary_directory) / "food_composition.db"
        subprocess.run(
            [sys.executable, str(IMPORTER), "--input", str(SEED_FILE), "--output", str(database_path)],
            check=True,
        )

        connection = sqlite3.connect(database_path)
        try:
            row_count = connection.execute("SELECT COUNT(*) FROM food_items").fetchone()[0]
            fts_count = connection.execute("SELECT COUNT(*) FROM food_fts").fetchone()[0]
            if row_count != len(items) or fts_count != len(items):
                raise SystemExit(
                    f"food database row mismatch: items={len(items)}, rows={row_count}, fts={fts_count}"
                )

            sample_name = items[0]["name"]
            match_count = connection.execute(
                "SELECT COUNT(*) FROM food_fts WHERE food_fts MATCH ?", (f'"{sample_name}"',)
            ).fetchone()[0]
            if match_count != 1:
                raise SystemExit(f"FTS smoke test failed for {sample_name!r}: matches={match_count}")

            cooked_rice = connection.execute(
                "SELECT energyKcal FROM food_items WHERE name = '米饭(熟)'"
            ).fetchone()
            raw_rice = connection.execute(
                "SELECT energyKcal FROM food_items WHERE name = '大米(生)'"
            ).fetchone()
            if cooked_rice != (116,) or raw_rice != (346,):
                raise SystemExit("rice mass-basis fixtures are missing or have incorrect energy values")
        finally:
            connection.close()

    print(f"Food database smoke test passed for {len(items)} seed items.")


if __name__ == "__main__":
    main()
