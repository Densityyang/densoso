#!/usr/bin/env python3
"""Aggregate automated Gate results with the manual Gate 15 device decision.

The script keeps CI health separate from release readiness. A focused run can
pass its selected automated checks while Gate 16 remains BLOCKED because other
required gates or the signed-device evidence have not been completed.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import subprocess
from datetime import datetime
from pathlib import Path
from typing import Any
from urllib.parse import urlparse


ROOT = Path(__file__).resolve().parents[1]
AUTOMATED_GATES = tuple(range(1, 15)) + (17, 18, 19)
CI_RESULT_STATUS = {
    "success": "PASS",
    "failure": "FAIL",
    "cancelled": "BLOCKED",
    "skipped": "NOT RUN",
}
VALID_GATE_STATUSES = {"PASS", "FAIL", "BLOCKED", "NOT RUN", "NOT_MEASURED"}
GATE15_TABLE_HEADERS = (
    "Device",
    "Tester",
    "Model",
    "OS version",
    "App build",
    "Tested Source SHA",
    "Scenario ID",
    "Result",
    "Timestamp",
    "Evidence URL",
    "Evidence SHA-256",
)
GATE15_REQUIRED_SCENARIOS = {
    "iPhone": {
        "iphone-healthkit",
        "iphone-speech-analyzer",
        "iphone-camera-photo",
        "iphone-background",
        "iphone-notifications",
    },
    "Apple Watch": {
        "watch-snapshot",
        "watch-quick-record",
        "watch-offline-queue-replay",
        "watch-reconnect",
        "watch-workoutkit",
    },
}
PLACEHOLDER_VALUES = {"", "pending", "tbd", "n/a", "na", "none", "unknown", "-"}
COMMIT_RE = re.compile(r"^(?:[0-9a-f]{40}|[0-9a-f]{64})$", re.IGNORECASE)
SHA256_RE = re.compile(r"^[0-9a-f]{64}$", re.IGNORECASE)
GITHUB_LOGIN_RE = re.compile(r"^@[A-Za-z0-9-]{1,39}$")


def parse_gate_results(values: list[str]) -> dict[int, str]:
    results: dict[int, str] = {}
    for item in values:
        gate_text, separator, result = item.partition("=")
        if not separator:
            raise ValueError(f"invalid gate result {item!r}; expected GATE=RESULT")
        try:
            gate = int(gate_text)
        except ValueError as error:
            raise ValueError(f"invalid gate number in {item!r}") from error
        if gate not in AUTOMATED_GATES:
            raise ValueError(f"unsupported automated gate number {gate}")
        if gate in results:
            raise ValueError(f"duplicate result for Gate {gate}")
        normalized = result.strip().upper()
        if normalized in VALID_GATE_STATUSES:
            results[gate] = normalized
        else:
            outcome = result.strip().lower()
            if outcome not in CI_RESULT_STATUS:
                raise ValueError(f"unsupported result {result!r} for Gate {gate}")
            results[gate] = CI_RESULT_STATUS[outcome]
    return results


def selected_gates(run_scope: str) -> set[int]:
    if run_scope == "full":
        return set(AUTOMATED_GATES)
    if run_scope == "focused-pr-tests":
        return {5, 11, 12, 13, 14, 17, 18, 19}
    raise ValueError(f"unsupported run scope {run_scope!r}")


def gate_status_records(
    results: dict[int, str], selected: set[int]
) -> list[dict[str, Any]]:
    records = []
    for gate in AUTOMATED_GATES:
        status = results.get(gate)
        if gate not in selected:
            status = "NOT RUN"
            reason = "gate was outside the selected workflow scope"
        elif status is None:
            status = "BLOCKED"
            reason = "selected gate result was not supplied"
        elif status == "PASS":
            reason = "automated gate completed successfully"
        elif status == "FAIL":
            reason = "automated gate failed; inspect its retained evidence"
        elif status == "BLOCKED":
            reason = "automated gate did not complete"
        elif status == "NOT_MEASURED":
            reason = "required gate evidence has not been measured"
        else:
            reason = "automated gate did not run"
        records.append({"gate": gate, "status": status, "reason": reason})
    return records


def _non_placeholder(value: str) -> bool:
    normalized = value.strip().casefold()
    return bool(normalized) and normalized not in PLACEHOLDER_VALUES and not any(
        marker in normalized for marker in ("pending", "tbd", "placeholder", "unknown")
    )


def _timestamp_has_timezone(value: str) -> bool:
    try:
        timestamp = datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
    except ValueError:
        return False
    return timestamp.tzinfo is not None and timestamp.utcoffset() is not None


def _is_separator_row(cells: list[str]) -> bool:
    return all(not cell or set(cell) <= {"-", ":", " "} for cell in cells)


def _valid_evidence_reference(url: str, digest: str) -> bool:
    try:
        parsed = urlparse(url)
        hostname = parsed.hostname
    except ValueError:
        return False
    if parsed.scheme != "https" or not hostname or not SHA256_RE.fullmatch(digest):
        return False
    hostname = hostname.casefold()
    path_parts = [part.casefold() for part in parsed.path.split("/") if part]
    return (
        "." in hostname
        and hostname not in {"example.com", "example.org", "example.net", "localhost"}
        and not hostname.endswith((".example", ".invalid", ".test"))
        and len(path_parts) >= 3
        and not any(part in PLACEHOLDER_VALUES for part in path_parts)
    )


def _check_tested_source_commit(
    repository_root: Path,
    tested_source_sha: str,
    current_workflow_sha: str,
) -> tuple[bool, str]:
    if not COMMIT_RE.fullmatch(tested_source_sha) or not COMMIT_RE.fullmatch(current_workflow_sha):
        return False, "Gate 15 needs full tested-source and current-workflow commit SHAs"

    def git(*arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["git", "-C", str(repository_root), *arguments],
            check=False,
            capture_output=True,
            text=True,
            encoding="utf-8",
        )

    try:
        head = git("rev-parse", "HEAD")
        if head.returncode != 0 or head.stdout.strip().lower() != current_workflow_sha.lower():
            return False, "current workflow SHA does not match the checked-out commit"
        shallow = git("rev-parse", "--is-shallow-repository")
        if shallow.returncode != 0:
            return False, "could not determine whether the checkout contains complete Git history"
        if shallow.stdout.strip().lower() == "true":
            return False, "Git history is shallow; Gate 15 verification requires full history (fetch-depth: 0)"
        tested_commit = git("cat-file", "-e", f"{tested_source_sha}^{{commit}}")
        current_commit = git("cat-file", "-e", f"{current_workflow_sha}^{{commit}}")
        if tested_commit.returncode != 0 or current_commit.returncode != 0:
            return False, "tested-source or current-workflow commit is unavailable in the checkout"
        ancestry = git("merge-base", "--is-ancestor", tested_source_sha, current_workflow_sha)
        if ancestry.returncode != 0:
            return False, "tested-source commit is not an ancestor of the current workflow commit"
        evidence_document = git(
            "diff",
            "--quiet",
            current_workflow_sha,
            "--",
            "docs/gates/gate-15-real-device-acceptance.md",
        )
        if evidence_document.returncode != 0:
            return False, "Gate 15 evidence document does not match the current workflow commit"
        changed_files = git(
            "diff",
            "--name-only",
            "--no-renames",
            tested_source_sha,
            current_workflow_sha,
            "--",
            ".",
            ":(exclude)docs/gates/gate-15-real-device-acceptance.md",
        )
        if changed_files.returncode != 0:
            return False, "could not compare tested-source and current-workflow commits"
        changed = [path for path in changed_files.stdout.splitlines() if path.strip()]
        if changed:
            return False, "source changed after device testing: " + ", ".join(changed[:8])
    except OSError as error:
        return False, f"Git history is unavailable for Gate 15 verification ({type(error).__name__})"
    return True, "tested-source commit is an ancestor and only the Gate 15 evidence document changed"


def manual_gate15_status(
    path: Path,
    current_workflow_sha: str,
    repository_root: Path = ROOT,
) -> tuple[str, str, dict[str, Any]]:
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        return "BLOCKED", f"Gate 15 evidence document is unavailable ({type(error).__name__})", {
            "iPhoneEvidence": False,
            "watchEvidence": False,
        }

    status_lines = [
        line for line in text.splitlines()
        if re.match(r"^\s*Status\s*:", line, re.IGNORECASE)
    ]
    if len(status_lines) != 1:
        return "BLOCKED", "Gate 15 has no recognized human-recorded status", {
            "iPhoneEvidence": False,
            "watchEvidence": False,
        }
    match = re.fullmatch(
        r"\s*Status\s*:\s*(PASS|FAIL|BLOCKED|NOT RUN)(?:\s+[—-].*)?\s*",
        status_lines[0],
        re.IGNORECASE,
    )
    if not match:
        return "BLOCKED", "Gate 15 has no recognized human-recorded status", {
            "iPhoneEvidence": False,
            "watchEvidence": False,
        }
    declared = match.group(1).upper()
    if declared != "PASS":
        return declared, "Gate 15 still requires signed iPhone and paired Watch evidence", {
            "iPhoneEvidence": False,
            "watchEvidence": False,
        }
    expected_document = (
        repository_root / "docs/gates/gate-15-real-device-acceptance.md"
    ).resolve()
    if path.resolve() != expected_document:
        return "BLOCKED", "Gate 15 PASS must be recorded in the repository's canonical evidence document", {
            "iPhoneEvidence": False,
            "watchEvidence": False,
        }

    header_indexes: list[int] = []
    table_rows: list[list[str]] = []
    in_device_table = False
    for line_index, line in enumerate(text.splitlines()):
        if not line.strip().startswith("|"):
            if in_device_table:
                in_device_table = False
            continue
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if tuple(cell.casefold() for cell in cells) == tuple(
            header.casefold() for header in GATE15_TABLE_HEADERS
        ):
            header_indexes.append(line_index)
            in_device_table = True
            continue
        if in_device_table and not _is_separator_row(cells):
            table_rows.append(cells)

    device_rows: dict[str, bool] = {"iPhone": False, "Apple Watch": False}
    if len(header_indexes) != 1:
        return "BLOCKED", "Gate 15 PASS requires one complete structured device evidence table", device_rows
    observed: dict[str, set[str]] = {device: set() for device in GATE15_REQUIRED_SCENARIOS}
    device_metadata: dict[str, tuple[str, str, str]] = {}
    tested_source_sha: str | None = None
    for row_index, cells in enumerate(table_rows, start=1):
        if len(cells) != len(GATE15_TABLE_HEADERS):
            return "BLOCKED", f"Gate 15 evidence row {row_index} has the wrong number of fields", device_rows
        row = dict(zip(GATE15_TABLE_HEADERS, cells, strict=True))
        device = row["Device"]
        scenario = row["Scenario ID"]
        if device not in GATE15_REQUIRED_SCENARIOS or scenario not in GATE15_REQUIRED_SCENARIOS[device]:
            return "BLOCKED", f"Gate 15 evidence row {row_index} names an unsupported device or scenario", device_rows
        if scenario in observed[device]:
            return "BLOCKED", f"Gate 15 contains duplicate evidence for {scenario}", device_rows
        observed[device].add(scenario)

        if row["Result"].upper() != "PASS":
            if row["Result"].upper() == "FAIL":
                return "FAIL", f"Gate 15 scenario {scenario} failed", device_rows
            return "BLOCKED", f"Gate 15 scenario {scenario} has no passing result", device_rows
        for field in ("Model", "OS version", "App build"):
            if not _non_placeholder(row[field]):
                return "BLOCKED", f"Gate 15 scenario {scenario} is missing {field}", device_rows
        metadata = (row["Model"], row["OS version"], row["App build"])
        if device in device_metadata and device_metadata[device] != metadata:
            return "BLOCKED", f"Gate 15 {device} rows do not describe one consistent tested build", device_rows
        device_metadata[device] = metadata
        tester = row["Tester"]
        if (
            not GITHUB_LOGIN_RE.fullmatch(tester)
            or tester[1:].casefold() in {"pending", "tbd", "none", "unknown"}
        ):
            return "BLOCKED", f"Gate 15 scenario {scenario} is missing a tester GitHub login", device_rows
        row_source_sha = row["Tested Source SHA"]
        if not COMMIT_RE.fullmatch(row_source_sha):
            return "BLOCKED", f"Gate 15 scenario {scenario} needs a full tested-source SHA", device_rows
        if tested_source_sha is not None and row_source_sha.lower() != tested_source_sha.lower():
            return "BLOCKED", "Gate 15 scenarios refer to different tested-source commits", device_rows
        tested_source_sha = row_source_sha
        if not _timestamp_has_timezone(row["Timestamp"]):
            return "BLOCKED", f"Gate 15 scenario {scenario} needs an ISO-8601 timestamp with timezone", device_rows
        if not _valid_evidence_reference(row["Evidence URL"], row["Evidence SHA-256"]):
            return "BLOCKED", f"Gate 15 scenario {scenario} needs an HTTPS evidence URL and SHA-256 digest", device_rows

    for device, required_scenarios in GATE15_REQUIRED_SCENARIOS.items():
        if observed[device] != required_scenarios:
            missing = sorted(required_scenarios - observed[device])
            return "BLOCKED", f"Gate 15 {device} evidence is incomplete; missing {missing}", device_rows
        device_rows[device] = True
    if tested_source_sha is None:
        return "BLOCKED", "Gate 15 contains no tested-source commit", device_rows
    commit_valid, commit_reason = _check_tested_source_commit(
        repository_root,
        tested_source_sha,
        current_workflow_sha,
    )
    if not commit_valid:
        return "BLOCKED", commit_reason, device_rows
    evidence = {
        **device_rows,
        "testedSourceSHA": tested_source_sha.lower(),
        "currentWorkflowSHA": current_workflow_sha.lower(),
        "scenarios": {
            device: sorted(scenarios) for device, scenarios in observed.items()
        },
    }
    return "PASS", commit_reason, evidence


def aggregate_status(statuses: list[str]) -> str:
    if not isinstance(statuses, list) or not statuses:
        return "BLOCKED"
    if "FAIL" in statuses:
        return "FAIL"
    if any(
        not isinstance(status, str) or status not in VALID_GATE_STATUSES
        for status in statuses
    ):
        return "BLOCKED"
    if any(status in {"BLOCKED", "NOT RUN"} for status in statuses):
        return "BLOCKED"
    # NOT_MEASURED is valid for the non-blocking field-calibration note, but
    # every selected gate is a required release input and must fail closed.
    if any(status == "NOT_MEASURED" for status in statuses):
        return "BLOCKED"
    return "PASS" if all(status == "PASS" for status in statuses) else "BLOCKED"


def build_report(
    *,
    run_scope: str,
    results: dict[int, str],
    gate15_document: Path,
    workflow_sha: str,
    run_id: str,
    run_url: str,
    repository_root: Path = ROOT,
) -> dict[str, Any]:
    selected = selected_gates(run_scope)
    gate_records = gate_status_records(results, selected)
    automated_status = aggregate_status([
        record["status"] for record in gate_records if record["gate"] in selected
    ])
    gate15, gate15_reason, gate15_evidence = manual_gate15_status(
        gate15_document,
        workflow_sha,
        repository_root,
    )
    release_inputs = [record["status"] for record in gate_records]
    release_inputs.append(gate15)
    release_status = aggregate_status(release_inputs)
    return {
        "schemaVersion": 1,
        "gate": 16,
        "workflow": "V3 Gates",
        "workflowSha": workflow_sha,
        "runId": run_id,
        "runUrl": run_url,
        "runScope": run_scope,
        "automatedChecksStatus": automated_status,
        "releaseReadinessStatus": release_status,
        "ready": release_status == "PASS",
        "fieldCalibration": {
            "status": "NOT_MEASURED",
            "reason": "No real-world labeled meal dataset was supplied; accuracy is not claimed.",
            "nonBlockingForBasicDeterministicEstimation": True,
        },
        "gates": gate_records + [{
            "gate": 15,
            "status": gate15,
            "reason": gate15_reason,
            "evidence": gate15_evidence,
        }],
        "limitations": [
            "Gate 15 is a human-reviewed signed-device acceptance and cannot be passed by Simulator evidence.",
            "The aggregate reports BLOCKED or FAIL when required evidence is missing, unmeasured, or unsuccessful; it never converts NOT RUN to PASS.",
            "A successful Actions job only means this report was generated; release readiness is the explicit releaseReadinessStatus field.",
        ],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-scope", choices=("full", "focused-pr-tests"), default="full")
    parser.add_argument("--gate-result", action="append", default=[], metavar="GATE=RESULT")
    parser.add_argument("--gate15-document", type=Path, default=ROOT / "docs/gates/gate-15-real-device-acceptance.md")
    parser.add_argument("--workflow-sha", default="unavailable")
    parser.add_argument("--run-id", default="unavailable")
    parser.add_argument("--run-url", default="unavailable")
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()

    try:
        results = parse_gate_results(args.gate_result)
        report = build_report(
            run_scope=args.run_scope,
            results=results,
            gate15_document=args.gate15_document,
            workflow_sha=args.workflow_sha,
            run_id=args.run_id,
            run_url=args.run_url,
        )
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    except (OSError, ValueError) as error:
        print(f"Gate 16 aggregate report failed: {error}", file=sys.stderr)
        return 1

    print(
        "Gate 16 release readiness: "
        f"{report['releaseReadinessStatus']} (automated checks: {report['automatedChecksStatus']})"
    )
    # Keep test CI status actionable while preserving Gate 16's fail-closed
    # release state in the report. The automated aggregate fails on test-gate
    # failures; a missing manual device gate leaves releaseReadinessStatus BLOCKED.
    return 0 if report["automatedChecksStatus"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
