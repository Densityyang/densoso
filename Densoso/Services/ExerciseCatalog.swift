import Foundation
import DensosoDomain

struct ExerciseCatalog: Decodable, Sendable {
    struct Entry: Decodable, Equatable, Identifiable, Sendable {
        let id: String
        let sourceID: String
        let name: String
        let aliases: [String]
        let category: String
        let equipment: String?
        let primaryMuscles: [String]
        let secondaryMuscles: [String]

        func matches(_ query: String) -> Bool {
            let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty else { return true }
            return ([name, sourceID] + aliases).contains { $0.lowercased().contains(normalized) }
        }
    }

    struct Source: Decodable, Sendable {
        let repository: String
        let revision: String
        let inputSHA256: String
        let license: String
    }

    let schemaVersion: Int
    let catalogVersion: String
    let source: Source
    let entries: [Entry]

    static func loadBundled(bundle: Bundle = .main) throws -> ExerciseCatalog {
        guard let url = bundle.url(forResource: "exercise_catalog", withExtension: "json") else {
            throw ExerciseCatalogError.resourceUnavailable
        }
        let catalog = try JSONDecoder().decode(ExerciseCatalog.self, from: Data(contentsOf: url))
        guard catalog.catalogVersion == ExerciseCatalogVersion.current else {
            throw ExerciseCatalogError.versionMismatch
        }
        return catalog
    }

    func entry(matching query: String) -> Entry? {
        entries.first { $0.matches(query) }
    }
}

enum ExerciseCatalogError: LocalizedError {
    case resourceUnavailable
    case versionMismatch

    var errorDescription: String? {
        switch self {
        case .resourceUnavailable: "离线动作目录不可用。"
        case .versionMismatch: "离线动作目录版本与应用不匹配。"
        }
    }
}
