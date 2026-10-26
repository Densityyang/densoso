#!/usr/bin/env python3
"""Import normalized food-composition JSON into a searchable SQLite database.

Development imports retain unverified legacy seed records so reviewers can
inspect and migrate them. Pass ``--production`` when building a distributable
database; it omits any row whose source and record-level redistribution
provenance are not both verified.
"""

from __future__ import annotations

import argparse
import json
import math
import sqlite3
import sys
import unicodedata
from collections import defaultdict
from pathlib import Path
from typing import Any


DEFAULT_MANIFEST = (
    Path(__file__).resolve().parent.parent
    / "Densoso"
    / "Resources"
    / "FoodData"
    / "sources.json"
)
ENERGY_FIELDS = ("energyKcal", "energy")
NUTRIENT_FIELDS = ("proteinG", "fatG", "carbohydrateG", "fiberG")
MISSING_MARKERS = {"", "—", "–", "-", "tr", "trace", "null", "n/a", "na"}


def _read_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"unable to read JSON from {path}: {error}") from error


def _source_registry(manifest_path: Path) -> dict[str, dict[str, Any]]:
    manifest = _read_json(manifest_path)
    if not isinstance(manifest, dict) or manifest.get("schemaVersion") != 1:
        raise ValueError("food source manifest must be an object with schemaVersion 1")
    sources = manifest.get("sources")
    if not isinstance(sources, list):
        raise ValueError("food source manifest must contain a sources array")

    registry: dict[str, dict[str, Any]] = {}
    for index, source in enumerate(sources):
        if not isinstance(source, dict):
            raise ValueError(f"manifest sources[{index}] must be an object")
        source_id = source.get("sourceID")
        version = source.get("sourceVersion")
        status = source.get("verificationStatus")
        if not isinstance(source_id, str) or not source_id.strip():
            raise ValueError(f"manifest sources[{index}] has no sourceID")
        if source_id in registry:
            raise ValueError(f"duplicate food sourceID: {source_id}")
        if not isinstance(version, str) or not version.strip():
            raise ValueError(f"manifest source {source_id!r} has no sourceVersion")
        if status not in {"verified", "unverified"}:
            raise ValueError(f"manifest source {source_id!r} has invalid verificationStatus")
        if not isinstance(source.get("redistributionAllowed"), bool):
            raise ValueError(f"manifest source {source_id!r} must declare redistributionAllowed")
        if status == "verified":
            required_evidence = (
                "sourceURL",
                "retrievedAt",
                "licenseSPDX",
                "licenseURL",
                "dataRole",
                "dataType",
            )
            missing = [
                field
                for field in required_evidence
                if not isinstance(source.get(field), str) or not source[field].strip()
            ]
            if missing:
                raise ValueError(
                    f"verified manifest source {source_id!r} is missing evidence: "
                    + ", ".join(missing)
                )
            if not source["sourceURL"].startswith("https://") or not source["licenseURL"].startswith("https://"):
                raise ValueError(
                    f"verified manifest source {source_id!r} must use HTTPS source and license URLs"
                )
            if source.get("dataRole") != "food-composition":
                raise ValueError(
                    f"verified manifest source {source_id!r} must declare dataRole 'food-composition'"
                )
        registry[source_id] = source
    return registry


def _number(value: Any, *, field: str, record: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float, str)):
        raise ValueError(f"{record}: {field} must be a numeric value, got {value!r}")
    try:
        parsed = float(value)
    except (TypeError, ValueError) as error:
        raise ValueError(f"{record}: {field} must be a numeric value, got {value!r}") from error
    if not math.isfinite(parsed):
        raise ValueError(f"{record}: {field} must be finite, got {value!r}")
    return parsed


def _energy_value(item: dict[str, Any], *, record: str) -> tuple[int, str, str]:
    energy_key = next((key for key in ENERGY_FIELDS if key in item), None)
    if energy_key is None:
        raise ValueError(f"{record}: energy is missing (no energyKcal field)")
    raw = item[energy_key]
    if raw is None:
        raise ValueError(f"{record}: energy is null, not zero")
    if isinstance(raw, str):
        marker = raw.strip().lower()
        if marker in MISSING_MARKERS:
            label = "trace" if marker in {"tr", "trace"} else "unavailable/empty"
            raise ValueError(f"{record}: energy is {label} ({raw!r}), not zero")

    unit = item.get("energyUnit", "kcal/100g")
    basis = item.get("nutrientBasis", "per100g")
    if basis != "per100g":
        raise ValueError(f"{record}: nutrientBasis {basis!r} is unsupported; expected 'per100g'")
    parsed = _number(raw, field=energy_key, record=record)
    input_limit = 4184 if unit == "kJ/100g" else 1000
    if parsed < 0 or parsed > input_limit:
        raise ValueError(
            f"{record}: energy value {parsed:g} {unit} is outside the supported 0–{input_limit} range"
        )
    if unit == "kJ/100g":
        # The source number remains in energyRaw; this is the normalized kcal value.
        parsed = parsed / 4.184
    elif unit == "kcal/100g":
        pass
    else:
        raise ValueError(f"{record}: unsupported energyUnit {unit!r}")

    if parsed > 1000:
        raise ValueError(f"{record}: normalized energy value {parsed:g} is outside the supported range")
    return int(round(parsed)), str(raw), unit


def _optional_nutrient(item: dict[str, Any], field: str, *, record: str) -> float | None:
    raw = item.get(field)
    if raw is None:
        return None
    if isinstance(raw, str) and raw.strip().lower() in MISSING_MARKERS:
        return None
    parsed = _number(raw, field=field, record=record)
    if parsed < 0 or parsed > 150:
        raise ValueError(f"{record}: {field} value {parsed:g} is outside the supported 0–150 g range")
    return parsed


def _normalize_alias(value: str) -> str:
    normalized = unicodedata.normalize("NFKC", value).casefold()
    return "".join(character for character in normalized if character.isalnum())


def _prepare_items(
    items: Any,
    registry: dict[str, dict[str, Any]],
    *,
    production: bool,
) -> tuple[list[dict[str, Any]], int, list[str]]:
    if not isinstance(items, list) or not items:
        raise ValueError("input must contain a non-empty food array")

    normalized: list[dict[str, Any]] = []
    seen_ids: set[int] = set()
    alias_owners: dict[str, set[int]] = defaultdict(set)
    skipped_unverified = 0
    warnings: list[str] = []

    for index, item in enumerate(items):
        if not isinstance(item, dict):
            raise ValueError(f"foods[{index}] must be an object")
        record = f"foods[{index}] ({item.get('name', '<unnamed>')!r})"
        identifier = item.get("id")
        if isinstance(identifier, bool) or not isinstance(identifier, int) or identifier <= 0:
            raise ValueError(f"{record}: id must be a positive integer")
        if identifier in seen_ids:
            raise ValueError(f"{record}: duplicate id {identifier}")
        seen_ids.add(identifier)

        name = item.get("name")
        category = item.get("category")
        if not isinstance(name, str) or not name.strip():
            raise ValueError(f"{record}: name must be non-empty")
        if not isinstance(category, str) or not category.strip():
            raise ValueError(f"{record}: category must be non-empty")
        aliases = item.get("alias")
        if aliases is not None and not isinstance(aliases, str):
            raise ValueError(f"{record}: alias must be a string or null")
        preparation = item.get("preparation")
        if preparation is not None and not isinstance(preparation, str):
            raise ValueError(f"{record}: preparation must be a string or null")
        mass_basis = item.get("massBasis", "unknown")
        if mass_basis not in {"edibleRaw", "cooked", "asPurchased", "unknown"}:
            raise ValueError(f"{record}: unsupported massBasis {mass_basis!r}")
        is_cooked_composite = item.get("isCookedComposite", False)
        if not isinstance(is_cooked_composite, bool):
            raise ValueError(f"{record}: isCookedComposite must be a boolean")

        edible = _number(item.get("edible", 100), field="edible", record=record)
        if edible < 0 or edible > 100:
            raise ValueError(f"{record}: edible must be between 0 and 100")
        if not edible.is_integer():
            raise ValueError(f"{record}: edible percentage must be a whole number")

        energy_kcal, energy_raw, source_energy_unit = _energy_value(item, record=record)
        record_warnings: list[str] = []
        if source_energy_unit == "kJ/100g":
            warning = f"{record}: energy converted from kJ/100g to kcal/100g"
            warnings.append(warning)
            record_warnings.append(warning)
        nutrients = {
            field: _optional_nutrient(item, field, record=record)
            for field in NUTRIENT_FIELDS
        }
        macros = (nutrients["proteinG"], nutrients["fatG"], nutrients["carbohydrateG"])
        if all(value is not None for value in macros):
            estimated_energy = 4 * macros[0] + 9 * macros[1] + 4 * macros[2]
            if abs(estimated_energy - energy_kcal) > max(100, energy_kcal * 0.5):
                warning = (
                    f"{record}: energy/macronutrients differ materially "
                    f"(energy={energy_kcal:g} kcal/100g, macro estimate={estimated_energy:g})"
                )
                warnings.append(warning)
                record_warnings.append(warning)

        source_id = item.get("sourceID")
        source_version = item.get("sourceVersion")
        source_record_id = item.get("sourceRecordID")
        license_status = item.get("licenseStatus", "unverified")
        if source_record_id is not None and (
            not isinstance(source_record_id, str) or not source_record_id.strip()
        ):
            raise ValueError(f"{record}: sourceRecordID must be a non-empty string or null")
        source = registry.get(source_id) if isinstance(source_id, str) else None
        if source is None:
            raise ValueError(f"{record}: sourceID {source_id!r} is absent from the source manifest")
        if source_version != source.get("sourceVersion"):
            raise ValueError(
                f"{record}: sourceVersion {source_version!r} does not match "
                f"manifest version {source.get('sourceVersion')!r}"
            )
        if license_status not in {"verified", "unverified"}:
            raise ValueError(f"{record}: licenseStatus must be 'verified' or 'unverified'")
        if license_status == "verified" and not (
            source.get("verificationStatus") == "verified"
            and source.get("redistributionAllowed") is True
            and isinstance(source_record_id, str)
            and bool(source_record_id.strip())
            and isinstance(source.get("licenseSPDX"), str)
            and bool(source.get("licenseSPDX").strip())
        ):
            raise ValueError(
                f"{record}: licenseStatus is verified but manifest/source-record "
                "redistribution evidence is incomplete"
            )
        if license_status == "verified":
            source_name = item.get("sourceName")
            if not isinstance(source_name, str) or not source_name.strip():
                raise ValueError(f"{record}: verified records must retain their original sourceName")
            if item.get("sourceDataType") != source.get("dataType"):
                raise ValueError(
                    f"{record}: sourceDataType {item.get('sourceDataType')!r} does not match "
                    f"manifest dataType {source.get('dataType')!r}"
                )
            if preparation == "raw" and mass_basis != "edibleRaw":
                raise ValueError(f"{record}: raw source records require massBasis 'edibleRaw'")
            if preparation == "cooked" and mass_basis != "cooked":
                raise ValueError(f"{record}: cooked source records require massBasis 'cooked'")

        source_is_redistributable = (
            source.get("verificationStatus") == "verified"
            and source.get("redistributionAllowed") is True
            and license_status == "verified"
            and isinstance(source_record_id, str)
            and bool(source_record_id.strip())
            and isinstance(source.get("licenseSPDX"), str)
            and bool(source.get("licenseSPDX").strip())
        )
        if production and not source_is_redistributable:
            skipped_unverified += 1
            continue

        if source_is_redistributable and not isinstance(source_record_id, str):
            raise ValueError(f"{record}: verified redistributable rows require a sourceRecordID")

        alias_values = aliases.split("|") if isinstance(aliases, str) else []
        for alias in [name, *alias_values]:
            normalized_alias = _normalize_alias(alias)
            if normalized_alias:
                alias_owners[normalized_alias].add(identifier)

        normalized.append({
            "id": identifier,
            "name": name.strip(),
            "alias": aliases,
            "preparation": preparation,
            "isCookedComposite": int(is_cooked_composite),
            "category": category.strip(),
            "edible": int(edible),
            "energyKcal": energy_kcal,
            "energyRaw": energy_raw,
            "energyUnit": source_energy_unit,
            **nutrients,
            "sourceID": source_id,
            "sourceRecordID": source_record_id,
            "sourceVersion": source_version,
            "licenseStatus": license_status,
            "sourceRecordJSON": json.dumps(item, ensure_ascii=False, sort_keys=True, separators=(",", ":")),
            "_importWarnings": record_warnings,
        })

    for alias, owners in alias_owners.items():
        if len(owners) > 1:
            warning = f"alias collision {alias!r} maps to food IDs {sorted(owners)}"
            warnings.append(warning)
            for row in normalized:
                if row["id"] in owners:
                    row["_importWarnings"].append(warning)

    for row in normalized:
        row["importWarningsJSON"] = json.dumps(row.pop("_importWarnings"), ensure_ascii=False)
    return normalized, skipped_unverified, warnings


def create_schema(conn: sqlite3.Connection) -> None:
    # Always rebuild generated artifacts so stale schemas cannot be packaged.
    conn.execute("DROP TABLE IF EXISTS food_fts")
    conn.execute("DROP TABLE IF EXISTS food_items")
    conn.execute("""
        CREATE TABLE food_items (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL,
            alias TEXT,
            preparation TEXT,
            isCookedComposite INTEGER NOT NULL DEFAULT 0,
            category TEXT NOT NULL,
            edible INTEGER NOT NULL DEFAULT 100,
            energyKcal INTEGER NOT NULL,
            energyRaw TEXT NOT NULL,
            energyUnit TEXT NOT NULL,
            proteinG REAL,
            fatG REAL,
            carbohydrateG REAL,
            fiberG REAL,
            sourceID TEXT NOT NULL,
            sourceRecordID TEXT,
            sourceVersion TEXT NOT NULL,
            licenseStatus TEXT NOT NULL,
            sourceRecordJSON TEXT NOT NULL,
            importWarningsJSON TEXT NOT NULL
        )
    """)
    conn.execute("CREATE INDEX idx_food_name ON food_items(name)")
    conn.execute("CREATE INDEX idx_food_category ON food_items(category)")
    conn.execute("""
        CREATE VIRTUAL TABLE food_fts USING fts5(
            name, alias, category,
            content='food_items',
            content_rowid='id'
        )
    """)


def import_data(conn: sqlite3.Connection, items: list[dict[str, Any]]) -> None:
    conn.executemany("""
        INSERT INTO food_items (
            id, name, alias, preparation, isCookedComposite, category, edible,
            energyKcal, energyRaw, energyUnit, proteinG, fatG, carbohydrateG,
            fiberG, sourceID, sourceRecordID, sourceVersion, licenseStatus,
            sourceRecordJSON, importWarningsJSON
        ) VALUES (
            :id, :name, :alias, :preparation, :isCookedComposite, :category,
            :edible, :energyKcal, :energyRaw, :energyUnit, :proteinG, :fatG,
            :carbohydrateG, :fiberG, :sourceID, :sourceRecordID,
            :sourceVersion, :licenseStatus, :sourceRecordJSON, :importWarningsJSON
        )
    """, items)


def rebuild_fts(conn: sqlite3.Connection) -> None:
    conn.execute("INSERT INTO food_fts(food_fts) VALUES('rebuild')")


def main() -> int:
    parser = argparse.ArgumentParser(description="Import food composition JSON into SQLite")
    parser.add_argument("--input", required=True, help="input JSON file path")
    parser.add_argument("--output", default="food_composition.db", help="output SQLite file path")
    parser.add_argument("--manifest", default=str(DEFAULT_MANIFEST), help="food source manifest path")
    parser.add_argument(
        "--production",
        action="store_true",
        help="exclude records without verified redistributable source and record provenance",
    )
    args = parser.parse_args()

    try:
        input_path = Path(args.input)
        manifest_path = Path(args.manifest)
        payload = _read_json(input_path)
        items = payload if isinstance(payload, list) else payload.get("foods") if isinstance(payload, dict) else None
        registry = _source_registry(manifest_path)
        normalized, skipped, warnings = _prepare_items(items, registry, production=args.production)
    except ValueError as error:
        print(f"food import rejected: {error}", file=sys.stderr)
        return 2

    for warning in warnings:
        print(f"food import warning: {warning}", file=sys.stderr)

    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(output_path)
    try:
        create_schema(conn)
        import_data(conn, normalized)
        rebuild_fts(conn)
        conn.commit()
        count = conn.execute("SELECT COUNT(*) FROM food_items").fetchone()[0]
    finally:
        conn.close()

    mode = "production" if args.production else "development/review"
    print(f"Food import ({mode}): {count} rows → {output_path}")
    if args.production and skipped:
        print(
            f"Food import note: excluded {skipped} row(s) without verified, "
            "redistributable provenance; the app will have no local composition "
            "catalog until a licensed source is added."
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
