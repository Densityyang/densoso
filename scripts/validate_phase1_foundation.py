#!/usr/bin/env python3
"""Validate the static contracts for PLAN_v3 gate-01-foundation.

Compilation, Simulator execution, screenshots, and signing remain CI/runtime
evidence. This script only prevents configuration and dependency-boundary drift.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DOMAIN = ROOT / "Packages" / "DensosoDomain"
OLD_DOMAIN = ROOT / "Packages" / "DensosoWorkoutDomain"
PROJECT_YML = ROOT / "project.yml"
WORKFLOW = ROOT / ".github" / "workflows" / "build.yml"
GATE_DOC = ROOT / "docs" / "gates" / "gate-01-foundation.md"
UI_FIXTURES = ROOT / "DensosoUITests" / "Fixtures" / "Gate01"


def main() -> int:
    errors: list[str] = []

    manifest = DOMAIN / "Package.swift"
    if not manifest.is_file():
        errors.append("Packages/DensosoDomain/Package.swift is missing")
    else:
        manifest_text = manifest.read_text(encoding="utf-8")
        for expected in (
            'name: "DensosoDomain"',
            '.library(name: "DensosoDomain"',
            '.target(name: "DensosoDomain")',
            'name: "DensosoDomainTests"',
        ):
            if expected not in manifest_text:
                errors.append(f"DensosoDomain manifest is missing {expected}")

    if OLD_DOMAIN.is_dir() and any(path.is_file() for path in OLD_DOMAIN.rglob("*")):
        errors.append("Packages/DensosoWorkoutDomain still contains files")

    domain_sources = sorted((DOMAIN / "Sources" / "DensosoDomain").glob("*.swift"))
    if not domain_sources:
        errors.append("DensosoDomain has no source files")
    for source in domain_sources:
        imports = re.findall(
            r"^import\s+([A-Za-z0-9_]+)\s*$",
            source.read_text(encoding="utf-8"),
            flags=re.MULTILINE,
        )
        disallowed = [module for module in imports if module != "Foundation"]
        if disallowed:
            errors.append(
                f"{source.relative_to(ROOT)} imports non-domain modules: {', '.join(disallowed)}"
            )

    project_text = PROJECT_YML.read_text(encoding="utf-8")
    if 'iOS: "18.0"' not in project_text:
        errors.append("project.yml must set the global iOS deployment target to 18.0")
    if 'IPHONEOS_DEPLOYMENT_TARGET: "26.0"' in project_text:
        errors.append("project.yml still contains an iOS 26 deployment target")
    if project_text.count('WATCHOS_DEPLOYMENT_TARGET: "11.0"') != 2:
        errors.append("Watch app and extension must both keep watchOS deployment at 11.0")
    for expected in (
        "DensosoUITests:",
        'deploymentTarget: "18.0"',
        "- package: DensosoDomain",
        "path: Packages/DensosoDomain",
    ):
        if expected not in project_text:
            errors.append(f"project.yml is missing {expected}")

    searchable_roots = [
        ROOT / "Densoso" / "Agent",
        ROOT / "Densoso" / "App",
        ROOT / "Densoso" / "Domain",
        ROOT / "Densoso" / "Infrastructure",
        ROOT / "Densoso" / "Intents",
        ROOT / "Densoso" / "Models",
        ROOT / "Densoso" / "Persistence",
        ROOT / "Densoso" / "Services",
        ROOT / "Densoso" / "Views",
        ROOT / "DensosoTests",
        ROOT / "DensosoUITests",
        ROOT / "DensosoWatchExtension",
        ROOT / "README.md",
        PROJECT_YML,
        WORKFLOW,
    ]
    for searchable in searchable_roots:
        paths = searchable.rglob("*") if searchable.is_dir() else [searchable]
        for path in paths:
            if not path.is_file() or path.suffix not in {".swift", ".md", ".yml", ".yaml"}:
                continue
            if "DensosoWorkoutDomain" in path.read_text(encoding="utf-8"):
                errors.append(f"stale DensosoWorkoutDomain reference in {path.relative_to(ROOT)}")

    adapter = ROOT / "Densoso" / "Infrastructure" / "Food" / "OpenFoodFactsPackagedFoodProvider.swift"
    if not adapter.is_file():
        errors.append("OpenFoodFacts adapter must live under Densoso/Infrastructure/Food")
    if (DOMAIN / "Sources" / "DensosoDomain" / "OpenFoodFactsPackagedFoodProvider.swift").exists():
        errors.append("OpenFoodFacts adapter must not remain in DensosoDomain")

    speech_text = (ROOT / "Densoso" / "Services" / "SpeechService.swift").read_text(encoding="utf-8")
    if "private var analyzer: SpeechAnalyzer?" in speech_text:
        errors.append("SpeechService stores an unguarded iOS 26 SpeechAnalyzer")
    if "@available(iOS 26.0, *)\n@MainActor\nprivate final class SpeechAnalyzerRecognitionBackend" not in speech_text:
        errors.append("SpeechAnalyzer backend is not isolated behind iOS 26 availability")

    launch_fixture = UI_FIXTURES / "launch-config.json"
    screen_fixture = UI_FIXTURES / "expected-tabs.json"
    for fixture in (launch_fixture, screen_fixture):
        if not fixture.is_file():
            errors.append(f"missing UI fixture {fixture.relative_to(ROOT)}")
    if screen_fixture.is_file():
        screens = json.loads(screen_fixture.read_text(encoding="utf-8")).get("screens", [])
        if len(screens) != 5:
            errors.append("Gate 1 UI fixture must cover all five current baseline tabs")

    if not GATE_DOC.is_file():
        errors.append("docs/gates/gate-01-foundation.md is missing")

    workflow_text = WORKFLOW.read_text(encoding="utf-8")
    for expected in (
        "foundation:",
        "Packages/DensosoDomain",
        "validate_phase1_foundation.py",
        "Build with iOS 18 deployment target",
        "IPHONEOS_DEPLOYMENT_TARGET=18.0",
        "Test units on iOS 26 Simulator",
        "-only-testing:DensosoTests",
        "Test UI fixtures and capture screenshots",
        "-only-testing:DensosoUITests",
        "xcresulttool export attachments",
        'test "$SCREENSHOT_COUNT" -ge 6',
        "-scheme DensosoWatch",
        "WATCHOS_DEPLOYMENT_TARGET=11.0",
        "UILaunchStoryboardName",
        "LaunchScreen.storyboardc",
        "Gate01UnitTests.xcresult",
        "Gate01UITests.xcresult",
        "gate-01-foundation-results",
    ):
        if expected not in workflow_text:
            errors.append(f"foundation workflow is missing {expected}")

    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1

    print("Phase 1 foundation static contracts: PASS")
    print("Xcode, Simulator, screenshot, and signing evidence must come from CI/runtime checks.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
