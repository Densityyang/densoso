#!/usr/bin/env python3
"""Build a deterministic, source-attributed recipe-prior catalog from HowToCook.

This script extracts dish names, ingredient labels, raw source quantity text and
coarse cooking-method evidence. It intentionally does not calculate nutrition
or convert a recipe quantity into a user's consumed grams.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MANIFEST = ROOT / "Densoso/Resources/FoodData/recipe_sources.json"
DEFAULT_OUTPUT = ROOT / "Densoso/Resources/FoodData/recipe_priors.json"
DEFAULT_REPORT = ROOT / "Densoso/Resources/FoodData/recipe_prior_import_report.json"
DEFAULT_FOOD_DATA = ROOT / "Densoso/Resources/seed_foods.json"
DEFAULT_FOOD_SOURCES = ROOT / "Densoso/Resources/FoodData/sources.json"
DEFAULT_VERIFIED_FOOD_IDS = ROOT / "Densoso/Resources/FoodData/verified_food_ids.json"
DEFAULT_VERIFIED_FOOD_RECORDS = ROOT / "Densoso/Resources/FoodData/verified_food_records.json"

CATEGORY_MAP = {
    "vegetable_dish": "vegetable",
    "meat_dish": "meat",
    "aquatic": "aquatic",
    "breakfast": "breakfast",
    "staple": "staple",
    "soup": "soup",
    "semi-finished": "semiFinished",
    "dessert": "dessert",
    "drink": "drink",
    "condiment": "condiment",
}
MINIMUM_RECIPE_COUNT = 100
MAXIMUM_INGREDIENTS = 40
ROLE_RULE_VERSION = "recipe-ingredient-role-v1"
NOTE_PREFIX_RE = re.compile(r"^(?:注|备注|说明|提示)\s*[:：，,]|^注意\s*[:：，,]")
TOOL_PREFIX_RE = re.compile(
    r"^(?:工具|工具清单|所需工具|准备工具|需要工具|必备工具|厨具|器具)\s*[:：]"
)
INGREDIENT_GROUP_PREFIX_RE = re.compile(r"^(?:主料|辅料|原料)\s*[:：]\s*")
EQUIPMENT_TERMS = (
    "菜刀",
    "砧板",
    "笊篱",
    "锅铲",
    "炒锅",
    "平底锅",
    "砂锅",
    "煎锅",
    "蒸锅",
    "高压锅",
    "电饭锅",
    "锅盖",
    "锅具",
    "空气炸锅",
    "微波炉",
    "烤箱",
    "烤盘",
    "烤架",
    "烤网",
    "保鲜膜",
    "料理机",
    "搅拌机",
    "容器",
    "筛网",
    "筛子",
    "打蛋器",
    "锡纸",
    "烘焙纸",
    "油纸",
    "饭盒",
    "量杯",
    "量勺",
    "手套",
)

HEADING_RE = re.compile(r"^(#{1,6})\s+(.+?)\s*#*\s*$", re.MULTILINE)
LIST_RE = re.compile(r"^\s*[-*+]\s+(.+?)\s*$")
QUANTITY_RE = re.compile(
    r"(?<![\d/])(?P<first>(?:\d+(?:\.\d+)?\s+\d+(?:\.\d+)?\s*/\s*[1-9]\d*(?:\.\d+)?|"
    r"\d+(?:\.\d+)?\s*/\s*[1-9]\d*(?:\.\d+)?|\d+(?:\.\d+)?))"
    r"\s*(?P<unit>千克|公斤|kg|克|g|毫升|ml|mL|升|L|"
    r"个|颗|只|根|片|瓣|把|袋|勺|杯|碗|斤|两|枚|条|块|张|份)",
    re.IGNORECASE,
)
RANGE_RE = re.compile(r"(?P<low>\d+(?:\.\d+)?)\s*(?:-|–|~|～|至|到)\s*(?P<high>\d+(?:\.\d+)?)")
COOKING_METHODS = (
    ("coldDress", ("凉拌", "拌菜")),
    ("deepFry", ("油炸", "煎炸", "炸鸡", "炸鱼", "炸虾", "炸肉", "炸鲜奶", "炸饼", "炸薯", "炸丸子", "炸洋葱")),
    ("dryFry", ("煎", "干煸", "干锅")),
    ("stirFry", ("爆炒", "炒")),
    ("braise", ("红烧", "卤", "焖", "酱烧")),
    ("steam", ("蒸",)),
    ("boil", ("水煮", "煮", "汆")),
    ("roast", ("烤",)),
    ("stew", ("炖", "煲", "汤")),
)


def git_output(source_root: Path, *args: str) -> str:
    return subprocess.run(
        ["git", "-C", str(source_root), *args],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
    ).stdout.strip()


def git_blob_contents(
    source_root: Path,
    revision: str,
    paths: list[Path],
) -> dict[str, bytes]:
    relative_paths = [path.relative_to(source_root).as_posix() for path in paths]
    requests = "".join(f"{revision}:{path}\n" for path in relative_paths).encode("utf-8")
    result = subprocess.run(
        ["git", "-C", str(source_root), "cat-file", "--batch"],
        check=True,
        input=requests,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    ).stdout
    blobs: dict[str, bytes] = {}
    cursor = 0
    for relative_path in relative_paths:
        header_end = result.find(b"\n", cursor)
        if header_end < 0:
            raise ValueError(f"Git returned an incomplete source blob header for {relative_path}")
        header = result[cursor:header_end].decode("ascii", errors="strict").split()
        if len(header) != 3 or header[1] != "blob":
            raise ValueError(f"pinned source record is not a Git blob: {relative_path}")
        size = int(header[2])
        blob_start = header_end + 1
        blob_end = blob_start + size
        if blob_end >= len(result) or result[blob_end : blob_end + 1] != b"\n":
            raise ValueError(f"Git returned an incomplete source blob for {relative_path}")
        blobs[relative_path] = result[blob_start:blob_end]
        cursor = blob_end + 1
    if cursor != len(result):
        raise ValueError("Git returned unexpected data after the pinned source blobs")
    return blobs


def load_source_manifest(path: Path) -> dict[str, Any]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict) or data.get("schemaVersion") != 1:
        raise ValueError("recipe source manifest must use schemaVersion 1")
    source = data.get("source")
    if not isinstance(source, dict):
        raise ValueError("recipe source manifest is missing its source object")
    required = (
        "sourceID",
        "sourceURL",
        "sourceVersion",
        "retrievedAt",
        "licenseSPDX",
        "dataRole",
        "redistributionAllowed",
        "verificationStatus",
        "licenseURL",
    )
    if any(not source.get(field) for field in required):
        raise ValueError("recipe source manifest contains an empty required provenance field")
    if source["dataRole"] != "recipe-prior":
        raise ValueError("HowToCook must be used only as a recipe-prior source")
    if source["licenseSPDX"] != "Unlicense" or source["verificationStatus"] != "verified":
        raise ValueError("source license must be verified as Unlicense")
    if source["redistributionAllowed"] is not True:
        raise ValueError("production recipe priors require a redistributable source")
    if not re.fullmatch(r"[0-9a-f]{40}", source["sourceVersion"]):
        raise ValueError("sourceVersion must be a full pinned Git commit SHA")
    return source


def verify_source_checkout(source_root: Path, source: dict[str, Any]) -> None:
    revision = git_output(source_root, "rev-parse", "HEAD")
    if revision != source["sourceVersion"]:
        raise ValueError(
            f"source checkout revision {revision} does not match pinned {source['sourceVersion']}"
        )
    dirty_source = git_output(
        source_root,
        "status",
        "--porcelain",
        "--untracked-files=all",
        "--",
        "dishes",
        "LICENSE",
    )
    if dirty_source:
        raise ValueError(
            "source checkout has modified or untracked dish/license files; "
            "refusing to attribute working-tree content to the pinned commit"
        )
    license_text = git_output(source_root, "show", f"{revision}:LICENSE")
    if "free and unencumbered software" not in license_text.lower():
        raise ValueError("pinned LICENSE does not match the verified Unlicense text")


def markdown_sections(text: str) -> list[tuple[int, str, str]]:
    headings = list(HEADING_RE.finditer(text))
    sections: list[tuple[int, str, str]] = []
    for index, heading in enumerate(headings):
        level = len(heading.group(1))
        next_parent = next(
            (candidate for candidate in headings[index + 1 :] if len(candidate.group(1)) <= level),
            None,
        )
        end = next_parent.start() if next_parent else len(text)
        title = heading.group(2).strip()
        sections.append((level, title, text[heading.end() : end]))
    return sections


def section_matches(title: str, terms: tuple[str, ...]) -> bool:
    normalized = re.sub(r"[\s\W_]+", "", title).lower()
    return any(term in normalized for term in terms)


def clean_markdown(value: str) -> str:
    value = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", value)
    value = re.sub(r"<[^>]+>", "", value)
    value = value.replace("`", "").replace("**", "").replace("__", "")
    return re.sub(r"\s+", " ", value).strip(" \t\r\n*_")


def quantity_text_review_reason(value: str) -> str | None:
    matches = list(QUANTITY_RE.finditer(value))
    if re.search(r"[;；]", value):
        return "multipleSourceQuantityLines"
    formula = bool(re.search(r"份数|\*|/|向上取整|向下取整|按口味|适量", value))
    if len(matches) > 1 or (formula and RANGE_RE.search(value)):
        return "ambiguousQuantityExpression"
    return None


def quantity_text_needs_review(value: str) -> bool:
    return quantity_text_review_reason(value) is not None


def parse_quantity(raw: str | None) -> dict[str, Any]:
    if not raw:
        return {"kind": "notSpecifiedInSource", "sourceText": None}
    source_text = clean_markdown(raw)
    formula = bool(re.search(r"份数|\*|/|向上取整|向下取整|按口味|适量", source_text))
    matches = list(QUANTITY_RE.finditer(source_text))
    if quantity_text_needs_review(source_text):
        return {"kind": "sourceTextOnly", "sourceText": source_text}
    range_match = RANGE_RE.search(source_text)
    if not matches:
        return {
            "kind": "sourceTextOnly",
            "sourceText": source_text,
        }

    match = matches[0]
    unit = match.group("unit").lower()
    normalized_unit = {
        "千克": "kg",
        "公斤": "kg",
        "克": "g",
        "毫升": "ml",
        "升": "L",
        "斤": "jin",
        "两": "liang",
    }.get(unit, unit)
    number_text = match.group("first").strip()
    if " " in number_text and "/" in number_text:
        whole_text, fraction_text = number_text.split(None, 1)
        numerator_text, denominator_text = fraction_text.split("/", 1)
        value = float(whole_text) + float(numerator_text) / float(denominator_text)
    elif "/" in number_text:
        numerator_text, denominator_text = number_text.split("/", 1)
        value = float(numerator_text) / float(denominator_text)
    else:
        value = float(number_text)
    if not math.isfinite(value) or value <= 0:
        return {"kind": "sourceTextOnly", "sourceText": source_text}
    evidence: dict[str, Any] = {
        "kind": "formula" if formula else "sourceQuantity",
        "sourceText": source_text,
        "value": value,
        "upperValue": None,
        "unit": normalized_unit,
    }
    if range_match and not formula:
        lower_value = float(range_match.group("low"))
        upper_value = float(range_match.group("high"))
        if (
            not math.isfinite(lower_value)
            or not math.isfinite(upper_value)
            or lower_value <= 0
            or upper_value < lower_value
        ):
            return {"kind": "sourceTextOnly", "sourceText": source_text}
        evidence["value"] = lower_value
        evidence["upperValue"] = upper_value
        evidence["kind"] = "sourceRange"
    return evidence


def split_inline_quantity(raw_label: str) -> tuple[str, str | None, bool]:
    """Split a plainly positioned source quantity from a list item label.

    Only a single quantity at the start/end of the label, or a quantity-only
    terminal parenthetical, is separated. Compound amounts and prose whose
    ingredient identity is unclear stay intact for human review.
    """
    source_text = clean_markdown(raw_label)
    matches = list(QUANTITY_RE.finditer(source_text))
    if not matches:
        return source_text, None, False
    if len(matches) != 1 or quantity_text_review_reason(source_text):
        return source_text, None, True

    match = matches[0]
    range_match = RANGE_RE.search(source_text)
    quantity_start = range_match.start() if range_match else match.start()
    quantity_text = source_text[quantity_start : match.end()].strip()
    before = source_text[:quantity_start]
    after = source_text[match.end() :]

    # A terminal parenthetical containing only the quantity is unambiguous:
    # e.g. "番茄（2个）". Parentheticals with notes or multiple amounts stay
    # in the review path.
    if before.endswith(("（", "(")) and after.startswith(("）", ")")):
        trailing = after[1:].strip(" 。．")
        name = before[:-1].strip()
        if name and not trailing:
            return name, quantity_text, False

    # A source note may trail an otherwise clear amount, e.g.
    # "五花肉 500g（肥瘦相间）". Keep the complete list item as evidence
    # while separating only the source-backed amount and ingredient label.
    if after.startswith(("（", "(")):
        closing = "）" if after.startswith("（") else ")"
        close_index = after.find(closing, 1)
        trailing = after[close_index + 1 :].strip(" 。．") if close_index >= 0 else "x"
        note = after[1:close_index].strip() if close_index >= 0 else ""
        name = before.strip(" ：:，,")
        if name and not trailing and note and not QUANTITY_RE.search(note):
            return name, quantity_text, False

    # Accept source labels such as "鸡蛋：1 个" or "鸡蛋 1 个".
    if not after.strip(" 。．"):
        name = before.strip(" ：:，,")
        if name:
            return name, quantity_text, False

    # Some source records place the amount before the ingredient, e.g.
    # "125ml 淡奶油". Require a plain food label after the amount.
    if not before.strip():
        name = after.strip(" ：:，,")
        if name and not re.search(r"[，,。；;]", name):
            return name, quantity_text, False

    # In optional/approximate parentheticals, a quantity at the very end is
    # still source evidence (e.g. "酸笋（可选，50g）"). Ignore only a short,
    # explicit qualifier; descriptive or multi-value notes remain review rows.
    parenthesis_index = max(before.rfind("（"), before.rfind("("))
    if parenthesis_index > 0 and after.startswith(("）", ")")):
        name = before[:parenthesis_index].strip(" ：:，,")
        qualifier = before[parenthesis_index + 1 :].strip(" ，,：: ")
        trailing = after[1:].strip(" 。．")
        if (
            name
            and not trailing
            and re.fullmatch(r"(?:可选|任选|备选|约|大约|约为|大致)?", qualifier)
        ):
            return name, quantity_text, False

    # A range followed by a short explanatory clause can still retain a
    # source-backed amount when the ingredient label is clearly before it.
    if before.strip() and re.match(r"^[，,；;。]", after):
        name = before.strip(" ：:，,")
        if name and not re.match(r"^(?:根据|可根据|按照|加入|增加|添加|取|准备)", name):
            return name, quantity_text, False

    return source_text, None, True


def normalized_text(value: str) -> str:
    return re.sub(r"[\s\W_]+", "", value).lower()


def ingredient_key(value: str) -> str:
    value = re.sub(r"（[^）]*可选[^）]*）|\([^)]*optional[^)]*\)", "", value, flags=re.I)
    return normalized_text(value)


def is_equipment_label(value: str) -> bool:
    # A food ingredient may mention the tool used to prepare it in a parenthetical
    # note, e.g. "清水（蒸锅用）" or "东北米（推荐用电饭煲煮）". Classify by the
    # row's leading subject; only container descriptions are recognized by their
    # explicit subject phrase when the equipment noun appears later in the row.
    subject = re.split(r"[（(]", value, maxsplit=1)[0].strip()
    if any(term in subject for term in EQUIPMENT_TERMS):
        return True
    if subject in {"刀", "铲", "勺", "筷子", "碗", "盆", "锅"}:
        return True
    if re.match(r"^(?:盆|碗|锅)(?:$|[（(]|一个|两个|一把|[0-9])", subject):
        return True
    return bool(
        "容器" in value
        and re.match(r"^(?:一个|一只|一台|准备一个|装成品的)", subject)
    )


def _ingredient_labels(raw_label: str) -> list[str]:
    label = INGREDIENT_GROUP_PREFIX_RE.sub("", raw_label).strip()
    if not label:
        return []
    # Enumeration punctuation separates source-listed ingredients. Alternative
    # wording remains one source row so the choice is not silently resolved.
    if "、" in label and not re.search(r"或者|任选", label):
        parts = [part.strip() for part in label.split("、")]
        if len(parts) > 1 and all(parts):
            return parts
    return [label]


def extract_ingredient_rows(
    sections: list[tuple[int, str, str]],
    source_record_id: str,
    review_rows: list[dict[str, str]],
    quantity_review_rows: list[dict[str, str]],
) -> list[dict[str, Any]]:
    ingredient_sections = [
        body
        for _level, title, body in sections
        if section_matches(title, ("必备原料", "所需食材", "原料和工具", "食材和调料", "食材清单", "配料"))
    ]
    rows: list[dict[str, Any]] = []
    seen: set[str] = set()
    for body in ingredient_sections:
        for line in body.splitlines():
            match = LIST_RE.match(line)
            if not match:
                continue
            raw_label = clean_markdown(match.group(1))
            if not raw_label or len(raw_label) > 160:
                continue
            if NOTE_PREFIX_RE.match(raw_label):
                review_rows.append({
                    "sourceRecordID": source_record_id,
                    "sourceText": raw_label,
                    "reason": "instructionOrNote",
                })
                continue
            if TOOL_PREFIX_RE.match(raw_label):
                review_rows.append({
                    "sourceRecordID": source_record_id,
                    "sourceText": raw_label,
                    "reason": "explicitToolLine",
                })
                continue

            for ingredient_label in _ingredient_labels(raw_label):
                source_name, inline_quantity, ambiguous_inline = split_inline_quantity(ingredient_label)
                if ambiguous_inline:
                    quantity_review_rows.append({
                        "sourceRecordID": source_record_id,
                        "sourceName": source_name,
                        "sourceText": ingredient_label,
                        "reason": "ambiguousQuantityExpression",
                    })
                if is_equipment_label(ingredient_label):
                    review_rows.append({
                        "sourceRecordID": source_record_id,
                        "sourceText": ingredient_label,
                        "reason": "recognizedEquipmentTerm",
                    })
                    continue
                key = ingredient_key(ingredient_label)
                if not key or key in seen:
                    continue
                seen.add(key)
                rows.append(
                    {
                        "sourceName": source_name,
                        "sourceText": ingredient_label,
                        "isOptional": bool(re.search(r"可选|任选|备选|可依口味", ingredient_label)),
                        "isAlternative": bool(re.search(r"或者|或|/|等|任选", raw_label)),
                        "quantityEvidence": (
                            parse_quantity(ingredient_label)
                            if inline_quantity is not None
                            else {
                                "kind": "sourceTextOnly",
                                "sourceText": ingredient_label,
                            }
                            if ambiguous_inline
                            else {"kind": "notSpecifiedInSource", "sourceText": None}
                        ),
                    }
                )
    return rows


def ingredient_terms(source_name: str) -> list[str]:
    terms = [source_name]
    terms.extend(re.findall(r"[（(]([^）)]*)[）)]", source_name))
    expanded: list[str] = []
    for term in terms:
        expanded.extend(re.split(r"(?:别称[:：]?|或者|或|/|、|，|,)", term))
    return list(dict.fromkeys(term.strip() for term in expanded if len(normalized_text(term.strip())) >= 2))


def canonical_json_sha256(raw: bytes) -> str:
    source_text = raw.decode("utf-8")
    canonical_bytes = source_text.replace("\r\n", "\n").replace("\r", "\n").encode("utf-8")
    return hashlib.sha256(canonical_bytes).hexdigest()


def load_verified_food_sources(path: Path) -> tuple[dict[str, dict[str, Any]], str]:
    raw = path.read_bytes()
    manifest = json.loads(raw.decode("utf-8"))
    if not isinstance(manifest, dict) or manifest.get("schemaVersion") != 1:
        raise ValueError("food source manifest must declare schemaVersion 1")
    sources = manifest.get("sources")
    if not isinstance(sources, list):
        raise ValueError("food source manifest is missing its sources array")

    eligible: dict[str, dict[str, Any]] = {}
    all_source_ids: set[str] = set()
    for index, source in enumerate(sources):
        if not isinstance(source, dict):
            raise ValueError(f"food source manifest entry {index} must be an object")
        source_id = source.get("sourceID")
        if not isinstance(source_id, str) or not source_id.strip() or source_id in all_source_ids:
            raise ValueError(f"food source manifest entry {index} has a missing or duplicate sourceID")
        all_source_ids.add(source_id)
        if source.get("verificationStatus") != "verified" or source.get("redistributionAllowed") is not True:
            continue
        if (
            not isinstance(source.get("licenseSPDX"), str)
            or not source["licenseSPDX"].strip()
            or not isinstance(source.get("licenseURL"), str)
            or not source["licenseURL"].strip()
            or not isinstance(source.get("sourceVersion"), str)
            or not source["sourceVersion"].strip()
            or source.get("dataRole") != "food-composition"
            or not isinstance(source.get("dataType"), str)
            or not source["dataType"].strip()
        ):
            raise ValueError(f"verified redistributable food source {source_id} lacks food-role/license/version provenance")
        eligible[source_id] = source
    if not eligible:
        raise ValueError("food source manifest has no verified redistributable food records")
    return eligible, canonical_json_sha256(raw)


def load_food_composition(path: Path) -> tuple[list[dict[str, Any]], str]:
    raw = path.read_bytes()
    source_text = raw.decode("utf-8")
    items = json.loads(source_text)
    if not isinstance(items, list) or not items:
        raise ValueError("food composition input must be a non-empty array")
    ids: set[int] = set()
    for index, item in enumerate(items):
        if not isinstance(item, dict):
            raise ValueError(f"food composition row {index} must be an object")
        food_id = item.get("id")
        edible = item.get("edible")
        if isinstance(food_id, bool) or not isinstance(food_id, int) or food_id <= 0 or food_id in ids:
            raise ValueError(f"food composition row {index} has a missing, invalid, or duplicate ID")
        if isinstance(edible, bool) or not isinstance(edible, int) or not 0 <= edible <= 100:
            raise ValueError(f"food composition row {index} has an invalid edible percentage")
        if not isinstance(item.get("name"), str) or not item["name"].strip():
            raise ValueError(f"food composition row {index} has no canonical name")
        if not isinstance(item.get("sourceID"), str) or not item["sourceID"].strip():
            raise ValueError(f"food composition row {index} has no sourceID")
        ids.add(food_id)
    return items, canonical_json_sha256(raw)


def build_food_name_index(
    items: list[dict[str, Any]],
    verified_sources: dict[str, dict[str, Any]],
) -> tuple[dict[str, list[dict[str, Any]]], list[dict[str, Any]]]:
    index: dict[str, list[dict[str, Any]]] = {}
    verified_food_records: list[dict[str, Any]] = []
    seen_source_records: set[tuple[str, str]] = set()
    for item in items:
        source_id = item.get("sourceID")
        if not isinstance(source_id, str) or not source_id.strip():
            raise ValueError(f"food composition row {item.get('id')} has no sourceID")
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
            raise ValueError(
                f"verified food source row {item['id']} has incomplete or inconsistent row provenance"
            )
        source_record_key = (source_id, item["sourceRecordID"])
        if source_record_key in seen_source_records:
            raise ValueError(f"verified food source repeats source record {source_record_key!r}")
        seen_source_records.add(source_record_key)
        indexed_item = {
            **item,
            "_verifiedLicenseSPDX": source["licenseSPDX"],
            "_verifiedRedistributionAllowed": source["redistributionAllowed"],
        }
        verified_food_records.append({
            "id": item["id"],
            "sourceID": item["sourceID"],
            "sourceRecordID": item["sourceRecordID"],
            "sourceVersion": item["sourceVersion"],
            "sourceDataType": item["sourceDataType"],
            "licenseStatus": item["licenseStatus"],
            "licenseSPDX": source["licenseSPDX"],
            "redistributionAllowed": source["redistributionAllowed"],
            "dataRole": source["dataRole"],
            "edible": item["edible"],
        })
        names = [item["name"]]
        aliases = item.get("alias")
        if isinstance(aliases, str):
            names.extend(aliases.split("|"))
        elif isinstance(aliases, list):
            names.extend(alias for alias in aliases if isinstance(alias, str))
        for name in names:
            key = normalized_text(name)
            if key:
                index.setdefault(key, []).append(indexed_item)
    verified_food_records.sort(key=lambda record: record["id"])
    return index, verified_food_records


def match_food_record(source_name: str, food_index: dict[str, list[dict[str, Any]]]) -> tuple[str, dict[str, Any] | None]:
    matched: dict[int, dict[str, Any]] = {}
    for term in ingredient_terms(source_name):
        for item in food_index.get(normalized_text(term), []):
            matched[item["id"]] = item
    if len(matched) == 1:
        return "exact", next(iter(matched.values()))
    if len(matched) > 1:
        return "ambiguous", None
    return "unmapped", None


def classify_mass_basis(source_text: str) -> tuple[str, dict[str, Any]]:
    cooked_patterns = (
        r"(?:^|[（(])熟(?:[）)]|$)",
        r"^熟(?:米饭|面条|面|饭|肉|鸡蛋|蛋|土豆|红薯|豆腐)",
        r"\b(?:cooked|prepared)\b",
    )
    raw_patterns = (
        r"(?:^|[（(])生(?:[）)]|$)",
        r"^生(?:米|肉|鸡蛋|蛋|鱼|虾|猪肉|牛肉|羊肉)",
        r"\b(?:raw|uncooked)\b",
    )
    if any(re.search(pattern, source_text, flags=re.IGNORECASE) for pattern in cooked_patterns):
        return "cooked", {"kind": "explicitSourceCue", "sourceText": source_text}
    if any(re.search(pattern, source_text, flags=re.IGNORECASE) for pattern in raw_patterns):
        return "raw", {"kind": "explicitSourceCue", "sourceText": source_text}
    return "unknown", {"kind": "unknown", "sourceText": None}


OIL_TERMS = (
    "食用油", "菜籽油", "花生油", "玉米油", "大豆油", "豆油", "芝麻油", "香油", "葱油",
    "辣椒油", "植物油", "猪油", "牛油", "黄油", "橄榄油", "椰子油", "色拉油", "酥油",
    "油脂", "油菜籽油", "米糠油",
)
SEASONING_TERMS = (
    "盐", "糖", "酱油", "生抽", "老抽", "醋", "料酒", "味精", "鸡精", "胡椒", "花椒",
    "八角", "桂皮", "香叶", "豆瓣酱", "蚝油", "芝麻酱", "番茄酱", "咖喱", "淀粉", "生粉",
    "蜂蜜", "腐乳", "孜然", "五香粉", "辣椒粉", "调味", "味噌", "酱",
)


def classify_ingredient_role(source_name: str) -> tuple[str, str]:
    normalized = normalized_text(source_name)
    if normalized == "油":
        return "oil", f"{ROLE_RULE_VERSION}:exact-oil"
    oil_match = next((term for term in OIL_TERMS if normalized_text(term) in normalized), None)
    if oil_match:
        return "oil", f"{ROLE_RULE_VERSION}:oil-term:{oil_match}"
    seasoning_match = next(
        (term for term in SEASONING_TERMS if normalized_text(term) in normalized),
        None,
    )
    if seasoning_match:
        return "seasoning", f"{ROLE_RULE_VERSION}:seasoning-term:{seasoning_match}"
    return "ingredient", f"{ROLE_RULE_VERSION}:default-ingredient"


def enrich_ingredient(
    ingredient: dict[str, Any],
    recipe_source: dict[str, Any],
    source_record_id: str,
    food_index: dict[str, list[dict[str, Any]]],
) -> dict[str, Any]:
    source_name = ingredient["sourceName"]
    source_text = ingredient["sourceText"]
    match_status, food = match_food_record(source_name, food_index)
    role, role_evidence = classify_ingredient_role(source_name)
    mass_basis, mass_evidence = classify_mass_basis(source_text)

    food_id: int | None = food["id"] if food is not None else None
    edible_evidence: dict[str, Any]
    if food is None:
        reason = "ambiguousFoodCompositionMatch" if match_status == "ambiguous" else "noExactFoodCompositionMatch"
        edible_evidence = {
            "kind": "unknown",
            "fraction": None,
            "foodID": None,
            "sourceID": None,
            "sourceRecordID": None,
            "sourceVersion": None,
            "licenseStatus": None,
                "licenseSPDX": None,
                "redistributionAllowed": None,
            "reason": reason,
        }
    else:
        source_record = food.get("sourceRecordID")
        source_id = food.get("sourceID")
        source_version = food.get("sourceVersion")
        license_status = food.get("licenseStatus")
        if (
            isinstance(source_record, str)
            and source_record.strip()
            and isinstance(source_id, str)
            and source_id.strip()
            and isinstance(source_version, str)
            and source_version.strip()
            and license_status == "verified"
            and food.get("_verifiedRedistributionAllowed") is True
            and isinstance(food.get("_verifiedLicenseSPDX"), str)
            and food["_verifiedLicenseSPDX"].strip()
        ):
            edible_evidence = {
                "kind": "foodCompositionRecord",
                "fraction": food["edible"] / 100.0,
                "foodID": food_id,
                "sourceID": source_id,
                "sourceRecordID": source_record,
                "sourceVersion": source_version,
                "licenseStatus": license_status,
                "licenseSPDX": food["_verifiedLicenseSPDX"],
                "redistributionAllowed": True,
                "reason": None,
            }
        else:
            edible_evidence = {
                "kind": "unknown",
                "fraction": None,
                "foodID": None,
                "sourceID": None,
                "sourceRecordID": None,
                "sourceVersion": None,
                "licenseStatus": None,
                "licenseSPDX": None,
                "redistributionAllowed": None,
                "reason": "foodCompositionProvenanceNotVerified",
            }

    source_ingredient = {key: value for key, value in ingredient.items() if key != "sourceText"}
    return {
        **source_ingredient,
        "foodID": food_id,
        "foodMatchStatus": match_status,
        "edibleFractionEvidence": edible_evidence,
        "massBasis": mass_basis,
        "massBasisEvidence": mass_evidence,
        "role": role,
        "roleEvidence": role_evidence,
        "sourceProvenance": {
            "sourceID": recipe_source["sourceID"],
            "sourceRecordID": source_record_id,
            "sourceVersion": recipe_source["sourceVersion"],
            "sourceText": source_text,
        },
    }


def extract_calculation_lines(
    sections: list[tuple[int, str, str]],
    ingredients: list[dict[str, Any]],
) -> list[tuple[str, str]]:
    lines: list[tuple[str, str]] = []
    for _level, title, body in sections:
        if not section_matches(title, ("计算", "用量", "比例")):
            continue
        for line in body.splitlines():
            match = LIST_RE.match(line)
            if not match:
                continue
            raw = clean_markdown(match.group(1))
            if "=" in raw:
                name, value = raw.split("=", 1)
                name = clean_markdown(name).strip(" ：:（）() ")
                value = clean_markdown(value)
            else:
                raw_key = normalized_text(raw)
                found: list[tuple[str, str]] = []
                for ingredient in ingredients:
                    for term in ingredient_terms(ingredient["sourceName"]):
                        term_key = normalized_text(term)
                        if raw_key.startswith(term_key):
                            found.append((ingredient["sourceName"], term))
                            break
                if found:
                    longest_match = max(len(normalized_text(term)) for _name, term in found)
                    found = [
                        item for item in found
                        if len(normalized_text(item[1])) == longest_match
                    ]
                unique_names = {name for name, _term in found}
                if len(unique_names) != 1:
                    continue
                name = next(iter(unique_names))
                matched_term = next(term for candidate, term in found if candidate == name)
                raw_position = raw.find(matched_term)
                value = raw[raw_position + len(matched_term) :].strip(" ：:（）() ")
                value = clean_markdown(value)
            if name and value:
                lines.append((name, value))
    return lines


def attach_quantity_evidence(
    ingredients: list[dict[str, Any]],
    sections: list[tuple[int, str, str]],
    source_record_id: str,
    quantity_review_rows: list[dict[str, str]],
) -> None:
    calculation_lines = extract_calculation_lines(sections, ingredients)
    quantities_by_ingredient: dict[int, list[str]] = {
        index: [] for index in range(len(ingredients))
    }
    for source_name, source_quantity in calculation_lines:
        source_key = ingredient_key(source_name)
        exact_matches = [
            index
            for index, ingredient in enumerate(ingredients)
            if ingredient_key(ingredient["sourceName"]) == source_key
        ]
        if len(exact_matches) == 1:
            quantities_by_ingredient[exact_matches[0]].append(source_quantity)
            continue
        candidates = [
            index
            for index, ingredient in enumerate(ingredients)
            if (key := ingredient_key(ingredient["sourceName"]))
            and source_key
            and (key in source_key or source_key in key)
        ]
        if len(candidates) == 1:
            quantities_by_ingredient[candidates[0]].append(source_quantity)
            continue
        quantity_review_rows.append({
            "sourceRecordID": source_record_id,
            "sourceName": source_name,
            "sourceText": source_quantity,
            "reason": "ambiguousIngredientMatch" if candidates else "unmatchedIngredientName",
        })

    for index, ingredient in enumerate(ingredients):
        matches = quantities_by_ingredient[index]
        if matches:
            inline_evidence = ingredient["quantityEvidence"]
            inline_text = (
                inline_evidence.get("sourceText")
                if inline_evidence["kind"] != "notSpecifiedInSource"
                else None
            )
            source_text = "; ".join(dict.fromkeys(
                ([inline_text] if inline_text else []) + matches
            ))
            if (review_reason := quantity_text_review_reason(source_text)):
                quantity_review_rows.append({
                    "sourceRecordID": source_record_id,
                    "sourceName": ingredient["sourceName"],
                    "sourceText": source_text,
                    "reason": review_reason,
                })
            if inline_text and matches:
                quantity_review_rows.append({
                    "sourceRecordID": source_record_id,
                    "sourceName": ingredient["sourceName"],
                    "sourceText": source_text,
                    "reason": "multipleSourceQuantityLines",
                })
                ingredient["quantityEvidence"] = {
                    "kind": "sourceTextOnly",
                    "sourceText": source_text,
                }
            else:
                ingredient["quantityEvidence"] = parse_quantity(source_text)


def cooking_method(text: str, category: str) -> tuple[str, str]:
    title_match = re.search(r"^#\s+(.+?)\s*$", text, re.MULTILINE)
    title = clean_markdown(title_match.group(1)) if title_match else ""
    matched = [method for method, terms in COOKING_METHODS if any(term in title for term in terms)]
    # “煎炸” is a deep-frying cue, not simultaneous pan-frying and deep-frying.
    if "煎炸" in title:
        matched = [method for method in matched if method != "dryFry"]
    # Air-fryer recipes are not evidence of deep-frying; preserve them as unknown
    # until this catalog has an explicit air-fry cooking-method contract.
    if "空气炸锅" in title:
        matched = [method for method in matched if method != "deepFry"]
    if len(matched) == 1:
        return matched[0], f"dish-title:{title}"
    if len(matched) > 1:
        return "unknown", f"ambiguous-title:{title}"
    if category == "soup":
        return "stew", f"category-prior:{category}"
    return "unknown", f"no-specific-title-cue:{title or 'missing-title'}"


def recipe_coverage_summary(recipes: list[dict[str, Any]]) -> dict[str, Any]:
    cooking_method_counts = Counter(recipe["cookingMethod"] for recipe in recipes)
    rice_count = sum("饭" in recipe["canonicalDishName"] for recipe in recipes)
    noodle_suffixes = (
        "面条", "拉面", "刀削面", "意大利面", "意面", "方便面", "热干面", "炸酱面",
        "汤面", "炒面", "烩面", "河粉", "米粉", "粉丝", "米线", "粉条", "凉粉", "面",
    )
    noodle_count = sum(
        any(recipe["canonicalDishName"].endswith(suffix) for suffix in noodle_suffixes)
        and not recipe["canonicalDishName"].endswith("面包")
        for recipe in recipes
    )
    porridge_count = sum(
        "粥" in recipe["canonicalDishName"] or "稀饭" in recipe["canonicalDishName"]
        for recipe in recipes
    )
    composite_count = sum(
        len({
            normalized_text(ingredient["sourceName"])
            for ingredient in recipe["ingredients"]
            if ingredient["role"] == "ingredient"
            and not ingredient["isOptional"]
            and not ingredient["isAlternative"]
        }) >= 2
        for recipe in recipes
    )
    return {
        "cookingMethodCounts": dict(sorted(cooking_method_counts.items())),
        "unknownCookingMethodCount": cooking_method_counts.get("unknown", 0),
        "unknownCookingMethodRecords": sorted(
            recipe["sourceRecordID"]
            for recipe in recipes
            if recipe["cookingMethod"] == "unknown"
        ),
        "recipeCoverageCounts": {
            "rice": rice_count,
            "noodles": noodle_count,
            "porridge": porridge_count,
            "composite": composite_count,
        },
    }


def canonical_name(text: str, source_path: Path) -> str:
    match = re.search(r"^#\s+(.+?)\s*$", text, re.MULTILINE)
    candidate = clean_markdown(match.group(1)) if match else source_path.stem
    candidate = re.sub(r"(?:的)?(?:制作)?方法$|的做法$|做法$", "", candidate).strip()
    return candidate or source_path.stem


def import_recipes(
    source_root: Path,
    source: dict[str, Any],
    food_index: dict[str, list[dict[str, Any]]],
) -> tuple[
    list[dict[str, Any]],
    list[dict[str, str]],
    list[dict[str, str]],
    list[dict[str, str]],
]:
    dishes_root = source_root / "dishes"
    if not dishes_root.is_dir():
        raise ValueError("source checkout is missing dishes/")
    records: list[dict[str, Any]] = []
    failures: list[dict[str, str]] = []
    review_rows: list[dict[str, str]] = []
    quantity_review_rows: list[dict[str, str]] = []
    canonical_names: set[str] = set()
    all_paths = sorted(dishes_root.rglob("*.md"), key=lambda path: path.as_posix().casefold())
    source_blobs = git_blob_contents(source_root, source["sourceVersion"], all_paths)
    for path in all_paths:
        relative = path.relative_to(source_root).as_posix()
        category_folder = path.relative_to(dishes_root).parts[0]
        category = CATEGORY_MAP.get(category_folder)
        if not category:
            failures.append({"sourceRecordID": relative, "reason": "unsupportedCategory"})
            continue
        try:
            text = path.read_text(encoding="utf-8-sig")
        except (OSError, UnicodeDecodeError):
            failures.append({"sourceRecordID": relative, "reason": "unreadableMarkdown"})
            continue
        sections = markdown_sections(text)
        name = canonical_name(text, path)
        name_key = normalized_text(name)
        if name_key in canonical_names:
            failures.append({"sourceRecordID": relative, "reason": "duplicateCanonicalName"})
            continue
        ingredients = extract_ingredient_rows(
            sections, relative, review_rows, quantity_review_rows
        )
        if len(ingredients) < 2:
            failures.append({"sourceRecordID": relative, "reason": "fewerThanTwoIngredientRows"})
            continue
        if len(ingredients) > MAXIMUM_INGREDIENTS:
            failures.append({"sourceRecordID": relative, "reason": "tooManyIngredientRows"})
            continue
        canonical_names.add(name_key)
        attach_quantity_evidence(ingredients, sections, relative, quantity_review_rows)
        ingredients = [
            enrich_ingredient(ingredient, source, relative, food_index)
            for ingredient in ingredients
        ]
        method, method_evidence = cooking_method(text, category)
        serving_match = re.search(r"([^。\n]{0,80}(?:一份|份数|人食用)[^。\n]{0,80})", text)
        servings_text = clean_markdown(serving_match.group(1)) if serving_match else None
        # Hash the pinned Git blob, not checkout bytes, so line-ending conversion
        # cannot change the source-record fingerprint.
        source_blob = source_blobs[relative]
        source_hash = hashlib.sha256(source_blob).hexdigest()
        records.append(
            {
                "id": f"{source['sourceID']}:{relative}",
                "canonicalDishName": name,
                "aliases": [],
                "category": category,
                # The pinned source does not provide a trustworthy cuisine-region field.
                "cuisineRegion": None,
                "cookingMethod": method,
                "cookingMethodEvidence": method_evidence,
                "ingredients": ingredients,
                "servingsSourceText": servings_text,
                "cookedYieldEvidence": {"kind": "notSpecifiedInSource", "sourceText": None},
                "householdMeasures": [],
                "oilRetention": {"kind": "notSpecifiedInSource", "sourceText": None},
                "sourceID": source["sourceID"],
                "sourceRecordID": relative,
                "sourceVersion": source["sourceVersion"],
                "licenseStatus": "verified",
                "licenseSPDX": source["licenseSPDX"],
                "confidenceGrade": "moderate" if any(
                    item["quantityEvidence"]["kind"] not in ("notSpecifiedInSource", "sourceTextOnly")
                    for item in ingredients
                ) else "weak",
                "sourceRecordSHA256": source_hash,
                "isNutritionAuthority": False,
            }
        )
    return records, failures, review_rows, quantity_review_rows


def json_bytes(value: Any) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(json_bytes(value))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-repo", type=Path, required=True, help="Local HowToCook checkout at the pinned commit")
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--food-data", type=Path, default=DEFAULT_FOOD_DATA)
    parser.add_argument("--food-sources", type=Path, default=DEFAULT_FOOD_SOURCES)
    parser.add_argument("--verified-food-ids-output", type=Path, default=DEFAULT_VERIFIED_FOOD_IDS)
    parser.add_argument("--verified-food-records-output", type=Path, default=DEFAULT_VERIFIED_FOOD_RECORDS)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    args = parser.parse_args()

    try:
        source = load_source_manifest(args.manifest)
        verified_food_sources, food_sources_sha256 = load_verified_food_sources(args.food_sources)
        food_items, seed_food_data_sha256 = load_food_composition(args.food_data)
        food_index, verified_food_records = build_food_name_index(food_items, verified_food_sources)
        verified_food_records_file = {"schemaVersion": 1, "records": verified_food_records}
        verified_food_records_bytes = json_bytes(verified_food_records_file)
        food_data_sha256 = canonical_json_sha256(verified_food_records_bytes)
        verified_food_ids = [record["id"] for record in verified_food_records]
        verify_source_checkout(args.source_repo, source)
        recipes, failures, review_rows, quantity_review_rows = import_recipes(
            args.source_repo, source, food_index
        )
        quantity_counts: Counter[str] = Counter(
            ingredient["quantityEvidence"]["kind"]
            for recipe in recipes
            for ingredient in recipe["ingredients"]
        )
        ingredient_count = sum(len(recipe["ingredients"]) for recipe in recipes)
        food_match_counts = Counter(
            ingredient["foodMatchStatus"]
            for recipe in recipes
            for ingredient in recipe["ingredients"]
        )
        mass_basis_counts = Counter(
            ingredient["massBasis"]
            for recipe in recipes
            for ingredient in recipe["ingredients"]
        )
        edible_fraction_evidence_counts = Counter(
            ingredient["edibleFractionEvidence"]["kind"]
            for recipe in recipes
            for ingredient in recipe["ingredients"]
        )
        ingredient_role_counts = Counter(
            ingredient["role"]
            for recipe in recipes
            for ingredient in recipe["ingredients"]
        )
        report = {
            "schemaVersion": 1,
            "sourceID": source["sourceID"],
            "sourceVersion": source["sourceVersion"],
            "licenseSPDX": source["licenseSPDX"],
            "scannedCount": len(list((args.source_repo / "dishes").rglob("*.md"))),
            "acceptedCount": len(recipes),
            "rejectedCount": len(failures),
            "rejections": failures,
            "ingredientRowCount": ingredient_count,
            "quantityEvidenceCounts": dict(sorted(quantity_counts.items())),
            "foodDataSHA256": seed_food_data_sha256,
            "foodSourceManifestSHA256": food_sources_sha256,
            "verifiedFoodIDCount": len(verified_food_ids),
            "foodMatchCounts": dict(sorted(food_match_counts.items())),
            "massBasisCounts": dict(sorted(mass_basis_counts.items())),
            "edibleFractionEvidenceCounts": dict(sorted(edible_fraction_evidence_counts.items())),
            "ingredientRoleCounts": dict(sorted(ingredient_role_counts.items())),
            **recipe_coverage_summary(recipes),
            "reviewRowCount": len(review_rows),
            "reviewRows": review_rows,
            "quantityReviewRowCount": len(quantity_review_rows),
            "quantityReviewRows": quantity_review_rows,
            "status": "PASS" if len(recipes) >= MINIMUM_RECIPE_COUNT else "FAIL",
        }
        write_json(args.output, {
            "schemaVersion": 2,
            "dataRole": "recipe-prior",
            "source": source,
            "recipes": recipes,
        })
        write_json(args.report, report)
        write_json(args.verified_food_ids_output, {
            "schemaVersion": 2,
            "foodDataSHA256": food_data_sha256,
            "seedFoodDataSHA256": seed_food_data_sha256,
            "foodSourceManifestSHA256": food_sources_sha256,
            "foodIDs": verified_food_ids,
        })
        args.verified_food_records_output.parent.mkdir(parents=True, exist_ok=True)
        args.verified_food_records_output.write_bytes(verified_food_records_bytes)
        print(json.dumps({key: report[key] for key in (
            "status",
            "sourceVersion",
            "scannedCount",
            "acceptedCount",
            "rejectedCount",
            "ingredientRowCount",
            "quantityEvidenceCounts",
            "foodMatchCounts",
            "massBasisCounts",
            "edibleFractionEvidenceCounts",
            "ingredientRoleCounts",
            "cookingMethodCounts",
            "recipeCoverageCounts",
            "unknownCookingMethodCount",
            "reviewRowCount",
            "quantityReviewRowCount",
        )}, ensure_ascii=False, sort_keys=True))
        return 0 if report["status"] == "PASS" else 1
    except (OSError, ValueError, subprocess.CalledProcessError, json.JSONDecodeError) as error:
        print(f"recipe-prior import failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
