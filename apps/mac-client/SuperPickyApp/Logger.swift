import os

extension Logger {
    static let pipeline = Logger(subsystem: "com.superpicky.mac", category: "Pipeline")
    static let inference = Logger(subsystem: "com.superpicky.mac", category: "Inference")
    static let database = Logger(subsystem: "com.superpicky.mac", category: "Database")
    static let ui = Logger(subsystem: "com.superpicky.mac", category: "UI")
}
