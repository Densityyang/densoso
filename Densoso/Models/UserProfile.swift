import Foundation

extension DensosoSchemaV3.UserProfile {
    struct WeightEntry: Codable, Equatable {
        var date: Date
        var kg: Double
    }

    var weightHistory: [WeightEntry] {
        get {
            guard let data = weightHistoryJSON.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([WeightEntry].self, from: data)) ?? []
        }
        set {
            if let data = try? JSONEncoder().encode(newValue),
               let json = String(data: data, encoding: .utf8) {
                weightHistoryJSON = json
            }
        }
    }

    func updateWeight(_ newKg: Double) {
        var history = weightHistory
        history.append(WeightEntry(date: Date(), kg: newKg))
        weightHistory = history
        weightKg = newKg
        updatedAt = Date()
    }

    var age: Int {
        Calendar.current.dateComponents([.year], from: dateOfBirth, to: Date()).year ?? 30
    }
}
