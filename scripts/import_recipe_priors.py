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
    ("deepFry", ("油炸", "炸", "煎炸")),
    ("stirFry", ("炒", "爆炒", "干煸")),
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
    if len(matched) == 1:
        return matched[0], f"dish-title:{title}"
    if len(matched) > 1:
        return "unknown", f"ambiguous-title:{title}"
    if category == "soup":
        return "stew", f"category-prior:{category}"
    return "unknown", f"no-specific-title-cue:{title or 'missing-title'}"


def canonical_name(text: str, source_path: Path) -> str:
    match = re.search(r"^#\s+(.+?)\s*$", text, re.MULTILINE)
    candidate = clean_markdown(match.group(1)) if match else source_path.stem
    candidate = re.sub(r"(?:的)?(?:制作)?方法$|的做法$|做法$", "", candidate).strip()
    return candidate or source_path.stem


def import_recipes(
    source_root: Path,
    source: dict[str, Any],
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


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-repo", type=Path, required=True, help="Local HowToCook checkout at the pinned commit")
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    args = parser.parse_args()

    try:
        source = load_source_manifest(args.manifest)
        verify_source_checkout(args.source_repo, source)
        recipes, failures, review_rows, quantity_review_rows = import_recipes(args.source_repo, source)
        quantity_counts: Counter[str] = Counter(
            ingredient["quantityEvidence"]["kind"]
            for recipe in recipes
            for ingredient in recipe["ingredients"]
        )
        ingredient_count = sum(len(recipe["ingredients"]) for recipe in recipes)
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
            "reviewRowCount": len(review_rows),
            "reviewRows": review_rows,
            "quantityReviewRowCount": len(quantity_review_rows),
            "quantityReviewRows": quantity_review_rows,
            "status": "PASS" if len(recipes) >= MINIMUM_RECIPE_COUNT else "FAIL",
        }
        write_json(args.output, {
            "schemaVersion": 1,
            "dataRole": "recipe-prior",
            "source": source,
            "recipes": recipes,
        })
        write_json(args.report, report)
        print(json.dumps({key: report[key] for key in (
            "status",
            "sourceVersion",
            "scannedCount",
            "acceptedCount",
            "rejectedCount",
            "ingredientRowCount",
            "quantityEvidenceCounts",
            "reviewRowCount",
            "quantityReviewRowCount",
        )}, ensure_ascii=False, sort_keys=True))
        return 0 if report["status"] == "PASS" else 1
    except (OSError, ValueError, subprocess.CalledProcessError, json.JSONDecodeError) as error:
        print(f"recipe-prior import failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
