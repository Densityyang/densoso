#!/usr/bin/env python3
"""将 ChinaFoodComposition JSON 数据导入为 SQLite 数据库（含 FTS5 索引）

用法:
    python3 import_food_db.py --input foods.json --output food_composition.db

来源:
    GitHub: andforce/ChinaFoodComposition
"""
import json, sqlite3, argparse, sys
from pathlib import Path

def create_schema(conn):
    conn.execute("""
        CREATE TABLE IF NOT EXISTS food_items (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL,
            alias TEXT,
            category TEXT NOT NULL,
            edible INTEGER NOT NULL DEFAULT 100,
            energyKcal INTEGER NOT NULL,
            proteinG REAL NOT NULL DEFAULT 0,
            fatG REAL NOT NULL DEFAULT 0,
            carbohydrateG REAL NOT NULL DEFAULT 0,
            fiberG REAL
        )
    """)
    conn.execute("CREATE INDEX IF NOT EXISTS idx_food_name ON food_items(name)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_food_category ON food_items(category)")
    conn.execute("""
        CREATE VIRTUAL TABLE IF NOT EXISTS food_fts USING fts5(
            name, alias, category,
            content='food_items',
            content_rowid='id'
        )
    """)

def import_data(conn, items):
    conn.executemany("""
        INSERT OR REPLACE INTO food_items
        (id, name, alias, category, edible, energyKcal, proteinG, fatG, carbohydrateG, fiberG)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """, [
        (
            item.get("id"),
            item.get("name", ""),
            item.get("alias"),
            item.get("category", ""),
            item.get("edible", 100),
            item.get("energyKcal", 0),
            item.get("proteinG", 0),
            item.get("fatG", 0),
            item.get("carbohydrateG", 0),
            item.get("fiberG"),
        )
        for item in items
    ])

def rebuild_fts(conn):
    conn.execute("INSERT INTO food_fts(food_fts) VALUES('rebuild')")

def main():
    parser = argparse.ArgumentParser(description="导入 ChinaFoodComposition → SQLite")
    parser.add_argument("--input", required=True, help="输入 JSON 文件路径")
    parser.add_argument("--output", default="food_composition.db", help="输出 SQLite 文件路径")
    args = parser.parse_args()

    with open(args.input, "r", encoding="utf-8") as f:
        data = json.load(f)

    items = data if isinstance(data, list) else data.get("foods", [])
    print(f"读取到 {len(items)} 条食材记录")

    conn = sqlite3.connect(args.output)
    create_schema(conn)
    import_data(conn, items)
    rebuild_fts(conn)
    conn.commit()

    count = conn.execute("SELECT COUNT(*) FROM food_items").fetchone()[0]
    print(f"导入完成: {count} 条记录 → {args.output}")
    conn.close()

if __name__ == "__main__":
    main()