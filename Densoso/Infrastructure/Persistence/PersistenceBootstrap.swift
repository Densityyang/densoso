import Foundation
import SwiftData

enum PersistenceBootstrapError: LocalizedError {
    case backupRequired
    case backupFailed(String)

    var errorDescription: String? {
        switch self {
        case .backupRequired: "A migration backup was required but was not created."
        case .backupFailed(let detail): "Migration backup failed: \(detail)"
        }
    }
}

struct PersistenceBootstrap {
    let container: ModelContainer
    let warning: String?
    let state: PersistenceRuntimeState
    let backupManifest: MigrationBackupManifest?

    static var defaultStoreURL: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return applicationSupport.appendingPathComponent("default.store")
    }

    static func make(
        inMemory: Bool = false,
        storeURL: URL = defaultStoreURL
    ) -> PersistenceBootstrap {
        make(
            inMemory: inMemory,
            storeURL: storeURL,
            migrationPlan: DensosoMigrationPlan.self
        )
    }

    static func make<Plan: SchemaMigrationPlan>(
        inMemory: Bool = false,
        storeURL: URL = defaultStoreURL,
        migrationPlan: Plan.Type,
        backupProvider: (URL) throws -> MigrationBackupManifest? = {
            try MigrationBackupManager.createBackupIfPresent(storeURL: $0)
        }
    ) -> PersistenceBootstrap {
        let schema = Schema(versionedSchema: DensosoSchemaV3.self)
        if inMemory {
            let configuration = ModelConfiguration(
                "DensosoUITests",
                schema: schema,
                isStoredInMemoryOnly: true
            )
            do {
                return PersistenceBootstrap(
                    container: try ModelContainer(for: schema, configurations: [configuration]),
                    warning: nil,
                    state: .writable,
                    backupManifest: nil
                )
            } catch {
                fatalError("Unable to create the UI test model container: \(error.localizedDescription)")
            }
        }

        let configuration = ModelConfiguration("Densoso", schema: schema, url: storeURL)
        let fileManager = FileManager.default
        let hasStore = fileManager.fileExists(atPath: storeURL.path)
        let legacyVersion = hasStore ? RecoveryStoreProbe.version(at: storeURL) : nil

        if legacyVersion == nil {
            do {
                return PersistenceBootstrap(
                    container: try ModelContainer(for: schema, configurations: [configuration]),
                    warning: nil,
                    state: .writable,
                    backupManifest: nil
                )
            } catch {
                // A corrupt or otherwise unrecognized store is backed up before
                // the explicit migration path is attempted below.
            }
        }

        let backupManifest: MigrationBackupManifest
        do {
            guard let manifest = try backupProvider(storeURL) else {
                return makeRecoveryBootstrap(
                    migrationError: PersistenceBootstrapError.backupRequired,
                    schema: schema,
                    backupManifest: nil
                )
            }
            backupManifest = manifest
        } catch {
            return makeRecoveryBootstrap(
                migrationError: PersistenceBootstrapError.backupFailed(error.localizedDescription),
                schema: schema,
                backupManifest: nil
            )
        }
        do {
            return PersistenceBootstrap(
                container: try ModelContainer(
                    for: schema,
                    migrationPlan: migrationPlan,
                    configurations: [configuration]
                ),
                warning: nil,
                state: .writable,
                backupManifest: backupManifest
            )
        } catch {
            return makeRecoveryBootstrap(
                migrationError: error,
                schema: schema,
                backupManifest: backupManifest
            )
        }
    }

    private static func makeRecoveryBootstrap(
        migrationError: Error,
        schema: Schema,
        backupManifest: MigrationBackupManifest?
    ) -> PersistenceBootstrap {
        let diagnosticID = UUID().uuidString.lowercased()
        var restoreError: Error?
        if let backupManifest {
            do {
                try MigrationBackupManager.restore(manifest: backupManifest)
            } catch {
                restoreError = error
            }
        }
        let sourceVersion = backupManifest.flatMap { RecoveryStoreProbe.version(at: $0.backupStoreURL) }
        let recoveryState: PersistenceRuntimeState
        if restoreError == nil,
           let backupStoreURL = backupManifest?.backupStoreURL,
           sourceVersion != nil {
            recoveryState = .recoveryReadOnly(
                diagnosticID: diagnosticID,
                backupStoreURL: backupStoreURL,
                sourceVersion: sourceVersion
            )
        } else {
            recoveryState = .diagnosticOnly(
                diagnosticID: diagnosticID,
                backupStoreURL: backupManifest?.backupStoreURL
            )
        }

        let diagnosticConfiguration = ModelConfiguration(
            "DensosoDiagnostic",
            schema: schema,
            isStoredInMemoryOnly: true,
            allowsSave: false
        )
        do {
            let container = try ModelContainer(for: schema, configurations: [diagnosticConfiguration])
            let restoreStatus: String
            if let restoreError {
                restoreStatus = "原 store 自动恢复未完成；迁移前备份仍保留：\(restoreError.localizedDescription)"
            } else if backupManifest != nil {
                restoreStatus = "原 store 已从迁移前备份恢复。"
            } else {
                restoreStatus = "未获得可验证的迁移备份，因此未执行迁移写入。"
            }
            return PersistenceBootstrap(
                container: container,
                warning: "本地数据迁移失败，当前为禁止写入的诊断模式（\(diagnosticID)）。\n\(restoreStatus)\n\(migrationError.localizedDescription)",
                state: recoveryState,
                backupManifest: backupManifest
            )
        } catch {
            fatalError("Unable to create the in-memory diagnostic container: \(error.localizedDescription)")
        }
    }
}

private enum RecoveryStoreProbe {
    static func version(at storeURL: URL) -> String? {
        if canOpen(storeURL: storeURL, version: DensosoSchemaV2.self) { return "2.0.0" }
        if canOpen(storeURL: storeURL, version: DensosoSchemaV1.self) { return "1.0.0" }
        return nil
    }

    private static func canOpen<Version: VersionedSchema>(
        storeURL: URL,
        version: Version.Type
    ) -> Bool {
        let schema = Schema(versionedSchema: version)
        let configuration = ModelConfiguration(
            "DensosoRecoveryProbe",
            schema: schema,
            url: storeURL,
            allowsSave: false
        )
        return (try? ModelContainer(for: schema, configurations: [configuration])) != nil
    }
}
