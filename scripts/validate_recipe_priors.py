#!/usr/bin/env python3
"""Validate the shipped recipe-prior catalog and its pinned provenance."""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
from collections import Counter
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CATALOG = ROOT / "Densoso/Resources/FoodData/recipe_priors.json"
DEFAULT_REPORT = ROOT / "Densoso/Resources/FoodData/recipe_prior_import_report.json"
MINIMUM_RECIPES = 100
REQUIRED_CATEGORIES = {"vegetable", "meat", "aquatic", "breakfast", "staple", "soup"}
EXPECTED_SOURCE_VERSION = "5fb3140c20b2a713296696dc6fdd3b83ccc617a6"
QUANTITY_KINDS = {
    "notSpecifiedInSource",
    "sourceTextOnly",
    "sourceQuantity",
    "sourceRange",
    "formula",
}


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"cannot read {path}: {error}") from error


def normalize(value: str) -> str:
    return re.sub(r"[\s\W_]+", "", value).lower()


def validate(catalog: dict[str, Any], report: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    source = catalog.get("source")
    recipes = catalog.get("recipes")
    if catalog.get("schemaVersion") != 1 or catalog.get("dataRole") != "recipe-prior":
        errors.append("catalog must declare schemaVersion 1 and dataRole recipe-prior")
    if not isinstance(source, dict) or not isinstance(recipes, list):
        return errors + ["catalog is missing source metadata or recipes array"]
    expected_license_url = (
        "https://github.com/Anduin2017/HowToCook/blob/"
        f"{EXPECTED_SOURCE_VERSION}/LICENSE"
    )
    if (
        source.get("sourceID") != "anduin-howtocook"
        or source.get("sourceURL") != "https://github.com/Anduin2017/HowToCook"
        or source.get("sourceVersion") != EXPECTED_SOURCE_VERSION
    ):
        errors.append("catalog source ID, URL, or version is not the pinned HowToCook revision")
    if (
        source.get("licenseSPDX") != "Unlicense"
        or source.get("licenseURL") != expected_license_url
        or source.get("verificationStatus") != "verified"
    ):
        errors.append("catalog source license evidence is not verified against the pinned LICENSE")
    if (
        source.get("redistributionAllowed") is not True
        or source.get("dataRole") != "recipe-prior"
    ):
        errors.append("recipe source must be redistributable and limited to recipe-prior data")
    if len(recipes) < MINIMUM_RECIPES:
        errors.append(f"catalog has {len(recipes)} recipes; requires at least {MINIMUM_RECIPES}")

    ids: set[str] = set()
    records: set[str] = set()
    names: Counter[str] = Counter()
    categories: Counter[str] = Counter()
    for index, recipe in enumerate(recipes):
        prefix = f"recipes[{index}]"
        if not isinstance(recipe, dict):
            errors.append(f"{prefix} must be an object")
            continue
        recipe_id = recipe.get("id")
        record_id = recipe.get("sourceRecordID")
        name = recipe.get("canonicalDishName")
        category = recipe.get("category")
        if not isinstance(recipe_id, str) or not recipe_id:
            errors.append(f"{prefix}.id is missing")
        elif recipe_id in ids:
            errors.append(f"duplicate recipe id: {recipe_id}")
        else:
            ids.add(recipe_id)
        if not isinstance(record_id, str) or not record_id.startswith("dishes/"):
            errors.append(f"{prefix}.sourceRecordID must point to a source dish record")
        elif record_id in records:
            errors.append(f"duplicate source record: {record_id}")
        else:
            records.add(record_id)
        if isinstance(record_id, str) and (
            not record_id.endswith(".md")
            or ".." in Path(record_id).parts
            or recipe.get("id") != f"{source.get('sourceID')}:{record_id}"
        ):
            errors.append(f"{prefix}.id must identify its canonical source record path")
        if not isinstance(name, str) or len(name.strip()) < 2:
            errors.append(f"{prefix}.canonicalDishName is missing")
        else:
            names[normalize(name)] += 1
        if not isinstance(category, str) or not category:
            errors.append(f"{prefix}.category is missing")
        else:
            categories[category] += 1
        if recipe.get("sourceID") != source.get("sourceID"):
            errors.append(f"{prefix}.sourceID does not match catalog source")
        if recipe.get("sourceVersion") != EXPECTED_SOURCE_VERSION:
            errors.append(f"{prefix}.sourceVersion is not pinned")
        if recipe.get("licenseStatus") != "verified" or recipe.get("licenseSPDX") != "Unlicense":
            errors.append(f"{prefix} has unverifiable license metadata")
        if recipe.get("isNutritionAuthority") is not False:
            errors.append(f"{prefix} must explicitly remain a non-nutrition prior")
        digest = recipe.get("sourceRecordSHA256")
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
            errors.append(f"{prefix}.sourceRecordSHA256 is missing or invalid")
        ingredients = recipe.get("ingredients")
        if not isinstance(ingredients, list) or len(ingredients) < 2:
            errors.append(f"{prefix} must preserve at least two source ingredient rows")
            continue
        if len(ingredients) > 40:
            errors.append(f"{prefix} exceeds the ingredient bound")
        for ingredient_index, ingredient in enumerate(ingredients):
            ingredient_prefix = f"{prefix}.ingredients[{ingredient_index}]"
            if (
                not isinstance(ingredient, dict)
                or not isinstance(ingredient.get("sourceName"), str)
                or not ingredient["sourceName"].strip()
            ):
                errors.append(f"{ingredient_prefix}.sourceName is missing")
                continue
            if not isinstance(ingredient.get("isOptional"), bool) or not isinstance(
                ingredient.get("isAlternative"), bool
            ):
                errors.append(f"{ingredient_prefix} optional/alternative flags must be booleans")
            quantity = ingredient.get("quantityEvidence")
            if not isinstance(quantity, dict) or quantity.get("kind") not in QUANTITY_KINDS:
                errors.append(f"{ingredient_prefix}.quantityEvidence is invalid")
                continue
            if quantity.get("kind") != "notSpecifiedInSource" and not quantity.get("sourceText"):
                errors.append(f"{ingredient_prefix} quantity evidence must retain raw source text")
            if quantity.get("kind") in {"sourceQuantity", "sourceRange", "formula"}:
                value = quantity.get("value")
                if (
                    isinstance(value, bool)
                    or not isinstance(value, (int, float))
                    or not math.isfinite(value)
                    or value <= 0
                ):
                    errors.append(f"{ingredient_prefix} has invalid parsed source quantity")
                if not isinstance(quantity.get("unit"), str) or not quantity["unit"].strip():
                    errors.append(f"{ingredient_prefix} parsed quantity must retain its source unit")
                upper_value = quantity.get("upperValue")
                if quantity.get("kind") == "sourceRange":
                    if (
                        isinstance(upper_value, bool)
                        or not isinstance(upper_value, (int, float))
                        or not math.isfinite(upper_value)
                        or isinstance(value, bool)
                        or not isinstance(value, (int, float))
                        or not math.isfinite(value)
                        or upper_value < value
                    ):
                        errors.append(f"{ingredient_prefix} has invalid source range bounds")
                elif upper_value is not None:
                    errors.append(f"{ingredient_prefix} has an unexpected upper quantity bound")
            elif quantity.get("kind") == "sourceTextOnly" and not isinstance(
                quantity.get("sourceText"), str
            ):
                errors.append(f"{ingredient_prefix} sourceTextOnly evidence must retain text")

    duplicate_names = [name for name, count in names.items() if count > 1]
    if duplicate_names:
        errors.append("duplicate canonical dish names: " + ", ".join(sorted(duplicate_names)[:12]))
    missing_categories = sorted(REQUIRED_CATEGORIES - set(categories))
    if missing_categories:
        errors.append("missing category coverage: " + ", ".join(missing_categories))

    if report.get("schemaVersion") != 1 or report.get("sourceVersion") != EXPECTED_SOURCE_VERSION:
        errors.append("import review report is missing the pinned provenance")
    if (
        report.get("sourceID") != source.get("sourceID")
        or report.get("licenseSPDX") != source.get("licenseSPDX")
        or report.get("status") != "PASS"
    ):
        errors.append("import review report source/license/status does not match the catalog")
    if report.get("acceptedCount") != len(recipes):
        errors.append("import review report acceptedCount does not match catalog size")
    ingredient_count = 0
    quantity_counts: Counter[str] = Counter()
    for recipe in recipes:
        if not isinstance(recipe, dict):
            continue
        ingredients = recipe.get("ingredients")
        if not isinstance(ingredients, list):
            continue
        ingredient_count += len(ingredients)
        quantity_counts.update(
            ingredient.get("quantityEvidence", {}).get("kind", "<missing>")
            for ingredient in ingredients
            if isinstance(ingredient, dict)
            and isinstance(ingredient.get("quantityEvidence"), dict)
        )
    if report.get("ingredientRowCount") != ingredient_count:
        errors.append("import report ingredientRowCount does not match catalog rows")
    if report.get("quantityEvidenceCounts") != dict(sorted(quantity_counts.items())):
        errors.append("import report quantity evidence counts do not match catalog rows")
    rejections = report.get("rejections")
    if not isinstance(rejections, list) or report.get("rejectedCount") != len(rejections):
        errors.append("import review report rejection list/count is inconsistent")
    elif any(
        not isinstance(entry, dict)
        or not isinstance(entry.get("sourceRecordID"), str)
        or not entry["sourceRecordID"].startswith("dishes/")
        or not isinstance(entry.get("reason"), str)
        or not entry["reason"].strip()
        for entry in rejections
    ):
        errors.append("import review report contains an invalid source-record rejection entry")
    review_rows = report.get("reviewRows")
    if (
        not isinstance(review_rows, list)
        or report.get("reviewRowCount") != len(review_rows)
        or any(
            not isinstance(entry, dict)
            or not isinstance(entry.get("sourceRecordID"), str)
            or not entry["sourceRecordID"].startswith("dishes/")
            or not isinstance(entry.get("sourceText"), str)
            or not entry["sourceText"].strip()
            or entry.get("reason") not in {
                "instructionOrNote",
                "explicitToolLine",
                "recognizedEquipmentTerm",
            }
            for entry in (review_rows if isinstance(review_rows, list) else [])
        )
    ):
        errors.append("import review report has malformed non-ingredient review rows")
    quantity_review_rows = report.get("quantityReviewRows")
    if (
        not isinstance(quantity_review_rows, list)
        or report.get("quantityReviewRowCount") != len(quantity_review_rows)
        or any(
            not isinstance(entry, dict)
            or not isinstance(entry.get("sourceRecordID"), str)
            or not entry["sourceRecordID"].startswith("dishes/")
            or not isinstance(entry.get("sourceName"), str)
            or not entry["sourceName"].strip()
            or not isinstance(entry.get("sourceText"), str)
            or not entry["sourceText"].strip()
            or entry.get("reason") not in {
                "multipleSourceQuantityLines",
                "ambiguousQuantityExpression",
                "ambiguousIngredientMatch",
                "unmatchedIngredientName",
            }
            for entry in (
                quantity_review_rows if isinstance(quantity_review_rows, list) else []
            )
        )
    ):
        errors.append("import review report has malformed ambiguous quantity review rows")
    scanned_count = report.get("scannedCount")
    accepted_count = report.get("acceptedCount")
    rejected_count = report.get("rejectedCount")
    if (
        any(isinstance(value, bool) or not isinstance(value, int) for value in (
            scanned_count, accepted_count, rejected_count
        ))
        or scanned_count != accepted_count + rejected_count
    ):
        errors.append("import review report scanned/accepted/rejected counts are inconsistent")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", type=Path, default=DEFAULT_CATALOG)
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    args = parser.parse_args()
    try:
        catalog = load_json(args.catalog)
        report = load_json(args.report)
        if not isinstance(catalog, dict) or not isinstance(report, dict):
            raise ValueError("catalog and import report must be JSON objects")
        errors = validate(catalog, report)
    except ValueError as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    source = catalog.get("source")
    recipes = catalog.get("recipes")
    summary = {
        "status": "FAIL" if errors else "PASS",
        "sourceVersion": source.get("sourceVersion") if isinstance(source, dict) else None,
        "recipeCount": len(recipes) if isinstance(recipes, list) else 0,
        "categories": dict(sorted(Counter(
            recipe.get("category") if isinstance(recipe.get("category"), str) else "unknown"
            for recipe in (recipes if isinstance(recipes, list) else [])
            if isinstance(recipe, dict)
        ).items())),
        "errors": errors,
    }
    print(json.dumps(summary, ensure_ascii=False, sort_keys=True))
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
