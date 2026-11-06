#!/usr/bin/env python3
"""Validate final software acceptance boundaries and cumulative gate ordering."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
GATES = (
    "foundation",
    "domain-persistence",
    "agent-provider",
    "speech",
    "meal-capture",
    "healthkit",
    "health-intelligence",
    "watch",
    "integration",
)

RESULT_TO_STATUS = {
    "success": "PASS",
    "failure": "FAIL",
    "cancelled": "BLOCKED",
    "skipped": "NOT RUN",
}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--report")
    parser.add_argument("--workflow-sha", default="unavailable")
    parser.add_argument("--pr-head-sha", default="unavailable")
    parser.add_argument("--run-url", default="unavailable")
    parser.add_argument("--artifact-root", default="")
    parser.add_argument(
        "--gate-result",
        action="append",
        default=[],
        metavar="JOB=RESULT",
        help="Upstream GitHub Actions job result, repeated once for every Gate 1-9 job.",
    )
    args = parser.parse_args()
    errors: list[str] = []

    gate_results: dict[str, str] = {}
    for item in args.gate_result:
        name, separator, result = item.partition("=")
        name = name.strip()
        result = result.strip().lower()
        if not separator or name not in GATES:
            errors.append(f"invalid Gate result {item!r}; expected JOB=RESULT for Gates 1-9")
            continue
        if name in gate_results:
            errors.append(f"duplicate Gate result for {name}")
            continue
        if result not in RESULT_TO_STATUS:
            errors.append(f"unsupported result {result!r} for Gate job {name}")
            continue
        gate_results[name] = result

    gate_statuses = []
    for number, name in enumerate(GATES, start=1):
        result = gate_results.get(name, "unknown")
        status = RESULT_TO_STATUS.get(result, "NOT RUN")
        if result != "success":
            if result == "unknown":
                reason = "upstream GitHub Actions job result was not supplied"
            elif result == "failure":
                reason = "upstream GitHub Actions job failed"
            elif result == "cancelled":
                reason = "upstream GitHub Actions job was cancelled"
            else:
                reason = "upstream GitHub Actions job was skipped"
            errors.append(f"Gate {number} ({name}) is {status}: {reason}")
        else:
            reason = "upstream GitHub Actions job succeeded"
        gate_statuses.append({
            "gate": number,
            "job": name,
            "jobOutcome": result,
            "status": status,
            "reason": reason,
        })

    workflow_path = ROOT / ".github/workflows/build.yml"
    docs_path = ROOT / "docs/gates/gate-10-final-acceptance.md"
    workflow = workflow_path.read_text(encoding="utf-8") if workflow_path.is_file() else ""
    docs = docs_path.read_text(encoding="utf-8") if docs_path.is_file() else ""
    if not workflow:
        errors.append("missing .github/workflows/build.yml")
    if not docs:
        errors.append("missing docs/gates/gate-10-final-acceptance.md")

    if "final-acceptance:" not in workflow or "name: gate-10-final-acceptance" not in workflow:
        errors.append("missing final-acceptance CI job")
    final_acceptance_job = workflow.split("  final-acceptance:", 1)
    final_acceptance_job = final_acceptance_job[1].split("  gate-11-ai-native-health-loop:", 1)[0] if len(final_acceptance_job) == 2 else ""
    if "needs:" not in final_acceptance_job or "integration" not in final_acceptance_job:
        errors.append("final acceptance must depend on Gate 9 integration")
    for gate in GATES:
        if gate not in final_acceptance_job:
            errors.append(f"final acceptance must receive the {gate} job result directly")
    for number in range(1, len(GATES) + 1):
        if f"GATE_{number:02d}_RESULT" not in final_acceptance_job:
            errors.append(f"final acceptance is missing the Gate {number} result input")
    for token in (
        "ACCEPTANCE_WORKFLOW_SHA",
        "ACCEPTANCE_PR_HEAD_SHA",
        "--workflow-sha",
        "--pr-head-sha",
    ):
        if token not in workflow:
            errors.append(f"final acceptance workflow is missing {token}")
    for gate in GATES:
        if f"needs: {GATES[GATES.index(gate) - 1]}" not in workflow and gate != "foundation":
            errors.append(f"missing cumulative dependency before {gate}")
        if f"gate-0{GATES.index(gate) + 1}-{gate}-results" not in workflow:
            errors.append(f"missing artifact name for gate {gate}")

    required = (
        "Gates 1–9 pass in one workflow run against the same tested commit",
        "the PR source",
        "No model, photo, speech or Watch path",
        "blocked-by-signing",
        "physical iPhone",
        "physical Watch",
        "Protected food OCR",
        "not",
        "Privacy-focused diagnostics export",
        "DiagnosticsExportPrivacyTests",
    )
    for needle in required:
        if needle not in docs:
            errors.append(f"final acceptance contract is missing {needle}")
    gate9_validator_path = ROOT / "scripts/validate_phase9_integration.py"
    gate9_validator = gate9_validator_path.read_text(encoding="utf-8") if gate9_validator_path.is_file() else ""
    if "DiagnosticsExportPrivacyTests.swift" not in gate9_validator:
        errors.append("Gate 9 static validation must require the diagnostics privacy tests")
    if '"diagnosticsExportWhitelistRequired": True' not in gate9_validator:
        errors.append("Gate 9 report must identify the diagnostics export whitelist contract")
    if "gh pr merge" in workflow.lower() or "gh pr ready" in workflow.lower():
        errors.append("the workflow must not merge the PR or remove its Draft boundary")
    if "upload-artifact@v4" not in workflow:
        errors.append("gate evidence artifacts are not uploaded")

    artifact_root = ROOT / args.artifact_root if args.artifact_root else None
    required_artifacts = {
        "gate-01-foundation-results": (
            "Gate01UnitTests.xcresult", "Gate01UITests.xcresult", "Gate01Screenshots",
            "gate01-domain.log", "gate01-ios18-build.log", "gate01-unit-tests.log",
            "gate01-ui-tests.log", "gate01-watch-build.log", "gate01-xcodegen-determinism.log",
        ),
        "gate-02-domain-persistence-results": (
            "Gate02PersistenceTests.xcresult", "Gate02Reports", "gate02-domain.log",
            "gate02-persistence-tests.log", "gate02-test-summary.json",
        ),
        "gate-03-agent-provider-results": (
            "Gate03AgentProviderTests.xcresult", "gate03-domain.log",
            "gate03-agent-provider-tests.log", "gate03-test-summary.json", "gate03-fixture-summary.json",
        ),
        "gate-04-speech-results": (
            "Gate04SpeechTests.xcresult", "gate04-domain.log", "gate04-speech-tests.log",
            "gate04-test-summary.json", "gate04-fixture-summary.json",
        ),
        "gate-05-meal-capture-results": (
            "Gate05MealCaptureTests.xcresult", "gate05-domain.log", "gate05-meal-capture-tests.log",
            "gate05-test-summary.json", "gate05-fixture-summary.json",
        ),
        "gate-06-healthkit-results": (
            "Gate06HealthKitTests.xcresult", "gate06-domain.log", "gate06-healthkit-tests.log",
            "gate06-test-summary.json", "gate06-contract-summary.json",
        ),
        "gate-07-health-intelligence-results": (
            "Gate07HealthIntelligenceTests.xcresult", "gate07-domain.log",
            "gate07-health-intelligence-tests.log", "gate07-test-summary.json", "gate07-contract-summary.json",
        ),
        "gate-08-watch-results": (
            "Gate08WatchTests.xcresult", "gate08-domain.log", "gate08-iphone-build.log",
            "gate08-watch-build.log", "gate08-watch-tests.log", "gate08-test-summary.json",
            "gate08-contract-summary.json",
        ),
        "gate-09-integration-results": (
            "Gate09IntegrationTests.xcresult",
            "Gate09UITests.xcresult",
            "Gate09Screenshots",
            "gate09-domain.log",
            "gate09-integration-tests.log",
            "gate09-ui-tests.log",
            "gate09-unit-test-summary.json",
            "gate09-ui-test-summary.json",
            "gate09-coverage-summary.txt",
            "gate09-contract-summary.json",
        ),
    }
    expected_artifacts = list(required_artifacts)
    artifact_statuses: dict[str, dict[str, object]] = {
        name: {"status": "NOT CHECKED", "missingPaths": []}
        for name in required_artifacts
    }
    if artifact_root is not None:
        for name, required_paths in required_artifacts.items():
            artifact_directory = artifact_root / name
            if not artifact_directory.is_dir():
                errors.append(f"missing downloaded artifact {name}")
                artifact_statuses[name] = {
                    "status": "MISSING",
                    "missingPaths": list(required_paths),
                }
                continue
            missing_paths = []
            for relative in required_paths:
                if not (artifact_directory / relative).exists():
                    errors.append(f"artifact {name} is missing {relative}")
                    missing_paths.append(relative)
            artifact_statuses[name] = {
                "status": "MISSING" if missing_paths else "PRESENT",
                "missingPaths": missing_paths,
            }
    else:
        errors.append("--artifact-root is required to verify Gates 1-9 evidence")

    report = {
        "status": "PASS" if not errors else "FAIL",
        "scope": "phase-10-final-software-acceptance-rollup",
        "allNineGatesRequired": True,
        "workflowCommitSHA": args.workflow_sha,
        "prHeadSHA": args.pr_head_sha,
        "workflowRun": args.run_url,
        "gateResults": gate_statuses,
        "expectedArtifacts": expected_artifacts,
        "artifacts": artifact_statuses,
        "errors": errors,
        "signedDeviceAcceptance": "not-claimed",
        "testFlightOrProduction": "not-claimed",
        "prBoundary": "OPEN-Draft-blocked-by-signing",
        "protectedOCRRead": False,
        "diagnosticsExportPrivacyContract": "required-by-gate-9",
    }
    if args.report:
        report_path = Path(args.report)
        report_path.parent.mkdir(parents=True, exist_ok=True)
        report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        print("Phase 10 final-acceptance static contracts: FAIL")
        return 1
    print("Phase 10 final-acceptance static contracts: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
