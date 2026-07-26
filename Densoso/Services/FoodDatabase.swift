import Foundation
import GRDB

/// 本地食材库（只读 SQLite + FTS5）
final class FoodDatabase {
    private let dbQueue: DatabaseQueue

    init() throws {
        guard let dbURL = Bundle.main.url(forResource: "food_composition", withExtension: "db") else {
            throw FoodDBError.databaseNotFound
        }
        var config = Configuration()
        config.readonly = true
        self.dbQueue = try DatabaseQueue(path: dbURL.path, configuration: config)
    }

    init(seedJSON: Data) throws {
        self.dbQueue = try DatabaseQueue()
        try createSchema()
        let items = try JSONDecoder().decode([FoodItem].self, from: seedJSON)
        try dbQueue.write { db in
            for item in items {
                try item.insert(db)
            }
            try db.execute(sql: "INSERT INTO food_fts(food_fts) VALUES('rebuild')")
        }
    }

    private func createSchema() throws {
        try dbQueue.write { db in
            try db.create(table: "food_items") { t in
                t.primaryKey("id", .integer)
                t.column("name", .text).notNull()
                t.column("alias", .text)
                t.column("category", .text).notNull()
                t.column("edible", .integer).notNull().defaults(to: 100)
                t.column("energyKcal", .integer).notNull()
                t.column("proteinG", .double).notNull().defaults(to: 0)
                t.column("fatG", .double).notNull().defaults(to: 0)
                t.column("carbohydrateG", .double).notNull().defaults(to: 0)
                t.column("fiberG", .double)
            }
            try db.create(index: "idx_food_name", on: "food_items", columns: ["name"])
            try db.create(index: "idx_food_category", on: "food_items", columns: ["category"])
            try db.create(virtualTable: "food_fts", using: FTS5()) { t in
                t.column("name")
                t.column("alias")
                t.column("category")
                t.content = "food_items"
                t.contentRowID = "id"
            }
        }
    }

    func lookup(id: Int64) throws -> FoodItem? {
        try dbQueue.read { db in try FoodItem.fetchOne(db, key: id) }
    }

    func lookup(name: String) throws -> FoodItem? {
        try dbQueue.read { db in
            try FoodItem
                .filter(Column("name") == name)
                .fetchOne(db)
        }
    }

    func searchByPrefix(_ prefix: String, limit: Int = 20) throws -> [FoodItem] {
        try dbQueue.read { db in
            try FoodItem
                .filter(Column("name").like("\(prefix)%") || Column("alias").like("\(prefix)%"))
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// 模糊搜索（包含子串匹配）—— GRDB 参数化查询，query 中的 % 为 SQL LIKE 通配符
    func search(query: String, limit: Int = 10) throws -> [FoodItem] {
        try dbQueue.read { db in
            try FoodItem
                .filter(
                    Column("name").like("%\(query)%") ||
                    Column("alias").like("%\(query)%")
                )
                .order(Column("category"))
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// FTS5 全文搜索（多关键词）
    func ftsSearch(query: String, limit: Int = 10) throws -> [FoodItem] {
        let boundedLimit = min(max(limit, 0), 100)
        guard boundedLimit > 0 else { return [] }

        let tokens = query
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }

        guard !tokens.isEmpty else { return [] }

        return try dbQueue.read { db in
            let pattern = tokens
                .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
                .joined(separator: " AND ")
            let sql = """
                SELECT food_items.* FROM food_items
                JOIN food_fts ON food_items.id = food_fts.rowid
                WHERE food_fts MATCH ?
                ORDER BY rank
                LIMIT ?
                """
            return try FoodItem.fetchAll(db, sql: sql, arguments: [pattern, boundedLimit])
        }
    }

    func listByCategory(_ category: String, limit: Int = 50) throws -> [FoodItem] {
        try dbQueue.read { db in
            try FoodItem
                .filter(Column("category") == category)
                .limit(limit)
                .fetchAll(db)
        }
    }

    func allCategories() throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT category FROM food_items ORDER BY category")
        }
    }

    var count: Int {
        (try? dbQueue.read { db in try FoodItem.fetchCount(db) }) ?? 0
    }
}

enum FoodDBError: Error, LocalizedError {
    case databaseNotFound

    var errorDescription: String? {
        switch self {
        case .databaseNotFound: return "食材数据库未找到，请确保 food_composition.db 已打包到 Bundle"
        }
    }
}
