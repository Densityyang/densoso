#!/usr/bin/env python3
"""Rebuild the shipped recipe-prior catalog from its pinned upstream commit."""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
SOURCE_MANIFEST = ROOT / "Densoso/Resources/FoodData/recipe_sources.json"
SHIPPED_CATALOG = ROOT / "Densoso/Resources/FoodData/recipe_priors.json"
SHIPPED_IMPORT_REPORT = ROOT / "Densoso/Resources/FoodData/recipe_prior_import_report.json"
IMPORTER = ROOT / "scripts/import_recipe_priors.py"
PINNED_SOURCE_ID = "anduin-howtocook"
PINNED_SOURCE_URL = "https://github.com/Anduin2017/HowToCook"
PINNED_SOURCE_VERSION = "5fb3140c20b2a713296696dc6fdd3b83ccc617a6"


def run_git(repository: Path, *arguments: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(repository), *arguments],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
    )
    return result.stdout.strip()


def load_pinned_source() -> dict[str, Any]:
    manifest = json.loads(SOURCE_MANIFEST.read_text(encoding="utf-8"))
    source = manifest.get("source") if isinstance(manifest, dict) else None
    if not isinstance(source, dict):
        raise ValueError("recipe source manifest is missing its source object")
    expected = {
        "sourceID": PINNED_SOURCE_ID,
        "sourceURL": PINNED_SOURCE_URL,
        "sourceVersion": PINNED_SOURCE_VERSION,
        "licenseSPDX": "Unlicense",
        "dataRole": "recipe-prior",
        "redistributionAllowed": True,
        "verificationStatus": "verified",
    }
    mismatches = [key for key, value in expected.items() if source.get(key) != value]
    if mismatches:
        raise ValueError("recipe source manifest differs from pinned provenance: " + ", ".join(mismatches))
    return source


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def write_report(path: Path, report: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--report",
        type=Path,
        default=Path("gate17-recipe-reproducibility.json"),
        help="write a machine-readable comparison report here",
    )
    args = parser.parse_args()

    report: dict[str, Any] = {
        "schemaVersion": 1,
        "sourceID": PINNED_SOURCE_ID,
        "sourceVersion": PINNED_SOURCE_VERSION,
        "status": "FAIL",
    }
    try:
        source = load_pinned_source()
        report["licenseSPDX"] = source["licenseSPDX"]
        with tempfile.TemporaryDirectory(prefix="densoso-recipe-priors-") as temporary_directory:
            temporary = Path(temporary_directory)
            source_repository = temporary / "HowToCook"
            clone = subprocess.run(
                [
                    "git",
                    "clone",
                    "--filter=blob:none",
                    "--no-checkout",
                    source["sourceURL"] + ".git",
                    str(source_repository),
                ],
                check=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                encoding="utf-8",
            )
            if clone.returncode != 0:
                raise RuntimeError(f"pinned upstream clone failed: {clone.stderr.strip()[-2000:]}")
            fetch = subprocess.run(
                ["git", "-C", str(source_repository), "fetch", "--depth=1", "origin", source["sourceVersion"]],
                check=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                encoding="utf-8",
            )
            if fetch.returncode != 0:
                raise RuntimeError(f"pinned upstream fetch failed: {fetch.stderr.strip()[-2000:]}")
            run_git(source_repository, "sparse-checkout", "init", "--cone")
            run_git(source_repository, "sparse-checkout", "set", "dishes")
            run_git(source_repository, "checkout", "--detach", source["sourceVersion"])

            generated_catalog = temporary / "recipe_priors.json"
            generated_import_report = temporary / "recipe_prior_import_report.json"
            imported = subprocess.run(
                [
                    sys.executable,
                    str(IMPORTER),
                    "--source-repo",
                    str(source_repository),
                    "--manifest",
                    str(SOURCE_MANIFEST),
                    "--output",
                    str(generated_catalog),
                    "--report",
                    str(generated_import_report),
                ],
                check=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                encoding="utf-8",
            )
            report["importerOutput"] = imported.stdout.strip()[-4000:]
            if imported.returncode != 0:
                raise RuntimeError(f"pinned source import failed: {imported.stderr.strip()[-2000:]}")

            comparisons = {
                "catalog": (generated_catalog, SHIPPED_CATALOG),
                "importReport": (generated_import_report, SHIPPED_IMPORT_REPORT),
            }
            comparison_report: dict[str, Any] = {}
            all_match = True
            for name, (generated, shipped) in comparisons.items():
                matches = generated.read_bytes() == shipped.read_bytes()
                comparison_report[name] = {
                    "matches": matches,
                    "generatedSHA256": sha256(generated),
                    "shippedSHA256": sha256(shipped),
                }
                all_match = all_match and matches
            report["comparisons"] = comparison_report
            report["status"] = "PASS" if all_match else "FAIL"
            if not all_match:
                report["failure"] = "generated recipe-prior catalog or import report differs from shipped files"
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError, json.JSONDecodeError) as error:
        report["failure"] = str(error)

    write_report(args.report, report)
    print(json.dumps(report, ensure_ascii=False, sort_keys=True))
    return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
