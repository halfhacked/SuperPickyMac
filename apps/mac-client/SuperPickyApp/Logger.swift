import os

extension Logger {
    static let pipeline = Logger(subsystem: "com.halfhacked.superpicky", category: "Pipeline")
    static let inference = Logger(subsystem: "com.halfhacked.superpicky", category: "Inference")
    static let database = Logger(subsystem: "com.halfhacked.superpicky", category: "Database")
    static let ui = Logger(subsystem: "com.halfhacked.superpicky", category: "UI")
    static let navigation = Logger(subsystem: "com.halfhacked.superpicky", category: "NavigationState")
}
