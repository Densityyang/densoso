#!/usr/bin/env python3
"""Validate explicit Gate 4 speech contracts without traversing private OCR data."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def require_text(path: Path, needles: list[str], errors: list[str]) -> str:
    if not path.is_file():
        errors.append(f"missing {path.relative_to(ROOT)}")
        return ""
    text = path.read_text(encoding="utf-8")
    for needle in needles:
        if needle not in text:
            errors.append(f"{path.relative_to(ROOT)} is missing {needle}")
    return text


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--report")
    args = parser.parse_args()
    errors: list[str] = []

    require_text(
        ROOT / "Densoso/Application/Speech/SpeechCaptureModels.swift",
        [
            "AudioSessionControlling", "AudioFrameStreaming", "VoiceTranscribing",
            "CloudSpeechProvider", "SpeechCaptureState", "requestingPermission",
            "configuringSession", "preparingBackend", "finalizing",
        ],
        errors,
    )
    service = require_text(
        ROOT / "Densoso/Services/SpeechService.swift",
        [
            "shouldAllowCloudFallback", "audioStarted", "cloudFallbackAllowed",
            "minimumCloudFallbackSeconds", "interruptionBegan", "routeChanged",
            "mediaServicesReset", "warningAfterSeconds", "maximumDurationSeconds",
            "cleanupStaleTemporaryAudio", "capability: .speech",
        ],
        errors,
    )
    if ".spokenAudio" in service or ".duckOthers" in service:
        errors.append("SpeechService retains an invalid spoken-audio/ducking capture path")

    platform = require_text(
        ROOT / "Densoso/Infrastructure/Audio/AudioCapturePlatform.swift",
        [
            "setCategory(.record, mode: .measurement, options: [])",
            "setActive(true, options: [])", "notifyOthersOnDeactivation",
            "isTapInstalled", "bufferingNewest(8)", "routeChangeNotification",
            "interruptionNotification", "mediaServicesWereResetNotification",
        ],
        errors,
    )
    if "requestRecordPermission" not in platform or "AVAudioApplication" not in platform:
        errors.append("microphone permission must use AVAudioApplication")

    require_text(
        ROOT / "Densoso/Infrastructure/Speech/SystemVoiceTranscribers.swift",
        [
            "AnalyzerInputConverter.converter", "converter.flush()",
            "finalizeAndFinishThroughEndOfInput", "await resultsTask?.value",
            "makeLegacyTranscriber",
        ],
        errors,
    )
    require_text(
        ROOT / "Densoso/Infrastructure/Audio/ProtectedSpeechAudioStore.swift",
        ["FileProtectionType.complete", "cleanupStaleFiles", "discardCurrent", "RIFF"],
        errors,
    )
    require_text(
        ROOT / "Densoso/Infrastructure/Diagnostics/SpeechDiagnosticsStore.swift",
        ["allowlisted", "redacted", "completeFileProtection"],
        errors,
    )
    require_text(
        ROOT / "Densoso/Infrastructure/LLM/QwenASRProvider.swift",
        [
            'model = "qwen3-asr-flash"', 'type = "input_audio"',
            '"data:audio/wav;base64,', 'case seconds', "maximumRequestBytes",
        ],
        errors,
    )
    require_text(
        ROOT / "Densoso/Infrastructure/LLM/LLMTypes.swift",
        ["case speechAudio"],
        errors,
    )
    require_text(
        ROOT / "Packages/DensosoDomain/Sources/DensosoDomain/VoiceCommandEnvelope.swift",
        ["case qwenASR"],
        errors,
    )
    require_text(
        ROOT / "Densoso/Views/SettingsScreen.swift",
        ["qwenSpeechFallbackEnabled", "dataClass: .speechAudio", "exportSpeechDiagnostics"],
        errors,
    )

    test_files = [
        "DensosoTests/Application/SpeechCaptureStateMachineTests.swift",
        "DensosoTests/Application/ProtectedSpeechAudioStoreTests.swift",
        "DensosoTests/Infrastructure/LLM/QwenASRProviderContractTests.swift",
        "DensosoTests/Privacy/SpeechDiagnosticsRedactionTests.swift",
    ]
    for relative in test_files:
        if not (ROOT / relative).is_file():
            errors.append(f"missing {relative}")

    fixtures = [
        ROOT / "DensosoTests/Fixtures/Gate04/Providers/Qwen/qwen3-asr-flash-response.json",
        ROOT / "DensosoTests/Fixtures/Gate04/Providers/Qwen/malformed-asr.json",
    ]
    for fixture in fixtures:
        if not fixture.is_file():
            errors.append(f"missing {fixture.relative_to(ROOT)}")
        else:
            json.loads(fixture.read_text(encoding="utf-8"))

    device_matrix = ROOT / "docs/gates/gate-04-device-matrix.json"
    if not device_matrix.is_file():
        errors.append("missing Gate 4 device matrix")
    else:
        matrix = json.loads(device_matrix.read_text(encoding="utf-8"))
        if matrix.get("status") != "provisional-blocked-by-signing":
            errors.append("unsigned device evidence must remain provisional")
        if matrix.get("executedStartStopCycles") != 0:
            errors.append("do not claim unexecuted device cycles")

    routing_matrix = ROOT / "docs/gates/gate-04-routing-matrix.json"
    if not routing_matrix.is_file():
        errors.append("missing Gate 4 routing matrix")
    else:
        routing = json.loads(routing_matrix.read_text(encoding="utf-8"))
        cases = routing.get("cases", [])
        if len(cases) < 7:
            errors.append("Gate 4 routing matrix does not cover all fallback boundaries")
        for case in cases:
            if not case.get("audioPresent") and case.get("expectedCloudCalls") != 0:
                errors.append(f"routing case {case.get('id')} uploads without audio")

    require_text(
        ROOT / ".github/workflows/build.yml",
        [
            "speech:", "needs: agent-provider", "gate-04-speech",
            "validate_phase4_speech.py", "Gate04SpeechTests.xcresult",
            "gate-04-speech-results",
            "gate-04-routing-matrix.json",
        ],
        errors,
    )

    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1

    report = {
        "status": "pass",
        "providerFixtures": len(fixtures),
        "testFiles": len(test_files),
        "liveNetworkCalls": 0,
        "audioSessionCategory": "record",
        "audioSessionMode": "measurement",
        "maximumCaptureSeconds": 60,
        "deviceEvidence": "provisional-blocked-by-signing",
        "protectedOCRRead": False,
    }
    if args.report:
        Path(args.report).write_text(
            json.dumps(report, indent=2, sort_keys=True),
            encoding="utf-8",
        )
    print("Phase 4 speech static contracts: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
