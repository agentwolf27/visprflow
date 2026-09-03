import Foundation
import OSLog

/// One logger per pipeline area. Read them with:
///   log stream --predicate 'subsystem == "com.vish.visprflow"' --level debug
enum Log {
    static let subsystem = Bundle.main.bundleIdentifier ?? "com.vish.visprflow"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let permissions = Logger(subsystem: subsystem, category: "permissions")
    static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let stt = Logger(subsystem: subsystem, category: "stt")
    static let compile = Logger(subsystem: subsystem, category: "compile")
    static let insert = Logger(subsystem: subsystem, category: "insert")
    static let db = Logger(subsystem: subsystem, category: "db")
    static let timing = Logger(subsystem: subsystem, category: "timing")
}
