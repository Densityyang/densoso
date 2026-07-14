import Foundation
import GRDB

/// 本地食材库（只读 SQLite + FTS5）
/// 食材数据来源：GitHub `andforce/ChinaFoodComposition`
final class FoodDatabase {
    private let dbQueue: DatabaseQueue

    /// 从 Bundle 中加载预建的 food_composition.db
    init() throws {
        guard let dbURL = Bundle.main.url(forResource: "food_composition", withExtension: "db") else {
            throw FoodDBError.databaseNotFound
        }
        var config = Configuration()
        config.readonly = true
        self.dbQueue = try DatabaseQueue(path: dbURL.path, configuration: config)
    }

    /// 开发模式：从内存中的 JSON 种子数据创建临时数据库
    init(seedJSON: Data) throws {
        self.dbQueue = try DatabaseQueue()
        try createSchema()
        let items = try JSONDecoder().decode([FoodItem].self, from: seedJSON)
        try dbQueue.write { db in
            for item in items {
                try item.insert(db)
            }
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

    // MARK: - 查询

    /// 按 ID 精确查找
    func lookup(id: Int64) throws -> FoodItem? {
        try dbQueue.read { db in try FoodItem.fetchOne(db, key: id) }
    }

    /// 按名称精确匹配
    func lookup(name: String) throws -> FoodItem? {
        try dbQueue.read { db in
            try FoodItem
                .filter(Column("name") == name)
                .fetchOne(db)
        }
    }

    /// 前缀模糊搜索
    func searchByPrefix(_ prefix: String, limit: Int = 20) throws -> [FoodItem] {
        try dbQueue.read { db in
            try FoodItem
                .filter(Column("name").like("\(prefix)%") || Column("alias").like("\(prefix)%"))
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// 模糊搜索（包含子串匹配）
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
        try dbQueue.read { db in
            let pattern = query
                .components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }
                .map { "\"\($0)\"" }
                .joined(separator: " AND ")
            let sql = """
                SELECT food_items.* FROM food_items
                JOIN food_fts ON food_items.id = food_fts.rowid
                WHERE food_fts MATCH ?
                ORDER BY rank
                LIMIT ?
                """
            return try FoodItem.fetchAll(db, sql: sql, arguments: [pattern, limit])
        }
    }

    /// 按分类列出
    func listByCategory(_ category: String, limit: Int = 50) throws -> [FoodItem] {
        try dbQueue.read { db in
            try FoodItem
                .filter(Column("category") == category)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// 所有分类
    func allCategories() throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT category FROM food_items ORDER BY category")
        }
    }

    /// 总数
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