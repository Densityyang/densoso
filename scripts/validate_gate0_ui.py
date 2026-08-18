#!/usr/bin/env python3
"""Validate the static parts of PLAN_v3 Gate 0.

Runtime screenshots remain a separate acceptance requirement. This check only
guards the launch-screen wiring and the single-root background invariant.
"""

from __future__ import annotations

import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
VIEWS = ROOT / "Densoso" / "Views"
PROJECT_YML = ROOT / "project.yml"
LAUNCH_STORYBOARD = ROOT / "Densoso" / "LaunchScreen.storyboard"


def line_hits(path: Path, pattern: re.Pattern[str]) -> list[tuple[Path, int]]:
    return [
        (path, line_number)
        for line_number, line in enumerate(
            path.read_text(encoding="utf-8").splitlines(), start=1
        )
        if pattern.search(line)
    ]


def main() -> int:
    errors: list[str] = []

    project_text = PROJECT_YML.read_text(encoding="utf-8")
    launch_setting = re.compile(
        r"^\s*INFOPLIST_KEY_UILaunchStoryboardName:\s*LaunchScreen\s*$",
        re.MULTILINE,
    )
    if not launch_setting.search(project_text):
        errors.append("project.yml must set UILaunchStoryboardName to LaunchScreen")

    if not LAUNCH_STORYBOARD.is_file():
        errors.append("Densoso/LaunchScreen.storyboard is missing")
    else:
        try:
            document = ET.parse(LAUNCH_STORYBOARD).getroot()
        except ET.ParseError as error:
            errors.append(f"LaunchScreen.storyboard is not valid XML: {error}")
        else:
            if document.attrib.get("launchScreen") != "YES":
                errors.append("LaunchScreen.storyboard must be marked as a launch screen")
            if not document.attrib.get("initialViewController"):
                errors.append("LaunchScreen.storyboard must declare an initial view controller")

    orbit_page_pattern = re.compile(r"\bOrbitPage\s*\{")
    orbit_page_hits = [
        hit
        for path in VIEWS.rglob("*.swift")
        for hit in line_hits(path, orbit_page_pattern)
    ]
    expected_orbit_page_path = VIEWS / "ContentView.swift"
    if len(orbit_page_hits) != 1 or orbit_page_hits[0][0] != expected_orbit_page_path:
        rendered_hits = ", ".join(
            f"{path.relative_to(ROOT)}:{line}" for path, line in orbit_page_hits
        ) or "none"
        errors.append(
            "the main hierarchy must have exactly one root OrbitPage at "
            f"Densoso/Views/ContentView.swift; found {rendered_hits}"
        )

    ignores_safe_area_pattern = re.compile(r"\.ignoresSafeArea\s*\(")
    safe_area_hits = [
        hit
        for path in VIEWS.rglob("*.swift")
        for hit in line_hits(path, ignores_safe_area_pattern)
    ]
    expected_safe_area_file = VIEWS / "Components" / "OrbitDesignSystem.swift"
    if len(safe_area_hits) != 1 or safe_area_hits[0][0] != expected_safe_area_file:
        rendered_hits = ", ".join(
            f"{path.relative_to(ROOT)}:{line}" for path, line in safe_area_hits
        ) or "none"
        errors.append(
            "only OrbitBackground may ignore the safe area; "
            f"found {rendered_hits}"
        )

    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1

    print("Gate 0 UI structure: PASS")
    print("Runtime iPhone 17 portrait screenshots are still required separately.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
