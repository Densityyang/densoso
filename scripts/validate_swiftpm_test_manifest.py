#!/usr/bin/env python3
"""Validate required SwiftPM XCTest cases from the XCTest runner log.

This reads case-level runner records only, for example:
    Test Case '-[DensosoDomainTests.HealthIntelligenceTests testUnknownCoverage]' passed (0.001 seconds).

Suite summaries, process exit codes, and arbitrary text are not test evidence.
The report's `swiftPackageTestResults` map can be copied into Gate 19's
structured evidence manifest.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Any


ANSI_ESCAPE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
CASE_LINE = re.compile(
    r"^\s*Test Case\s+'(?P<identifier>[^']+)'\s+"
    r"(?P<outcome>started|passed|failed|skipped)\b(?P<suffix>.*)$"
)
BRACKET_IDENTIFIER = re.compile(r"^[-+]\[(?P<type>[^\s\]]+)\s+(?P<method>[^\s\]]+)\]$")
CASE_LINE_SUFFIX = re.compile(
    r"^\s*(?:\([0-9]+(?:\.[0-9]+)?\s+(?:seconds?|s)\))?\.?\s*$"
)
SKIPPED_LINE_SUFFIX = re.compile(
    r"^\s*(?:\([0-9]+(?:\.[0-9]+)?\s+(?:seconds?|s)\))?\.?"
    r"(?:\s+-\s+[^\r\n]+)?\s*$"
)


class LogError(Exception):
    """The log is missing or its XCTest case-line schema is unsupported."""


@dataclass(frozen=True)
class RequiredTest:
    suite: str
    method: str
    original: str


@dataclass(frozen=True)
class CaseEvent:
    module: str
    suite: str
    method: str
    outcome: str
    line_number: int

    @property
    def identity(self) -> tuple[str, str, str]:
        return (self.module, self.suite, self.method)

    def to_json(self) -> dict[str, Any]:
        return {
            "module": self.module,
            "suite": self.suite,
            "testMethod": self.method,
            "outcome": self.outcome,
            "line": self.line_number,
        }


def normalize_method(value: str) -> str:
    method = value.strip()
    if method.endswith("()"):
        method = method[:-2]
    return method


def parse_required(value: str) -> RequiredTest:
    trimmed = value.strip()
    parts = trimmed.split("/")
    if len(parts) != 2 or not all(part.strip() for part in parts):
        raise argparse.ArgumentTypeError("required filter must be Suite/testMethod")
    suite, method = (part.strip() for part in parts)
    method = normalize_method(method)
    return RequiredTest(suite=suite, method=method, original=f"{suite}/{method}")


def parse_case_identifier(identifier: str) -> tuple[str, str, str] | None:
    value = identifier.strip()
    bracket_match = BRACKET_IDENTIFIER.fullmatch(value)
    if bracket_match:
        type_parts = bracket_match.group("type").split(".")
        method = normalize_method(bracket_match.group("method"))
        if len(type_parts) < 2 or not all(type_parts) or not method:
            return None
        return (".".join(type_parts[:-1]), type_parts[-1], method)

    if "/" in value:
        parts = [part for part in value.split("/") if part]
        if len(parts) < 2:
            return None
        method = normalize_method(parts[-1])
        if len(parts) == 2:
            module, suite = "", parts[0]
        else:
            module, suite = "/".join(parts[:-2]), parts[-2]
        if not suite or not method:
            return None
        return (module, suite, method)

    parts = value.split(".")
    if len(parts) >= 2:
        method = normalize_method(parts[-1])
        if len(parts) == 2:
            module, suite = "", parts[0]
        else:
            module, suite = ".".join(parts[:-2]), parts[-2]
        if not suite or not method:
            return None
        return (module, suite, method)
    return None


def parse_case_events(input_path: Path) -> list[CaseEvent]:
    try:
        lines = input_path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as error:
        raise LogError(f"cannot read XCTest runner log: {error}") from error

    events: list[CaseEvent] = []
    malformed_lines: list[int] = []
    for line_number, original_line in enumerate(lines, start=1):
        line = ANSI_ESCAPE.sub("", original_line)
        if not line.lstrip().startswith("Test Case "):
            continue
        match = CASE_LINE.fullmatch(line)
        if match is None:
            malformed_lines.append(line_number)
            continue
        suffix_pattern = (
            SKIPPED_LINE_SUFFIX if match.group("outcome") == "skipped" else CASE_LINE_SUFFIX
        )
        if suffix_pattern.fullmatch(match.group("suffix")) is None:
            malformed_lines.append(line_number)
            continue
        parsed = parse_case_identifier(match.group("identifier"))
        if parsed is None:
            malformed_lines.append(line_number)
            continue
        module, suite, method = parsed
        events.append(
            CaseEvent(
                module=module,
                suite=suite,
                method=method,
                outcome=match.group("outcome"),
                line_number=line_number,
            )
        )

    if malformed_lines:
        rendered_lines = ", ".join(str(number) for number in malformed_lines)
        raise LogError(f"unrecognized case-level XCTest line format at line(s): {rendered_lines}")
    if not events:
        raise LogError("the log contains no recognized case-level XCTest runner lines")
    return events


def group_events(events: list[CaseEvent]) -> list[dict[str, Any]]:
    grouped: dict[tuple[str, str, str], list[CaseEvent]] = defaultdict(list)
    for event in events:
        grouped[event.identity].append(event)

    groups: list[dict[str, Any]] = []
    for (module, suite, method), case_events in sorted(grouped.items()):
        ordered_events = sorted(case_events, key=lambda event: event.line_number)
        groups.append({
            "module": module,
            "suite": suite,
            "testMethod": method,
            "startedCount": sum(event.outcome == "started" for event in ordered_events),
            "results": [
                event.outcome for event in ordered_events if event.outcome != "started"
            ],
            "events": [event.to_json() for event in ordered_events],
        })
    return groups


def result_for_required(required: RequiredTest, events: list[CaseEvent]) -> dict[str, Any]:
    matches = sorted(
        (
            event
            for event in events
            if event.suite == required.suite and event.method == required.method
        ),
        key=lambda event: (event.module, event.line_number, event.outcome),
    )
    observed = [event.to_json() for event in matches]
    if not matches:
        return {
            "testFilter": required.original,
            "observedStatus": "FAIL",
            "summary": "No case-level XCTest record matched this Suite/testMethod filter.",
            "observedResults": [],
        }

    modules = {event.module for event in matches}
    if len(modules) > 1:
        return {
            "testFilter": required.original,
            "observedStatus": "FAIL",
            "summary": "The Suite/testMethod filter matched multiple modules; the result is ambiguous.",
            "observedResults": observed,
        }

    outcomes = [event.outcome for event in matches if event.outcome != "started"]
    started_count = sum(event.outcome == "started" for event in matches)
    if not outcomes:
        return {
            "testFilter": required.original,
            "observedStatus": "BLOCKED",
            "summary": "The required test started but has no terminal passed/failed/skipped record.",
            "observedResults": observed,
        }
    if started_count > len(outcomes):
        return {
            "testFilter": required.original,
            "observedStatus": "BLOCKED",
            "summary": "More started records than terminal records were observed for this required test.",
            "observedResults": observed,
        }
    if any(outcome != "passed" for outcome in outcomes):
        counts: dict[str, int] = {}
        for outcome in outcomes:
            counts[outcome] = counts.get(outcome, 0) + 1
        counts_summary = ", ".join(f"{key}: {counts[key]}" for key in sorted(counts))
        return {
            "testFilter": required.original,
            "observedStatus": "FAIL",
            "summary": f"The required test has non-passing case result(s): {counts_summary}.",
            "observedResults": observed,
        }

    return {
        "testFilter": required.original,
        "observedStatus": "PASS",
        "summary": f"All {len(outcomes)} terminal case result(s) for this test reported passed.",
        "observedResults": observed,
    }


def blocked_report(input_path: Path, required: list[RequiredTest], diagnostic: str) -> dict[str, Any]:
    status_map = {item.original: "BLOCKED" for item in required}
    return {
        "schemaVersion": 1,
        "status": "BLOCKED",
        "summary": "The SwiftPM XCTest log could not be validated.",
        "input": str(input_path),
        "swiftPackageTestResults": status_map,
        "requiredTests": [
            {
                "testFilter": item.original,
                "observedStatus": "BLOCKED",
                "summary": diagnostic,
                "observedResults": [],
            }
            for item in required
        ],
        "observedTestCases": [],
        "diagnostics": [diagnostic],
    }


def validate(input_path: Path, required: list[RequiredTest]) -> dict[str, Any]:
    try:
        events = parse_case_events(input_path)
    except LogError as error:
        return blocked_report(input_path, required, str(error))

    results = [result_for_required(item, events) for item in required]
    statuses = {result["testFilter"]: result["observedStatus"] for result in results}
    if any(status == "FAIL" for status in statuses.values()):
        status = "FAIL"
        summary = "One or more required SwiftPM XCTest filters are missing, ambiguous, or failed."
    elif any(value == "BLOCKED" for value in statuses.values()):
        status = "BLOCKED"
        summary = "One or more required SwiftPM XCTest filters have incomplete execution evidence."
    else:
        status = "PASS"
        summary = f"All {len(results)} required SwiftPM XCTest filter(s) reported passed."

    return {
        "schemaVersion": 1,
        "status": status,
        "summary": summary,
        "input": str(input_path),
        "swiftPackageTestResults": statuses,
        "requiredTests": results,
        "observedTestCases": group_events(events),
        "diagnostics": [],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path, help="SwiftPM XCTest runner log")
    parser.add_argument(
        "--required",
        required=True,
        action="append",
        type=parse_required,
        metavar="SUITE/TEST_METHOD",
        help="exact required Suite/testMethod filter; may be repeated",
    )
    parser.add_argument("--report", required=True, type=Path, help="write Gate 19-compatible JSON here")
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
