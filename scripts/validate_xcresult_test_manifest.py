#!/usr/bin/env python3
"""Validate required XCTest methods against xcresulttool test-results JSON.

Supported input is the structured JSON from:
    xcrun xcresulttool get test-results tests --path <bundle> --format json

The validator trusts only recursive `testNodes` / `children` entries whose
`nodeType` is exactly `Test Case`, with string `name` and `result` fields. It
never infers a test result from a suite node, an identifier, or free-form text.
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from typing import Any


# Xcode 26 wraps the test plan tree in a Unit test bundle node. It is a
# structural container only; test outcomes still come exclusively from the
# descendant Test Case nodes.
CONTAINER_NODE_TYPES = {"Unit test bundle", "Test Plan", "Test Suite"}
CASE_NODE_TYPE = "Test Case"


class ManifestError(Exception):
    """The xcresult JSON does not match the supported structured schema."""


@dataclass(frozen=True)
class TestCase:
    name: str
    identifier: str
    result: str

    def to_json(self) -> dict[str, str]:
        return {
            "name": self.name,
            "nodeIdentifier": self.identifier,
            "result": self.result,
        }


def clean_identifier(value: str) -> str:
    cleaned = value.strip()
    if cleaned.startswith("- [") and cleaned.endswith("]"):
        body = cleaned[3:-1].strip()
        parts = body.rsplit(None, 1)
        cleaned = "/".join(parts) if len(parts) == 2 else body
    if cleaned.endswith("()"):
        cleaned = cleaned[:-2]
    return cleaned


def method_leaf(value: str) -> str:
    cleaned = clean_identifier(value)
    return cleaned.rsplit("/", 1)[-1].rsplit(".", 1)[-1]


def required_matches(required: str, case: TestCase) -> bool:
    wanted = clean_identifier(required)
    candidates = [clean_identifier(case.name)]
    if case.identifier:
        candidates.append(clean_identifier(case.identifier))

    if "/" in wanted:
        return any(candidate == wanted or candidate.endswith("/" + wanted) for candidate in candidates)

    return any(
        candidate == wanted or method_leaf(candidate) == wanted
        for candidate in candidates
    )


def walk_node(node: Any, cases: list[TestCase], recognized_types: set[str]) -> None:
    if not isinstance(node, dict):
        raise ManifestError("testNodes/children entries must be JSON objects")

    node_type = node.get("nodeType")
    if not isinstance(node_type, str):
        raise ManifestError("a test node is missing its string nodeType field")
    recognized_types.add(node_type)

    if node_type == CASE_NODE_TYPE:
        name = node.get("name")
        result = node.get("result")
        identifier = node.get("nodeIdentifier", "")
        if not isinstance(name, str) or not name.strip():
            raise ManifestError("a Test Case node is missing a non-empty string name")
        if not isinstance(result, str) or not result.strip():
            raise ManifestError(f"Test Case {name!r} is missing a string result")
        if not isinstance(identifier, str):
            raise ManifestError(f"Test Case {name!r} has a non-string nodeIdentifier")
        cases.append(TestCase(name=name.strip(), identifier=identifier.strip(), result=result.strip()))
    elif node_type not in CONTAINER_NODE_TYPES:
        raise ManifestError(f"unsupported xcresult test nodeType {node_type!r}")

    children = node.get("children", [])
    if not isinstance(children, list):
        raise ManifestError(f"the children field for {node_type!r} must be an array")
    for child in children:
        walk_node(child, cases, recognized_types)


def extract_test_cases(document: Any) -> list[TestCase]:
    if not isinstance(document, dict):
        raise ManifestError("xcresult JSON root must be an object")
    nodes = document.get("testNodes")
    if not isinstance(nodes, list):
        raise ManifestError("xcresult JSON must contain a testNodes array")

    cases: list[TestCase] = []
    recognized_types: set[str] = set()
    for node in nodes:
        walk_node(node, cases, recognized_types)

    if recognized_types and not recognized_types.intersection(CONTAINER_NODE_TYPES | {CASE_NODE_TYPE}):
        raise ManifestError("no recognized Test Plan, Test Suite, or Test Case nodes were found")
    return cases


def required_item(required: str, cases: list[TestCase]) -> dict[str, Any]:
    matches = sorted(
        (case for case in cases if required_matches(required, case)),
        key=lambda case: (case.identifier, case.name, case.result),
    )
    observed = [case.to_json() for case in matches]
    if not matches:
        return {
            "testMethod": required,
            "observedStatus": "MISSING",
            "summary": "No Test Case node matched this exact test method.",
            "observedResults": [],
        }

    wanted = clean_identifier(required)
    if "/" not in wanted:
        qualified_identities = {
            clean_identifier(case.identifier) if case.identifier else clean_identifier(case.name)
            for case in matches
        }
        if len(qualified_identities) > 1 or (
            len(matches) > 1 and any(not case.identifier for case in matches)
        ):
            identity_summary = ", ".join(sorted(qualified_identities))
            return {
                "testMethod": required,
                "observedStatus": "FAIL",
                "summary": (
                    "The unqualified method name matched multiple test-case identifiers; "
                    f"specify a qualified test method to disambiguate: {identity_summary}."
                ),
                "observedResults": observed,
            }

    counts = Counter(case.result for case in matches)
    if all(case.result == "Passed" for case in matches):
        summary = f"All {len(matches)} matching Test Case node(s) reported Passed."
        status = "PASS"
    else:
        result_summary = ", ".join(
            f"{result}: {count}" for result, count in sorted(counts.items())
        )
        summary = (
            f"{len(matches)} matching Test Case node(s) reported {result_summary}; "
            "every matching case must report Passed."
        )
        status = "FAIL"

    return {
        "testMethod": required,
        "observedStatus": status,
        "summary": summary,
        "observedResults": observed,
    }


def blocked_report(input_path: Path, required: list[str], diagnostic: str) -> dict[str, Any]:
    return {
        "schemaVersion": 1,
        "status": "BLOCKED",
        "schemaStatus": "UNRECOGNIZED",
        "summary": "Could not validate required tests because the input or xcresult schema was unavailable.",
        "input": str(input_path),
        "requiredTests": [
            {
                "testMethod": method,
                "observedStatus": "BLOCKED",
                "summary": diagnostic,
                "observedResults": [],
            }
            for method in required
        ],
        "observedTestCases": [],
        "diagnostics": [diagnostic],
    }


def validate(input_path: Path, required: list[str]) -> dict[str, Any]:
    try:
        document = json.loads(input_path.read_text(encoding="utf-8"))
        cases = extract_test_cases(document)
    except (OSError, UnicodeError, json.JSONDecodeError, ManifestError) as error:
        return blocked_report(input_path, required, str(error))

    results = [required_item(method, cases) for method in required]
    passed = all(item["observedStatus"] == "PASS" for item in results)
    missing_count = sum(item["observedStatus"] == "MISSING" for item in results)
    failed_count = sum(item["observedStatus"] == "FAIL" for item in results)
    if passed:
        summary = f"All {len(results)} required test method(s) have Passed case results."
        status = "PASS"
    else:
        details = []
        if failed_count:
            details.append(f"{failed_count} failed")
        if missing_count:
            details.append(f"{missing_count} missing")
        summary = "Required XCTest manifest failed: " + ", ".join(details) + "."
        status = "FAIL"

    sorted_cases = sorted(cases, key=lambda case: (case.identifier, case.name, case.result))
    return {
        "schemaVersion": 1,
        "status": status,
        "schemaStatus": "RECOGNIZED",
        "summary": summary,
        "input": str(input_path),
        "requiredTests": results,
        "observedTestCases": [case.to_json() for case in sorted_cases],
        "diagnostics": [],
    }


def non_empty_required(value: str) -> str:
    method = value.strip()
    if not method:
        raise argparse.ArgumentTypeError("required test method must not be empty")
    return method


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path, help="xcresulttool test-results JSON file")
    parser.add_argument(
        "--required",
        required=True,
        action="append",
        type=non_empty_required,
        metavar="TEST_METHOD",
        help="required XCTest method; may be repeated",
    )
    parser.add_argument("--report", required=True, type=Path, help="write the stable JSON report here")
    args = parser.parse_args()

    report = validate(args.input, args.required)
    serialized = json.dumps(report, ensure_ascii=False, sort_keys=True, indent=2) + "\n"
    try:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(serialized, encoding="utf-8", newline="\n")
    except OSError as error:
        print(f"cannot write report {args.report}: {error}", file=sys.stderr)
        return 2

    print(serialized, end="")
    return 0 if report["status"] == "PASS" else (2 if report["status"] == "BLOCKED" else 1)


if __name__ == "__main__":
    raise SystemExit(main())
