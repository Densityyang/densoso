import Foundation

extension DensosoSchemaV4.UserProfile {
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

}
