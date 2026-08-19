#!/usr/bin/env python3
"""Validate static contracts for PLAN_v3 gate-02-domain-persistence.

The scanner uses explicit source roots and never traverses Densoso/Resources or
the private OCR validation script. SwiftData migration and transaction evidence
must still come from the Simulator test gate.
"""

from __future__ import annotations

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
    errors: list[str] = []

    domain = ROOT / "Packages" / "DensosoDomain"
    for relative in (
        "Sources/DensosoDomain/EstimateRange.swift",
        "Sources/DensosoDomain/Evidence.swift",
        "Sources/DensosoDomain/HealthDomainDrafts.swift",
        "Sources/DensosoDomain/ActionPayload.swift",
        "Tests/DensosoDomainTests/EstimateRangePropertyTests.swift",
        "Tests/DensosoDomainTests/CanonicalActionPayloadTests.swift",
    ):
        if not (domain / relative).is_file():
            errors.append(f"missing Packages/DensosoDomain/{relative}")

    schemas = ROOT / "Densoso" / "Persistence" / "Schemas"
    for name in (
        "DensosoSchemaV1.swift",
        "DensosoSchemaV1Bridge.swift",
        "DensosoSchemaV2.swift",
        "DensosoSchemaV2Bridge.swift",
        "DensosoSchemaV3.swift",
    ):
        if not (schemas / name).is_file():
            errors.append(f"missing Densoso/Persistence/Schemas/{name}")

    require_text(
        ROOT / "Densoso" / "Persistence" / "DensosoMigrationPlan.swift",
        [
            "DensosoSchemaV1Bridge.self",
            "DensosoSchemaV2Bridge.self",
            "legacy-meal-",
            "legacy-outbox-",
            "legacyPointEstimate",
        ],
        errors,
    )
    require_text(
        schemas / "DensosoSchemaV3.swift",
        [
            "ConversationRecord.self",
            "MessageRecord.self",
            "PendingActionRecord.self",
            "CommittedActionReceiptRecord.self",
            "GoalProfileRecord.self",
            "DailyHealthSnapshotRecord.self",
            "ProviderUsageRecord.self",
            "WatchMessageReceiptRecord.self",
            "ConsentRecord.self",
            "attemptCount",
            "nextAttemptAt",
        ],
        errors,
    )

    agent_roots = [ROOT / "Densoso" / "Agent", ROOT / "Densoso" / "Agent" / "Tools"]
    for agent_root in agent_roots:
        for path in agent_root.rglob("*.swift"):
            text = path.read_text(encoding="utf-8")
            if "import SwiftData" in text or "ModelContext" in text:
                errors.append(f"Agent persistence boundary violated in {path.relative_to(ROOT)}")
    if (ROOT / "Densoso" / "Agent" / "Tools" / "LogWorkoutTool.swift").exists():
        errors.append("LogWorkoutTool must not exist in the model tool registry")

    require_text(
        ROOT / "Packages" / "DensosoDomain" / "Sources" / "DensosoDomain" / "ActionPayload.swift",
        ["CanonicalizationError", "CanonicalInteger", "rounded > Double(Int64.min)"],
        errors,
    )
    require_text(
        ROOT / "Densoso" / "Agent" / "AgentSession.swift",
        ["import Observation", "restoredVisibleMessages"],
        errors,
    )
    require_text(
        ROOT / "Densoso" / "Application" / "Confirmation" / "ConfirmationCoordinator.swift",
        ["24 * 60 * 60", "canonicalData", "recoverInterruptedCommits"],
        errors,
    )
    require_text(
        ROOT / "Densoso" / "Infrastructure" / "Persistence" / "SwiftDataConfirmationRepository.swift",
        [
            "modelContext.transaction",
            "CommittedActionReceiptRecord",
            "HealthSyncOutboxEntry",
            "afterTransactionCommitted",
            "record_without_receipt",
            "HealthSyncState.retryable.rawValue",
            "reprojectDailyHealthSnapshot",
        ],
        errors,
    )
    require_text(
        ROOT / "Densoso" / "Infrastructure" / "Persistence" / "PersistenceBootstrap.swift",
        ["allowsSave: false", "MigrationBackupManager.restore", "backupProvider", "DensosoDiagnostic"],
        errors,
    )
    require_text(
        ROOT / "Densoso" / "Infrastructure" / "Persistence" / "MigrationBackupManager.swift",
        ["checksumMismatch", "stagedDirectory", "rollbackDirectory"],
        errors,
    )
    bootstrap_text = (ROOT / "Densoso" / "Infrastructure" / "Persistence" / "PersistenceBootstrap.swift").read_text(encoding="utf-8")
    if 'ModelConfiguration("DensosoRecovery"' in bootstrap_text:
        errors.append("PersistenceBootstrap must not create a writable DensosoRecovery store")

    fixture_root = ROOT / "DensosoTests" / "Fixtures" / "Gate02"
    fixture_names = ["v1-seed.json", "v2-seed.json", "expected-migration.json"]
    for name in fixture_names:
        path = fixture_root / name
        if not path.is_file():
            errors.append(f"missing DensosoTests/Fixtures/Gate02/{name}")
        else:
            json.loads(path.read_text(encoding="utf-8"))

    for test_name in (
        "ConfirmationCoordinatorTests.swift",
        "ConversationPersistenceTests.swift",
        "DensosoMigrationTests.swift",
        "MigrationBackupManagerTests.swift",
        "AgentPersistenceBoundaryTests.swift",
    ):
        if not (ROOT / "DensosoTests" / test_name).is_file():
            errors.append(f"missing DensosoTests/{test_name}")

    require_text(
        ROOT / "docs" / "gates" / "gate-01-foundation.md",
        ["approved by user on 2026-08-18", "Phase 2 authorized"],
        errors,
    )
    if not (ROOT / "docs" / "gates" / "gate-02-domain-persistence.md").is_file():
        errors.append("missing docs/gates/gate-02-domain-persistence.md")

    require_text(
        ROOT / ".github" / "workflows" / "build.yml",
        [
            "domain-persistence:",
            "needs: foundation",
            "gate-02-domain-persistence",
            "validate_phase2_domain_persistence.py",
            "Gate02PersistenceTests.xcresult",
            "DensosoTests/ConfirmationCoordinatorTests",
            "DensosoTests/DensosoMigrationTests",
            "xcresulttool export attachments",
            "gate-02-domain-persistence-results",
        ],
        errors,
    )

    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print("Phase 2 domain-persistence static contracts: PASS")
    print("Migration, transaction, crash-recovery, and rollback evidence must come from Simulator CI.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
