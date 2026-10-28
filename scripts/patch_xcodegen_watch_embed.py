#!/usr/bin/env python3
"""Place XcodeGen's embedded single-target watchOS app in PlugIns/.

XcodeGen 2.45 emits watchOS application dependencies into Watch/. Current
Xcode expects embedded single-target watchOS apps under PlugIns/.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PROJECT_FILE = ROOT / "Densoso.xcodeproj" / "project.pbxproj"
PHASE = re.compile(
    r"(?P<header>^[\t ]*[A-F0-9]{24} /\* Embed Watch Content \*/ = \{\r?\n)"
    r"(?P<body>.*?)"
    r"(?P<footer>^[\t ]*\};)",
    flags=re.MULTILINE | re.DOTALL,
)
WATCH_DESTINATION = 'dstPath = "$(CONTENTS_FOLDER_PATH)/Watch";'
PLUGINS_DESTINATION = 'dstPath = "";'
WATCH_SUBFOLDER = "dstSubfolderSpec = 16;"
PLUGINS_SUBFOLDER = "dstSubfolderSpec = 13;"


def fail(message: str) -> int:
    print(f"ERROR: {message}", file=sys.stderr)
    return 1


def main() -> int:
    if not PROJECT_FILE.is_file():
        return fail(f"generated Xcode project is missing: {PROJECT_FILE.relative_to(ROOT)}")

    project = PROJECT_FILE.read_text(encoding="utf-8")
    phases = list(PHASE.finditer(project))
    if len(phases) != 1:
        return fail(f"expected one Embed Watch Content phase, found {len(phases)}")

    phase = phases[0]
    body = phase.group("body")
    if "isa = PBXCopyFilesBuildPhase;" not in body:
        return fail("Embed Watch Content is not a copy-files phase")

    old_path_count = body.count(WATCH_DESTINATION)
    old_folder_count = body.count(WATCH_SUBFOLDER)
    new_path_count = body.count(PLUGINS_DESTINATION)
    new_folder_count = body.count(PLUGINS_SUBFOLDER)
    if (old_path_count, old_folder_count) == (1, 1) and (new_path_count, new_folder_count) == (0, 0):
        body = body.replace(WATCH_DESTINATION, PLUGINS_DESTINATION, 1)
        body = body.replace(WATCH_SUBFOLDER, PLUGINS_SUBFOLDER, 1)
    elif (old_path_count, old_folder_count, new_path_count, new_folder_count) != (0, 0, 1, 1):
        return fail("Watch embed phase has an unexpected or ambiguous destination")

    patched = project[: phase.start("body")] + body + project[phase.end("body") :]
    if patched != project:
        PROJECT_FILE.write_text(patched, encoding="utf-8")
    print("Single-target Watch app embeds under PlugIns/.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
