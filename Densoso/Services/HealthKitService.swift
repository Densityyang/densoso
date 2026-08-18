import Foundation
import HealthKit

/// HealthKit 读写服务
/// v1: 读 BMR/体重/身高；写饮食热量
/// v2: 读 Apple Watch 运动/睡眠数据
@MainActor
@Observable
final class HealthKitService {
    enum HealthError: LocalizedError {
        case unavailable
        case sharingDenied
        case authorizationRequestFailed(String)

        var errorDescription: String? {
            switch self {
            case .unavailable:
                "此设备无法使用 Apple Health。"
            case .sharingDenied:
                "Apple Health 未允许写入膳食能量。请在健康 App 的共享设置中检查 densoso 的写入权限。"
            case .authorizationRequestFailed(let message):
                "Apple Health 授权请求失败：\(message)。请返回设置页查看设备、签名能力和授权状态。"
            }
        }
    }

    private let store = HKHealthStore()

    var isAuthorized = false

    // MARK: - 权限

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw HealthError.unavailable }

        let readTypes: Set<HKSampleType> = [
            HKObjectType.quantityType(forIdentifier: .bodyMass)!,
            HKObjectType.quantityType(forIdentifier: .height)!,
            HKObjectType.workoutType(),
            HKSeriesType.workoutRoute(),
        ]

        let writeTypes: Set<HKSampleType> = [
            HKObjectType.quantityType(forIdentifier: .dietaryEnergyConsumed)!,
        ]

        do {
            try await store.requestAuthorization(
                toShare: writeTypes,
                read: readTypes
            )
        } catch {
            throw HealthError.authorizationRequestFailed(error.localizedDescription)
        }

        guard let dietaryEnergyType = HKObjectType.quantityType(forIdentifier: .dietaryEnergyConsumed),
              store.authorizationStatus(for: dietaryEnergyType) == .sharingAuthorized else {
            isAuthorized = false
            throw HealthError.sharingDenied
        }
        isAuthorized = true
    }

    // MARK: - 读取

    func fetchLatestWeight() async -> Double? {
        guard let type = HKObjectType.quantityType(forIdentifier: .bodyMass) else { return nil }
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: type)],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
            limit: 1
        )
        let samples = try? await descriptor.result(for: store)
        return samples?.first?.quantity.doubleValue(for: .gramUnit(with: .kilo))
    }

    func fetchHeight() async -> Double? {
        guard let type = HKObjectType.quantityType(forIdentifier: .height) else { return nil }
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: type)],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
            limit: 1
        )
        let samples = try? await descriptor.result(for: store)
        return samples?.first?.quantity.doubleValue(for: .meterUnit(with: .centi))
    }

    // MARK: - 写入

    func writeDietaryEnergy(kcal: Int, date: Date) async throws {
        guard let type = HKObjectType.quantityType(forIdentifier: .dietaryEnergyConsumed) else { return }
        let quantity = HKQuantity(unit: .kilocalorie(), doubleValue: Double(kcal))
        let sample = HKQuantitySample(type: type, quantity: quantity, start: date, end: date)
        try await store.save(sample)
    }
}
