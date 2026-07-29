import AVFAudio
import Foundation
import HealthKit
import Observation
import Security
import Speech

enum CapabilityPermissionState: Equatable, Sendable {
    case authorized
    case denied
    case notDetermined
    case unavailable
    case privacyProtected
    case unknown

    var displayName: String {
        switch self {
        case .authorized: "已允许"
        case .denied: "已拒绝"
        case .notDetermined: "未请求"
        case .unavailable: "不可用"
        case .privacyProtected: "系统保护"
        case .unknown: "未知"
        }
    }
}

enum HealthAuthorizationRequestState: Equatable, Sendable {
    case shouldRequest
    case unnecessary
    case unknown

    var displayName: String {
        switch self {
        case .shouldRequest: "需要请求"
        case .unnecessary: "无需重复请求"
        case .unknown: "未知"
        }
    }
}

struct CapabilityDiagnosticsSnapshot: Equatable, Sendable {
    var healthDataAvailable = false
    var healthKitEntitlementPresent = false
    var dietaryEnergyWritePermission: CapabilityPermissionState = .unknown
    var healthAuthorizationRequest: HealthAuthorizationRequestState = .unknown
    var healthReadPermission: CapabilityPermissionState = .privacyProtected
    var microphonePermission: CapabilityPermissionState = .unknown
    var speechRecognitionPermission: CapabilityPermissionState = .unknown
    var modernSpeechAvailable = false
    var lastHealthImportAt: Date?
}

@MainActor
@Observable
final class CapabilityDiagnosticsService {
    private let healthStore = HKHealthStore()
    private(set) var snapshot = CapabilityDiagnosticsSnapshot()
    private(set) var isRefreshing = false

    func refresh(lastHealthImportAt: Date?) async {
        isRefreshing = true
        defer { isRefreshing = false }

        let healthDataAvailable = HKHealthStore.isHealthDataAvailable()
        let entitlementPresent = Self.hasEntitlement("com.apple.developer.healthkit")
        let writePermission: CapabilityPermissionState
        if !healthDataAvailable {
            writePermission = .unavailable
        } else if let dietaryEnergyType = HKObjectType.quantityType(forIdentifier: .dietaryEnergyConsumed) {
            writePermission = Self.map(healthStore.authorizationStatus(for: dietaryEnergyType))
        } else {
            writePermission = .unavailable
        }

        let requestState: HealthAuthorizationRequestState
        if healthDataAvailable {
            requestState = await authorizationRequestState()
        } else {
            requestState = .unknown
        }

        snapshot = CapabilityDiagnosticsSnapshot(
            healthDataAvailable: healthDataAvailable,
            healthKitEntitlementPresent: entitlementPresent,
            dietaryEnergyWritePermission: writePermission,
            healthAuthorizationRequest: requestState,
            healthReadPermission: .privacyProtected,
            microphonePermission: Self.microphonePermission(),
            speechRecognitionPermission: Self.map(SFSpeechRecognizer.authorizationStatus()),
            modernSpeechAvailable: PlatformCapabilities.current.modernSpeechAvailable,
            lastHealthImportAt: lastHealthImportAt
        )
    }

    private func authorizationRequestState() async -> HealthAuthorizationRequestState {
        guard let bodyMass = HKObjectType.quantityType(forIdentifier: .bodyMass),
              let height = HKObjectType.quantityType(forIdentifier: .height),
              let dietaryEnergy = HKObjectType.quantityType(forIdentifier: .dietaryEnergyConsumed) else {
            return .unknown
        }

        let readTypes: Set<HKObjectType> = [
            bodyMass,
            height,
            HKObjectType.workoutType(),
            HKSeriesType.workoutRoute(),
        ]
        let writeTypes: Set<HKSampleType> = [
            dietaryEnergy,
        ]

        return await withCheckedContinuation { continuation in
            healthStore.getRequestStatusForAuthorization(toShare: writeTypes, read: readTypes) { status, _ in
                let mapped: HealthAuthorizationRequestState = switch status {
                case .shouldRequest: .shouldRequest
                case .unnecessary: .unnecessary
                case .unknown: .unknown
                @unknown default: .unknown
                }
                continuation.resume(returning: mapped)
            }
        }
    }

    private static func microphonePermission() -> CapabilityPermissionState {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: .authorized
        case .denied: .denied
        case .undetermined: .notDetermined
        @unknown default: .unknown
        }
    }

    private static func hasEntitlement(_ name: String) -> Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, name as CFString, nil) else {
            return false
        }
        return (value as? Bool) == true
    }

    private static func map(_ status: HKAuthorizationStatus) -> CapabilityPermissionState {
        switch status {
        case .sharingAuthorized: .authorized
        case .sharingDenied: .denied
        case .notDetermined: .notDetermined
        @unknown default: .unknown
        }
    }

    private static func map(_ status: SFSpeechRecognizerAuthorizationStatus) -> CapabilityPermissionState {
        switch status {
        case .authorized: .authorized
        case .denied: .denied
        case .notDetermined: .notDetermined
        case .restricted: .unavailable
        @unknown default: .unknown
        }
    }
}
