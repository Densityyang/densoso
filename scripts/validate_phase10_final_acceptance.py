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


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--report")
    parser.add_argument("--workflow-sha", default="unavailable")
    parser.add_argument("--pr-head-sha", default="unavailable")
    parser.add_argument("--run-url", default="unavailable")
    parser.add_argument("--artifact-root", default="")
    args = parser.parse_args()
    errors: list[str] = []

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
    if "needs: integration" not in workflow:
        errors.append("final acceptance must depend on Gate 9 integration")
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
    if artifact_root is not None:
        for name, required_paths in required_artifacts.items():
            artifact_directory = artifact_root / name
            if not artifact_directory.is_dir():
                errors.append(f"missing downloaded artifact {name}")
                continue
            for relative in required_paths:
                if not (artifact_directory / relative).exists():
                    errors.append(f"artifact {name} is missing {relative}")

    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1

    report = {
        "status": "pass",
        "scope": "phase-10-final-software-acceptance-rollup",
        "allNineGatesRequired": True,
        "workflowCommitSHA": args.workflow_sha,
        "prHeadSHA": args.pr_head_sha,
        "workflowRun": args.run_url,
        "artifacts": expected_artifacts if artifact_root is not None else "verified-by-final-CI-job",
        "signedDeviceAcceptance": "not-claimed",
        "testFlightOrProduction": "not-claimed",
        "prBoundary": "OPEN-Draft-blocked-by-signing",
        "protectedOCRRead": False,
        "diagnosticsExportPrivacyContract": "required-by-gate-9",
    }
    if args.report:
        Path(args.report).write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print("Phase 10 final-acceptance static contracts: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
