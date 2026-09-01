#!/usr/bin/env python3
"""Validate static contracts and fixtures for PLAN_v3 gate-03-agent-provider.

This validator uses explicit paths and never traverses the private OCR source.
Provider runtime behavior is proven by fake-transport Simulator tests, not live API calls.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def require_text(path: Path, needles: list[str], errors: list[str]) -> None:
    if not path.is_file():
        errors.append(f"missing {path.relative_to(ROOT)}")
        return
    text = path.read_text(encoding="utf-8")
    for needle in needles:
        if needle not in text:
            errors.append(f"{path.relative_to(ROOT)} is missing {needle}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--report")
    args = parser.parse_args()
    errors: list[str] = []

    required_files = [
        "Densoso/Infrastructure/LLM/LLMTypes.swift",
        "Densoso/Infrastructure/LLM/ProviderError.swift",
        "Densoso/Infrastructure/LLM/ProviderHTTPTransport.swift",
        "Densoso/Infrastructure/LLM/DeepSeekProvider.swift",
        "Densoso/Infrastructure/LLM/QwenProvider.swift",
        "Densoso/Infrastructure/LLM/ProviderConfiguration.swift",
        "Densoso/Application/Agent/AgentBudget.swift",
        "Densoso/Application/Agent/AgentEvents.swift",
        "Densoso/Application/Agent/ToolSchemaValidator.swift",
        "Densoso/Application/Usage/ProviderUsageLedger.swift",
        "Densoso/Application/Formatting/AssistantBlock.swift",
        "Densoso/Application/Formatting/RestrictedMarkdownRenderer.swift",
        "Densoso/Views/Components/AssistantBlockView.swift",
        "Densoso/Agent/Tools/CreateWorkoutPlanTool.swift",
        "docs/gates/gate-03-agent-provider.md",
    ]
    for relative in required_files:
        if not (ROOT / relative).is_file():
            errors.append(f"missing {relative}")

    require_text(
        ROOT / "Densoso" / "Infrastructure" / "LLM" / "ProviderError.swift",
        [
            "configurationMissing", "consentRequired", "unauthorized", "rateLimited",
            "timeout", "network", "server", "malformedResponse", "contentRejected",
            "cancelled", "budgetExceeded",
        ],
        errors,
    )
    require_text(
        ROOT / "Densoso" / "Infrastructure" / "LLM" / "ProviderHTTPTransport.swift",
        ["maximumRetries: Int = 2", "Retry-After", "Task.checkCancellation", "deadline"],
        errors,
    )
    for provider_file in ("DeepSeekProvider.swift", "QwenProvider.swift"):
        require_text(
            ROOT / "Densoso" / "Infrastructure" / "LLM" / provider_file,
            ["continuation.onTermination", "task.cancel()"],
            errors,
        )
    require_text(
        ROOT / "Densoso" / "Agent" / "AgentSession.swift",
        [
            "AgentBudgetTracker", "toolCallsCount: tracker.toolCalls",
            "providerRoundsCount: tracker.providerRounds", "cancelActiveRequest",
            "governanceRepository.isConsentGranted", "latestEvent", "sendEvents",
            "cancelled(requestID:",
        ],
        errors,
    )
    agent_text = (ROOT / "Densoso" / "Agent" / "AgentSession.swift").read_text(encoding="utf-8")
    if "DeepSeekClient" in agent_text or "ModelContext" in agent_text:
        errors.append("AgentSession must remain provider-neutral and free of ModelContext")

    require_text(
        ROOT / "Densoso" / "Agent" / "Tools" / "LogMealTool.swift",
        ["\"dishes\": .array", "LogMealArguments", "additionalProperties: false"],
        errors,
    )
    if "dishesJSON" in (ROOT / "Densoso" / "Agent" / "Tools" / "LogMealTool.swift").read_text(encoding="utf-8"):
        errors.append("log_meal still accepts stringified nested JSON")
    require_text(
        ROOT / "Densoso" / "Agent" / "ToolRegistry.swift",
        ["ToolSchemaValidator.validate", "CreateWorkoutPlanTool", "8_192"],
        errors,
    )
    require_text(
        ROOT / "Densoso" / "Services" / "KeychainStore.swift",
        ["model_studio_api_key", "saveModelStudioAPIKey", "readModelStudioAPIKey"],
        errors,
    )
    require_text(
        ROOT / "Densoso" / "Application" / "Formatting" / "RestrictedMarkdownRenderer.swift",
        ["containsForbiddenMarkup", "sanitizeLinks", "plainText", 'scheme?.lowercased() == "https"'],
        errors,
    )

    test_files = [
        "DensosoTests/Infrastructure/LLM/DeepSeekProviderContractTests.swift",
        "DensosoTests/Infrastructure/LLM/QwenProviderContractTests.swift",
        "DensosoTests/Infrastructure/LLM/ProviderRetryPolicyTests.swift",
        "DensosoTests/Application/AgentCoordinatorTests.swift",
        "DensosoTests/Application/PromptInjectionEvalTests.swift",
        "DensosoTests/Application/AgentBudgetTests.swift",
        "DensosoTests/Application/ToolSchemaTests.swift",
        "DensosoTests/Application/ProviderUsageLedgerTests.swift",
        "DensosoTests/Presentation/RestrictedMarkdownRendererTests.swift",
        "DensosoTests/Privacy/ProviderLogRedactionTests.swift",
    ]
    for relative in test_files:
        if not (ROOT / relative).is_file():
            errors.append(f"missing {relative}")

    fixture_paths = [
        ROOT / "DensosoTests/Fixtures/Gate03/Providers/DeepSeek/deepseek-text-tool-response.json",
        ROOT / "DensosoTests/Fixtures/Gate03/Providers/Qwen/qwen-text-tool-response.json",
        ROOT / "DensosoTests/Fixtures/Gate03/Providers/malformed.json",
    ]
    for path in fixture_paths:
        if not path.is_file():
            errors.append(f"missing {path.relative_to(ROOT)}")
        else:
            json.loads(path.read_text(encoding="utf-8"))

    injection = ROOT / "evals" / "prompt-injection-phase3.yaml"
    injection_cases: list[dict[str, object]] = []
    if not injection.is_file():
        errors.append("missing evals/prompt-injection-phase3.yaml")
    else:
        try:
            injection_suite = json.loads(injection.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError) as error:
            errors.append(f"prompt injection eval is not executable JSON/YAML: {error}")
        else:
            if injection_suite.get("version") != 1:
                errors.append("prompt injection eval version must be 1")
            raw_cases = injection_suite.get("cases")
            if not isinstance(raw_cases, list) or not raw_cases:
                errors.append("prompt injection eval must contain cases")
            else:
                injection_cases = raw_cases
                seen_ids: set[str] = set()
                for case in injection_cases:
                    if not isinstance(case, dict):
                        errors.append("prompt injection case must be an object")
                        continue
                    case_id = case.get("id")
                    scenario = case.get("scenario")
                    expected = case.get("expected")
                    if not isinstance(case_id, str) or not case_id or case_id in seen_ids:
                        errors.append("prompt injection case ids must be unique non-empty strings")
                    else:
                        seen_ids.add(case_id)
                    if scenario not in {"user_input", "tool_result"}:
                        errors.append(f"prompt injection case {case_id} has invalid scenario")
                    if not isinstance(case.get("input"), str) or not case["input"]:
                        errors.append(f"prompt injection case {case_id} has no input")
                    if not isinstance(expected, dict):
                        errors.append(f"prompt injection case {case_id} has no expected object")
                        continue
                    if expected.get("direct_health_writes") != 0:
                        errors.append(f"prompt injection case {case_id} permits a direct write")
                    if expected.get("pending_actions") != 1:
                        errors.append(f"prompt injection case {case_id} must require one pending action")
                    if expected.get("confirmation_required") is not True:
                        errors.append(f"prompt injection case {case_id} must require confirmation")

    require_text(
        ROOT / "project.yml",
        ["evals/prompt-injection-phase3.yaml"],
        errors,
    )

    require_text(
        ROOT / ".github" / "workflows" / "build.yml",
        [
            "agent-provider:", "needs: domain-persistence", "gate-03-agent-provider",
            "validate_phase3_agent_provider.py", "Gate03AgentProviderTests.xcresult",
            "gate-03-agent-provider-results",
        ],
        errors,
    )

    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1

    report = {
        "status": "pass",
        "providerFixtures": len(fixture_paths),
        "testFiles": len(test_files),
        "liveNetworkCalls": 0,
        "promptInjectionCases": len(injection_cases),
        "protectedOCRRead": False,
    }
    if args.report:
        Path(args.report).write_text(json.dumps(report, indent=2, sort_keys=True), encoding="utf-8")
    print("Phase 3 agent-provider static contracts: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
