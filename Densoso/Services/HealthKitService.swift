import Foundation
import HealthKit

/// HealthKit 读写服务
/// v1: 读 BMR/体重/身高；写饮食热量
/// v2: 读 Apple Watch 运动/睡眠数据
@MainActor
@Observable
final class HealthKitService {
    private let store = HKHealthStore()

    var isAuthorized = false

    // MARK: - 权限

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }

        let readTypes: Set<HKSampleType> = [
            HKObjectType.quantityType(forIdentifier: .bodyMass)!,
            HKObjectType.quantityType(forIdentifier: .height)!,
        ]

        let writeTypes: Set<HKSampleType> = [
            HKObjectType.quantityType(forIdentifier: .dietaryEnergyConsumed)!,
        ]

        try await store.requestAuthorization(
            toShare: writeTypes,
            read: readTypes
        )
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