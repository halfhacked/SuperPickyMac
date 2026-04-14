import os

/// Thin wrapper over Apple's `os.Logger` with categorized static instances.
///
/// Use these instead of constructing a `Logger` ad hoc so subsystem/category
/// strings stay consistent across the app:
///
///     SPLog.pipeline.info("scanned \(count) files")
///     SPLog.http.error("request failed: \(error.localizedDescription)")
enum SPLog {
    private static let subsystem = "com.superpicky.mac"

    static let pipeline = Logger(subsystem: subsystem, category: "pipeline")
    static let http = Logger(subsystem: subsystem, category: "http")
    static let db = Logger(subsystem: subsystem, category: "db")
    static let ui = Logger(subsystem: subsystem, category: "ui")
    static let process = Logger(subsystem: subsystem, category: "process")
}
