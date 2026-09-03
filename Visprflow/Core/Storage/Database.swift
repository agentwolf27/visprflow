import Foundation
import GRDB

/// Local history store. Lives in ~/Library/Application Support/Visprflow/visprflow.sqlite.
/// Every dictation row carries the exact request that left the machine, so the privacy
/// contract in the plan is inspectable rather than promised.
enum Database {
    @MainActor private(set) static var queue: DatabaseQueue?

    @MainActor
    static func open() throws {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = support.appending(path: "Visprflow", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "visprflow.sqlite")
        queue = try makeQueue(path: file.path)
        Log.db.info("Database opened at \(file.path, privacy: .public)")
    }

    /// Opens (or creates) a migrated database. Pass nil for an in-memory database in tests.
    static func makeQueue(path: String?) throws -> DatabaseQueue {
        let queue = try path.map { try DatabaseQueue(path: $0) } ?? DatabaseQueue()
        try migrator.migrate(queue)
        return queue
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-dictation-and-timing") { db in
            try db.create(table: "dictation") { t in
                t.primaryKey("id", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("destination", .text).notNull()
                t.column("level", .text).notNull()
                t.column("rawTranscript", .text).notNull()
                t.column("compiledText", .text)
                t.column("requestJSON", .text)
                t.column("status", .text).notNull()
            }
            try db.create(table: "stageTiming") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("dictationId", .text).notNull()
                    .references("dictation", onDelete: .cascade)
                t.column("stage", .text).notNull()
                t.column("offsetMs", .double).notNull()
                t.column("sinceLastMs", .double).notNull()
            }
            try db.create(index: "stageTiming_dictationId", on: "stageTiming", columns: ["dictationId"])
        }
        return migrator
    }
}

struct DictationRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "dictation"

    enum Status: String, Codable {
        case inserted
        case cancelled
        case failed
        case rawFallback
    }

    var id: String
    var createdAt: Date
    var destination: String
    var level: String
    var rawTranscript: String
    var compiledText: String?
    var requestJSON: String?
    var status: Status
}

struct StageTimingRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "stageTiming"

    var id: Int64?
    var dictationId: String
    var stage: String
    var offsetMs: Double
    var sinceLastMs: Double

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// Rows for every mark in a trace, ready to insert alongside its dictation.
    static func rows(for trace: Trace, dictationId: String) -> [StageTimingRecord] {
        trace.stageDurations().map { item in
            StageTimingRecord(
                id: nil,
                dictationId: dictationId,
                stage: item.stage.rawValue,
                offsetMs: Trace.milliseconds(item.offset),
                sinceLastMs: Trace.milliseconds(item.sinceLast)
            )
        }
    }
}
