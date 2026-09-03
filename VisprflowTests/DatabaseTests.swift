import GRDB
import XCTest
@testable import Visprflow

final class DatabaseTests: XCTestCase {
    func testMigrationCreatesTables() throws {
        let queue = try Database.makeQueue(path: nil)
        try queue.read { db in
            XCTAssertTrue(try db.tableExists("dictation"))
            XCTAssertTrue(try db.tableExists("stageTiming"))
        }
    }

    func testInsertDictationWithTimingsAndCascadeDelete() throws {
        let queue = try Database.makeQueue(path: nil)

        var trace = Trace()
        trace.mark(.keyDown)
        trace.mark(.keyUp)
        trace.mark(.transcriptReady)
        trace.mark(.inserted)

        let dictation = DictationRecord(
            id: "d1",
            createdAt: Date(),
            destination: "claude_code",
            level: "FULL",
            rawTranscript: "rename the uh helper to parse date camel case",
            compiledText: "Rename the helper to parseDate (camelCase).",
            requestJSON: #"{"model":"claude-haiku-4-5"}"#,
            status: .inserted
        )

        try queue.write { db in
            try dictation.insert(db)
            for var row in StageTimingRecord.rows(for: trace, dictationId: dictation.id) {
                try row.insert(db)
            }
        }

        try queue.read { db in
            XCTAssertEqual(try DictationRecord.fetchCount(db), 1)
            XCTAssertEqual(try StageTimingRecord.fetchCount(db), 4)
            let fetched = try XCTUnwrap(try DictationRecord.fetchOne(db, key: "d1"))
            XCTAssertEqual(fetched.status, .inserted)
            XCTAssertEqual(fetched.compiledText, dictation.compiledText)
        }

        try queue.write { db in
            _ = try DictationRecord.deleteOne(db, key: "d1")
        }

        try queue.read { db in
            XCTAssertEqual(try StageTimingRecord.fetchCount(db), 0, "stageTiming rows cascade with their dictation")
        }
    }
}
