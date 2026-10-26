#!/usr/bin/env python3
"""Validate the shipped recipe-prior catalog and its pinned provenance."""

from __future__ import annotations

import argparse
import hashlib
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
DEFAULT_FOOD_DATA = ROOT / "Densoso/Resources/seed_foods.json"
DEFAULT_FOOD_SOURCES = ROOT / "Densoso/Resources/FoodData/sources.json"
DEFAULT_VERIFIED_FOOD_IDS = ROOT / "Densoso/Resources/FoodData/verified_food_ids.json"
DEFAULT_VERIFIED_FOOD_RECORDS = ROOT / "Densoso/Resources/FoodData/verified_food_records.json"
PROJECT_SPEC = ROOT / "project.yml"
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
FOOD_MATCH_STATUSES = {"exact", "ambiguous", "unmapped"}
MASS_BASES = {"raw", "cooked", "unknown"}
MASS_BASIS_EVIDENCE_KINDS = {"explicitSourceCue", "unknown"}
EDIBLE_FRACTION_EVIDENCE_KINDS = {"foodCompositionRecord", "unknown"}
INGREDIENT_ROLES = {"ingredient", "oil", "seasoning"}
ROLE_RULE_VERSION = "recipe-ingredient-role-v1"
REQUIRED_RECIPE_FIELDS = {
    "id", "canonicalDishName", "aliases", "category", "cuisineRegion", "cookingMethod",
    "cookingMethodEvidence", "ingredients", "servingsSourceText", "cookedYieldEvidence",
    "householdMeasures", "oilRetention", "sourceID", "sourceRecordID", "sourceVersion",
    "licenseStatus", "licenseSPDX", "confidenceGrade", "sourceRecordSHA256",
    "isNutritionAuthority",
}
REQUIRED_INGREDIENT_FIELDS = {
    "sourceName", "foodID", "foodMatchStatus", "edibleFractionEvidence", "massBasis",
    "massBasisEvidence", "role", "roleEvidence", "sourceProvenance", "isOptional",
    "isAlternative", "quantityEvidence",
}
REQUIRED_SOURCE_PROVENANCE_FIELDS = {"sourceID", "sourceRecordID", "sourceVersion", "sourceText"}
REQUIRED_EDIBLE_EVIDENCE_FIELDS = {
    "kind", "fraction", "foodID", "sourceID", "sourceRecordID", "sourceVersion",
    "licenseStatus", "licenseSPDX", "redistributionAllowed", "reason",
}


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"cannot read {path}: {error}") from error


def normalize(value: str) -> str:
    return re.sub(r"[\s\W_]+", "", value).lower()


def canonical_json_sha256(raw: bytes) -> str:
    source_text = raw.decode("utf-8")
    canonical_bytes = source_text.replace("\r\n", "\n").replace("\r", "\n").encode("utf-8")
    return hashlib.sha256(canonical_bytes).hexdigest()


def load_verified_food_sources(manifest: Any) -> dict[str, dict[str, Any]]:
    if not isinstance(manifest, dict) or manifest.get("schemaVersion") != 1:
        raise ValueError("food source manifest must declare schemaVersion 1")
    sources = manifest.get("sources")
    if not isinstance(sources, list):
        raise ValueError("food source manifest is missing its sources array")
    verified: dict[str, dict[str, Any]] = {}
    seen_ids: set[str] = set()
    for index, source in enumerate(sources):
        if not isinstance(source, dict):
            raise ValueError(f"food source manifest entry {index} must be an object")
        source_id = source.get("sourceID")
        if not isinstance(source_id, str) or not source_id.strip() or source_id in seen_ids:
            raise ValueError(f"food source manifest entry {index} has a missing or duplicate sourceID")
        seen_ids.add(source_id)
        if source.get("verificationStatus") != "verified" or source.get("redistributionAllowed") is not True:
            continue
        if not all(
            isinstance(source.get(field), str) and source[field].strip()
            for field in ("licenseSPDX", "licenseURL", "sourceVersion", "dataType")
        ) or source.get("dataRole") != "food-composition":
            raise ValueError(
                f"verified redistributable source {source_id} must be licensed, versioned, and food-composition data"
            )
        verified[source_id] = source
    if not verified:
        raise ValueError("food source manifest has no verified redistributable records")
    return verified


def load_verified_food_records(
    food_rows: Any,
    verified_sources: dict[str, dict[str, Any]],
) -> dict[int, dict[str, Any]]:
    if not isinstance(food_rows, list) or not food_rows:
        raise ValueError("food composition input must be a non-empty array")
    records: dict[int, dict[str, Any]] = {}
    seen_ids: set[int] = set()
    seen_source_records: set[tuple[str, str]] = set()
    for index, item in enumerate(food_rows):
        if not isinstance(item, dict):
            raise ValueError(f"food composition row {index} must be an object")
        food_id = item.get("id")
        edible = item.get("edible")
        if (
            isinstance(food_id, bool)
            or not isinstance(food_id, int)
            or food_id <= 0
            or food_id in seen_ids
        ):
            raise ValueError(f"food composition row {index} has a missing, invalid, or duplicate ID")
        if isinstance(edible, bool) or not isinstance(edible, int) or not 0 <= edible <= 100:
            raise ValueError(f"food composition row {index} has an invalid edible percentage")
        seen_ids.add(food_id)
        source_id = item.get("sourceID")
        if not isinstance(source_id, str) or not source_id.strip():
            raise ValueError(f"food composition row {index} has no sourceID")
        source = verified_sources.get(source_id)
        if source is None:
            continue
        if (
            item.get("licenseStatus") != "verified"
            or not isinstance(item.get("sourceRecordID"), str)
            or not item["sourceRecordID"].strip()
            or item.get("sourceVersion") != source["sourceVersion"]
            or item.get("sourceDataType") != source["dataType"]
        ):
            raise ValueError(f"verified food source row {food_id} has inconsistent provenance")
        source_record_key = (source_id, item["sourceRecordID"])
        if source_record_key in seen_source_records:
            raise ValueError(f"verified food source repeats source record {source_record_key!r}")
        seen_source_records.add(source_record_key)
        records[food_id] = {
            **item,
            "_verifiedLicenseSPDX": source["licenseSPDX"],
            "_verifiedRedistributionAllowed": source["redistributionAllowed"],
            "_verifiedDataRole": source["dataRole"],
            "_verifiedDataType": source["dataType"],
        }
    if not records:
        raise ValueError("food data has no records from verified redistributable sources")
    return records


def verified_food_records_projection(
    records: dict[int, dict[str, Any]],
) -> dict[str, Any]:
    return {
        "schemaVersion": 1,
        "records": [
            {
                "id": food_id,
                "sourceID": record["sourceID"],
                "sourceRecordID": record["sourceRecordID"],
                "sourceVersion": record["sourceVersion"],
                "sourceDataType": record["sourceDataType"],
                "licenseStatus": record["licenseStatus"],
                "licenseSPDX": record["_verifiedLicenseSPDX"],
                "redistributionAllowed": record["_verifiedRedistributionAllowed"],
                "dataRole": record["_verifiedDataRole"],
                "edible": record["edible"],
            }
            for food_id, record in sorted(records.items())
        ],
    }


def deterministic_json_bytes(value: Any) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")


def validate_quantity_evidence_shape(
    evidence: Any,
    prefix: str,
    errors: list[str],
) -> bool:
    if not isinstance(evidence, dict) or evidence.get("kind") not in QUANTITY_KINDS:
        errors.append(f"{prefix} is invalid")
        return False

    kind = evidence["kind"]
    required = {"kind", "sourceText"}
    if kind in {"sourceQuantity", "sourceRange", "formula"}:
        required.update({"value", "upperValue", "unit"})
    missing = required.difference(evidence)
    if missing:
        errors.append(f"{prefix} is missing schema fields: {', '.join(sorted(missing))}")
        return False

    if kind == "notSpecifiedInSource":
        if evidence["sourceText"] is not None:
            errors.append(f"{prefix} notSpecifiedInSource must have null sourceText")
    elif not isinstance(evidence["sourceText"], str) or not evidence["sourceText"].strip():
        errors.append(f"{prefix} must retain non-empty sourceText")

    if kind in {"sourceQuantity", "sourceRange", "formula"}:
        value = evidence["value"]
        upper_value = evidence["upperValue"]
        if (
            isinstance(value, bool)
            or not isinstance(value, (int, float))
            or not math.isfinite(value)
            or value <= 0
            or not isinstance(evidence["unit"], str)
            or not evidence["unit"].strip()
        ):
            errors.append(f"{prefix} has invalid parsed quantity fields")
            return False
        if kind == "sourceRange":
            if (
                isinstance(upper_value, bool)
                or not isinstance(upper_value, (int, float))
                or not math.isfinite(upper_value)
                or upper_value < value
            ):
                errors.append(f"{prefix} has invalid source range bounds")
                return False
        elif upper_value is not None:
            errors.append(f"{prefix} has an unexpected upper quantity bound")
            return False
    elif any(evidence.get(field) is not None for field in ("value", "upperValue", "unit")):
        errors.append(f"{prefix} has numeric fields for a text-only quantity kind")
        return False
    return True


def validate(
    catalog: dict[str, Any],
    report: dict[str, Any],
    known_food_records: dict[int, dict[str, Any]],
    food_data_sha256: str,
    food_source_manifest_sha256: str,
) -> list[str]:
    errors: list[str] = []
    source = catalog.get("source")
    recipes = catalog.get("recipes")
    if catalog.get("schemaVersion") != 2 or catalog.get("dataRole") != "recipe-prior":
        errors.append("catalog must declare schemaVersion 2 and dataRole recipe-prior")
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
        missing_recipe_fields = REQUIRED_RECIPE_FIELDS.difference(recipe)
        if missing_recipe_fields:
            errors.append(f"{prefix} is missing schema fields: {', '.join(sorted(missing_recipe_fields))}")
        validate_quantity_evidence_shape(recipe.get("cookedYieldEvidence"), f"{prefix}.cookedYieldEvidence", errors)
        validate_quantity_evidence_shape(recipe.get("oilRetention"), f"{prefix}.oilRetention", errors)
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
        cuisine_region = recipe.get("cuisineRegion")
        if "cuisineRegion" not in recipe or (cuisine_region is not None and (
            not isinstance(cuisine_region, str) or not cuisine_region.strip()
        )):
            errors.append(f"{prefix}.cuisineRegion must be a non-empty source-backed value or null")
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
            missing_ingredient_fields = REQUIRED_INGREDIENT_FIELDS.difference(ingredient)
            if missing_ingredient_fields:
                errors.append(
                    f"{ingredient_prefix} is missing schema fields: "
                    f"{', '.join(sorted(missing_ingredient_fields))}"
                )
            validate_quantity_evidence_shape(
                ingredient.get("quantityEvidence"),
                f"{ingredient_prefix}.quantityEvidence",
                errors,
            )
            if not isinstance(ingredient.get("isOptional"), bool) or not isinstance(
                ingredient.get("isAlternative"), bool
            ):
                errors.append(f"{ingredient_prefix} optional/alternative flags must be booleans")
            food_id = ingredient.get("foodID")
            match_status = ingredient.get("foodMatchStatus")
            if not isinstance(match_status, str) or match_status not in FOOD_MATCH_STATUSES:
                errors.append(f"{ingredient_prefix}.foodMatchStatus is invalid")
            elif match_status == "exact":
                if (
                    isinstance(food_id, bool)
                    or not isinstance(food_id, int)
                    or food_id <= 0
                    or food_id not in known_food_records
                ):
                    errors.append(f"{ingredient_prefix}.foodID does not identify a verified redistributable bundled food record")
            elif food_id is not None:
                errors.append(f"{ingredient_prefix} must not claim foodID without one exact mapping")

            provenance = ingredient.get("sourceProvenance")
            if isinstance(provenance, dict):
                missing_provenance_fields = REQUIRED_SOURCE_PROVENANCE_FIELDS.difference(provenance)
                if missing_provenance_fields:
                    errors.append(
                        f"{ingredient_prefix}.sourceProvenance is missing schema fields: "
                        f"{', '.join(sorted(missing_provenance_fields))}"
                    )
            if (
                not isinstance(provenance, dict)
                or provenance.get("sourceID") != recipe.get("sourceID")
                or provenance.get("sourceRecordID") != record_id
                or provenance.get("sourceVersion") != recipe.get("sourceVersion")
                or not isinstance(provenance.get("sourceText"), str)
                or not provenance["sourceText"].strip()
            ):
                errors.append(f"{ingredient_prefix}.sourceProvenance is missing or does not match the pinned recipe row")

            edible = ingredient.get("edibleFractionEvidence")
            if isinstance(edible, dict):
                missing_edible_fields = REQUIRED_EDIBLE_EVIDENCE_FIELDS.difference(edible)
                if missing_edible_fields:
                    errors.append(
                        f"{ingredient_prefix}.edibleFractionEvidence is missing schema fields: "
                        f"{', '.join(sorted(missing_edible_fields))}"
                    )
            if (
                not isinstance(edible, dict)
                or not isinstance(edible.get("kind"), str)
                or edible.get("kind") not in EDIBLE_FRACTION_EVIDENCE_KINDS
            ):
                errors.append(f"{ingredient_prefix}.edibleFractionEvidence is invalid")
            elif edible.get("kind") == "foodCompositionRecord":
                fraction = edible.get("fraction")
                food_record = known_food_records.get(food_id) if isinstance(food_id, int) else None
                if (
                    match_status != "exact"
                    or food_record is None
                    or edible.get("foodID") != food_id
                    or isinstance(fraction, bool)
                    or not isinstance(fraction, (int, float))
                    or not math.isfinite(fraction)
                    or not 0 <= fraction <= 1
                    or not all(
                        isinstance(edible.get(field), str) and edible[field].strip()
                        for field in (
                            "sourceID",
                            "sourceRecordID",
                            "sourceVersion",
                            "licenseStatus",
                            "licenseSPDX",
                        )
                    )
                    or (food_record is not None and (
                        edible.get("sourceID") != food_record.get("sourceID")
                        or edible.get("sourceRecordID") != food_record.get("sourceRecordID")
                        or edible.get("sourceVersion") != food_record.get("sourceVersion")
                        or edible.get("licenseStatus") != "verified"
                        or edible.get("licenseSPDX") != food_record.get("_verifiedLicenseSPDX")
                        or edible.get("redistributionAllowed") is not True
                        or food_record.get("_verifiedRedistributionAllowed") is not True
                        or food_record.get("_verifiedDataRole") != "food-composition"
                        or not math.isclose(
                            float(fraction),
                            food_record["edible"] / 100.0,
                            abs_tol=1e-12,
                        )
                    ))
                    or edible.get("reason") is not None
                ):
                    errors.append(f"{ingredient_prefix} has invalid linked edible-fraction evidence")
            elif (
                match_status == "exact"
                or food_id is not None
                or edible.get("fraction") is not None
                or edible.get("foodID") is not None
                or any(edible.get(field) is not None for field in (
                    "sourceID", "sourceRecordID", "sourceVersion", "licenseStatus", "licenseSPDX"
                ))
                or edible.get("redistributionAllowed") is not None
                or not isinstance(edible.get("reason"), str)
                or not edible["reason"].strip()
            ):
                errors.append(f"{ingredient_prefix} unknown edible-fraction evidence must remain explicit and value-free")

            mass_basis = ingredient.get("massBasis")
            mass_evidence = ingredient.get("massBasisEvidence")
            if (
                not isinstance(mass_basis, str)
                or mass_basis not in MASS_BASES
                or not isinstance(mass_evidence, dict)
                or not {"kind", "sourceText"}.issubset(mass_evidence)
                or not isinstance(mass_evidence.get("kind"), str)
                or mass_evidence.get("kind") not in MASS_BASIS_EVIDENCE_KINDS
            ):
                errors.append(f"{ingredient_prefix} mass-basis evidence is invalid")
            elif mass_basis in {"raw", "cooked"}:
                provenance_source_text = provenance.get("sourceText") if isinstance(provenance, dict) else None
                if (
                    mass_evidence.get("kind") != "explicitSourceCue"
                    or not isinstance(mass_evidence.get("sourceText"), str)
                    or not mass_evidence["sourceText"].strip()
                    or not isinstance(provenance_source_text, str)
                    or mass_evidence["sourceText"] not in provenance_source_text
                ):
                    errors.append(f"{ingredient_prefix} known mass basis lacks explicit source text")
            elif mass_evidence.get("kind") != "unknown" or mass_evidence.get("sourceText") is not None:
                errors.append(f"{ingredient_prefix} unknown mass basis must not invent source evidence")

            role = ingredient.get("role")
            role_evidence = ingredient.get("roleEvidence")
            if not isinstance(role, str) or role not in INGREDIENT_ROLES:
                errors.append(f"{ingredient_prefix}.role is invalid")
            if (
                not isinstance(role_evidence, str)
                or not role_evidence.startswith(ROLE_RULE_VERSION + ":")
            ):
                errors.append(f"{ingredient_prefix}.roleEvidence is missing its classifier version")
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
    if report.get("foodDataSHA256") != food_data_sha256:
        errors.append("import report does not identify the exact bundled food-composition mapping input")
    if report.get("foodSourceManifestSHA256") != food_source_manifest_sha256:
        errors.append("import report does not identify the food-source license/redistribution manifest")
    if report.get("verifiedFoodIDCount") != len(known_food_records):
        errors.append("import report verified food ID count does not match the eligible source rows")
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
    match_counts = Counter(
        ingredient.get("foodMatchStatus", "<missing>")
        for recipe in recipes if isinstance(recipe, dict)
        for ingredient in recipe.get("ingredients", []) if isinstance(ingredient, dict)
    )
    mass_basis_counts = Counter(
        ingredient.get("massBasis", "<missing>")
        for recipe in recipes if isinstance(recipe, dict)
        for ingredient in recipe.get("ingredients", []) if isinstance(ingredient, dict)
    )
    edible_evidence_counts = Counter(
        ingredient.get("edibleFractionEvidence", {}).get("kind", "<missing>")
        for recipe in recipes if isinstance(recipe, dict)
        for ingredient in recipe.get("ingredients", [])
        if isinstance(ingredient, dict) and isinstance(ingredient.get("edibleFractionEvidence"), dict)
    )
    role_counts = Counter(
        ingredient.get("role", "<missing>")
        for recipe in recipes if isinstance(recipe, dict)
        for ingredient in recipe.get("ingredients", []) if isinstance(ingredient, dict)
    )
    for report_key, counts in (
        ("foodMatchCounts", match_counts),
        ("massBasisCounts", mass_basis_counts),
        ("edibleFractionEvidenceCounts", edible_evidence_counts),
        ("ingredientRoleCounts", role_counts),
    ):
        if report.get(report_key) != dict(sorted(counts.items())):
            errors.append(f"import report {report_key} does not match catalog rows")
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
    parser.add_argument("--food-data", type=Path, default=DEFAULT_FOOD_DATA)
    parser.add_argument("--food-sources", type=Path, default=DEFAULT_FOOD_SOURCES)
    parser.add_argument("--verified-food-ids", type=Path, default=DEFAULT_VERIFIED_FOOD_IDS)
    parser.add_argument("--verified-food-records", type=Path, default=DEFAULT_VERIFIED_FOOD_RECORDS)
    args = parser.parse_args()
    try:
        catalog = load_json(args.catalog)
        report = load_json(args.report)
        if not isinstance(catalog, dict) or not isinstance(report, dict):
            raise ValueError("catalog and import report must be JSON objects")
        food_data_bytes = args.food_data.read_bytes()
        food_rows = json.loads(food_data_bytes.decode("utf-8"))
        food_sources_bytes = args.food_sources.read_bytes()
        food_sources_manifest = json.loads(food_sources_bytes.decode("utf-8"))
        verified_sources = load_verified_food_sources(food_sources_manifest)
        verified_food_records = load_verified_food_records(food_rows, verified_sources)
        food_data_sha256 = canonical_json_sha256(food_data_bytes)
        food_source_manifest_sha256 = canonical_json_sha256(food_sources_bytes)
        expected_food_records = verified_food_records_projection(verified_food_records)
        expected_food_records_bytes = deterministic_json_bytes(expected_food_records)
        bundled_food_records_bytes = args.verified_food_records.read_bytes()
        if bundled_food_records_bytes != expected_food_records_bytes:
            raise ValueError(
                "verified_food_records.json does not exactly match the production-eligible seed rows and source manifest"
            )
        verified_food_records_sha256 = canonical_json_sha256(bundled_food_records_bytes)
        errors = validate(
            catalog,
            report,
            verified_food_records,
            food_data_sha256,
            food_source_manifest_sha256,
        )
        ids_manifest = load_json(args.verified_food_ids)
        expected_ids_manifest = {
            "schemaVersion": 2,
            "foodDataSHA256": verified_food_records_sha256,
            "seedFoodDataSHA256": food_data_sha256,
            "foodSourceManifestSHA256": food_source_manifest_sha256,
            "foodIDs": sorted(verified_food_records),
        }
        if ids_manifest != expected_ids_manifest:
            errors.append("verified_food_ids.json does not match the verified source/seed food records")
        project_spec = PROJECT_SPEC.read_text(encoding="utf-8")
        if "Densoso/Resources/FoodData/verified_food_ids.json" not in project_spec:
            errors.append("project.yml must bundle the verified food ID manifest for runtime catalog checks")
        if "Densoso/Resources/FoodData/verified_food_records.json" not in project_spec:
            errors.append("project.yml must bundle the verified food source records for runtime catalog checks")
    except (OSError, ValueError, json.JSONDecodeError) as error:
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
