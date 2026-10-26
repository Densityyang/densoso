#!/usr/bin/env python3
"""Exercise Gate 16 status aggregation and manual-device fail-closed rules."""

from __future__ import annotations

import hashlib
import subprocess
import tempfile
from pathlib import Path

from aggregate_gate16_release_readiness import (
    AUTOMATED_GATES,
    GATE15_REQUIRED_SCENARIOS,
    GATE15_TABLE_HEADERS,
    aggregate_status,
    build_report,
    manual_gate15_status,
    parse_gate_results,
)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"Gate 16 aggregate contract failed: {message}")


def gate15_document(
    status: str,
    tested_source_sha: str = "b" * 40,
    *,
    omit_scenario: str | None = None,
) -> str:
    if status != "PASS":
        return f"Status: {status}\n"
    lines = [
        "Status: PASS",
        "",
        "| " + " | ".join(GATE15_TABLE_HEADERS) + " |",
        "| " + " | ".join("---" for _ in GATE15_TABLE_HEADERS) + " |",
    ]
    for device, scenarios in GATE15_REQUIRED_SCENARIOS.items():
        model = "iPhone 17 Pro" if device == "iPhone" else "Apple Watch Series 11"
        os_version = "iOS 26.1" if device == "iPhone" else "watchOS 26.1"
        for scenario in sorted(scenarios):
            if scenario == omit_scenario:
                continue
            digest = hashlib.sha256(scenario.encode("utf-8")).hexdigest()
            values = (
                device,
                "@device-tester",
                model,
                os_version,
                "1.0.0 (123)",
                tested_source_sha,
                scenario,
                "PASS",
                "2026-10-26T10:00:00Z",
                f"https://github.com/Densityyang/densoso/actions/runs/12345/artifacts/{scenario}",
                digest,
            )
            lines.append("| " + " | ".join(values) + " |")
    return "\n".join(lines) + "\n"


def git(repository: Path, *arguments: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(repository), *arguments],
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


def create_gate15_repository(repository: Path) -> tuple[Path, str, str]:
    repository.mkdir(parents=True)
    git(repository, "init", "-b", "main")
    git(repository, "config", "user.name", "Gate 16 contract")
    git(repository, "config", "user.email", "gate16-contract@example.invalid")
    (repository / "source.swift").write_text("let testedSource = true\n", encoding="utf-8")
    git(repository, "add", "source.swift")
    git(repository, "commit", "-m", "tested source")
    tested_source_sha = git(repository, "rev-parse", "HEAD")

    gate15_path = repository / "docs/gates/gate-15-real-device-acceptance.md"
    gate15_path.parent.mkdir(parents=True)
    gate15_path.write_text(
        gate15_document("PASS", tested_source_sha=tested_source_sha),
        encoding="utf-8",
    )
    git(repository, "add", "docs/gates/gate-15-real-device-acceptance.md")
    git(repository, "commit", "-m", "record device acceptance evidence")
    current_workflow_sha = git(repository, "rev-parse", "HEAD")
    return gate15_path, tested_source_sha, current_workflow_sha


def gate15_shell_document() -> str:
    return """Status: PASS

| Device | OS | App | Build | Result | Timestamp | Evidence |
| --- | --- | --- | --- | --- | --- | --- |
| iPhone | pending | Densoso | pending | PASS | pending | signed-device-log |
| Apple Watch | pending | Densoso | pending | PASS | pending | paired-watch-log |
"""


def main() -> int:
    require(aggregate_status(["PASS", "PASS"]) == "PASS", "all required gates passing")
    require(aggregate_status([]) == "BLOCKED", "empty status input fails closed")
    require(aggregate_status(["UNKNOWN"]) == "BLOCKED", "unknown status fails closed")
    require(aggregate_status(["PASS", "NOT_MEASURED"]) == "BLOCKED", "unmeasured required gate blocks")
    require(aggregate_status(["BLOCKED", "FAIL"]) == "FAIL", "failure takes precedence over blocked")
    require(aggregate_status(["NOT RUN"]) == "BLOCKED", "unrun required gate blocks")

    all_passing = parse_gate_results([f"{gate}=PASS" for gate in AUTOMATED_GATES])
    with tempfile.TemporaryDirectory(prefix="densoso-gate16-contract-") as directory:
        repository = Path(directory) / "valid-repository"
        gate15_path, tested_source_sha, current_workflow_sha = create_gate15_repository(repository)
        gate15_path.write_text(gate15_document("NOT RUN"), encoding="utf-8")
        report = build_report(
            run_scope="full",
            results=all_passing,
            gate15_document=gate15_path,
            workflow_sha=current_workflow_sha,
            run_id="12345",
            run_url="https://github.com/example/repo/actions/runs/12345",
            repository_root=repository,
        )
        require(report["automatedChecksStatus"] == "PASS", "automated checks pass independently")
        require(report["releaseReadinessStatus"] == "BLOCKED", "missing Gate 15 blocks release readiness")
        require(report["ready"] is False, "missing Gate 15 never becomes ready")
        require(report["fieldCalibration"]["status"] == "NOT_MEASURED", "calibration remains explicit")

        gate15_path.write_text(
            gate15_document("PASS", tested_source_sha=tested_source_sha),
            encoding="utf-8",
        )
        report = build_report(
            run_scope="full",
            results=all_passing,
            gate15_document=gate15_path,
            workflow_sha=current_workflow_sha,
            run_id="12346",
            run_url="https://github.com/example/repo/actions/runs/12346",
            repository_root=repository,
        )
        require(report["releaseReadinessStatus"] == "PASS", "complete SHA-256-linked scenario evidence permits readiness")
        require(report["ready"] is True, "ready is true only when all required inputs pass")
        require(report["fieldCalibration"]["status"] == "NOT_MEASURED", "field calibration is non-blocking")
        gate15_evidence = report["gates"][-1]["evidence"]
        require(gate15_evidence["testedSourceSHA"] == tested_source_sha, "Gate 15 report records the tested source SHA")
        require(gate15_evidence["currentWorkflowSHA"] == current_workflow_sha, "Gate 15 report records the aggregate workflow SHA")
        require(len(gate15_evidence["scenarios"]["iPhone"]) == 5, "Gate 15 report lists every iPhone scenario")
        require(len(gate15_evidence["scenarios"]["Apple Watch"]) == 5, "Gate 15 report lists every Watch scenario")

        gate15_path.write_text(gate15_shell_document(), encoding="utf-8")
        shell_status, _, _ = manual_gate15_status(gate15_path, current_workflow_sha, repository)
        require(shell_status == "BLOCKED", "old placeholder matrix cannot pass Gate 15")

        gate15_path.write_text(
            gate15_document("PASS", tested_source_sha=tested_source_sha).replace("@device-tester", "@pending"),
            encoding="utf-8",
        )
        placeholder_tester_status, _, _ = manual_gate15_status(gate15_path, current_workflow_sha, repository)
        require(placeholder_tester_status == "BLOCKED", "placeholder tester login cannot pass Gate 15")

        gate15_path.write_text(
            gate15_document("PASS", tested_source_sha=tested_source_sha) + "Status: NOT RUN\n",
            encoding="utf-8",
        )
        duplicate_status, _, _ = manual_gate15_status(gate15_path, current_workflow_sha, repository)
        require(duplicate_status == "BLOCKED", "conflicting Gate 15 status lines block release readiness")

        gate15_path.write_text(
            gate15_document("PASS", tested_source_sha=tested_source_sha, omit_scenario="iphone-healthkit"),
            encoding="utf-8",
        )
        incomplete_status, _, _ = manual_gate15_status(gate15_path, current_workflow_sha, repository)
        require(incomplete_status == "BLOCKED", "incomplete required scenario matrix blocks Gate 15")

        gate15_path.write_text(gate15_document("PASS", tested_source_sha="c" * 40), encoding="utf-8")
        stale_status, _, _ = manual_gate15_status(gate15_path, current_workflow_sha, repository)
        require(stale_status == "BLOCKED", "unavailable tested-source commit is rejected")

        source_changed_repository = Path(directory) / "source-changed-repository"
        changed_doc, changed_tested_sha, _ = create_gate15_repository(source_changed_repository)
        (source_changed_repository / "source.swift").write_text("let changedAfterTesting = true\n", encoding="utf-8")
        git(source_changed_repository, "add", "source.swift")
        git(source_changed_repository, "commit", "-m", "change source after device testing")
        changed_doc.write_text(
            gate15_document("PASS", tested_source_sha=changed_tested_sha),
            encoding="utf-8",
        )
        git(source_changed_repository, "add", "docs/gates/gate-15-real-device-acceptance.md")
        git(source_changed_repository, "commit", "-m", "record evidence after source change")
        changed_current_sha = git(source_changed_repository, "rev-parse", "HEAD")
        changed_status, changed_reason, _ = manual_gate15_status(
            changed_doc,
            changed_current_sha,
            source_changed_repository,
        )
        require(changed_status == "BLOCKED", "source changes after testing block Gate 15")
        require("source.swift" in changed_reason, "source-change blocker identifies changed paths")

        unrelated_repository = Path(directory) / "unrelated-repository"
        unrelated_doc, unrelated_tested_sha, _ = create_gate15_repository(unrelated_repository)
        unrelated_tree = git(unrelated_repository, "write-tree")
        independent_sha = git(
            unrelated_repository,
            "commit-tree",
            unrelated_tree,
            "-m",
            "unrelated current workflow commit",
        )
        git(unrelated_repository, "reset", "--hard", independent_sha)
        unrelated_status, unrelated_reason, _ = manual_gate15_status(
            unrelated_doc,
            independent_sha,
            unrelated_repository,
        )
        require(unrelated_status == "BLOCKED", "unrelated tested-source commit blocks Gate 15")
        require("ancestor" in unrelated_reason, "non-ancestor blocker is explicit")

        focused_repository = Path(directory) / "focused-repository"
        focused_doc, _, focused_current_sha = create_gate15_repository(focused_repository)
        focused_results = parse_gate_results([
            f"{gate}=PASS" for gate in (5, 11, 12, 13, 14, 17, 18, 19)
        ])
        focused = build_report(
            run_scope="focused-pr-tests",
            results=focused_results,
            gate15_document=focused_doc,
            workflow_sha=focused_current_sha,
            run_id="12347",
            run_url="https://github.com/example/repo/actions/runs/12347",
            repository_root=focused_repository,
        )
        require(focused["automatedChecksStatus"] == "PASS", "focused selected gates can pass")
        require(focused["releaseReadinessStatus"] == "BLOCKED", "focused runs cannot imply full release readiness")
        require(focused["ready"] is False, "focused runs never claim full readiness")

    print("Gate 16 aggregate contract: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
