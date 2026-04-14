import Foundation
import os

/// Manages the Python server environment setup.
/// On first launch, creates a venv and installs dependencies.
/// Stores the venv in ~/Library/Application Support/SuperPicky/
@Observable
final class ServerSetup {
    private let logger = Logger(subsystem: "com.superpicky.mac", category: "ServerSetup")

    var isSettingUp = false
    var setupProgress = ""
    var setupFailed = false
    var setupError = ""

    /// Application support directory for SuperPicky
    static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SuperPicky")
    }

    /// Path to the managed venv
    static var venvDir: URL { supportDir.appendingPathComponent("venv") }
    static var pythonPath: String { venvDir.appendingPathComponent("bin/python").path }

    /// Path to bundled server code inside the app bundle
    static var bundledServerDir: URL {
        Bundle.main.resourceURL!.appendingPathComponent("python-server")
    }

    /// Whether the venv is ready (has been set up)
    var isReady: Bool {
        FileManager.default.fileExists(atPath: Self.pythonPath)
    }

    /// Set up the Python environment if needed. Returns true if ready.
    func ensureSetup() async -> Bool {
        if isReady { return true }

        await MainActor.run {
            isSettingUp = true
            setupProgress = "Creating Python environment..."
            setupFailed = false
        }

        do {
            let fm = FileManager.default
            try fm.createDirectory(at: Self.supportDir, withIntermediateDirectories: true)

            // Create venv
            await updateProgress("Creating virtual environment...")
            try await run("/usr/bin/python3", args: ["-m", "venv", Self.venvDir.path])

            // Install requirements
            await updateProgress("Installing dependencies (this may take a few minutes)...")
            let pip = Self.venvDir.appendingPathComponent("bin/pip").path
            let reqPath = Self.bundledServerDir.appendingPathComponent("requirements.txt").path
            try await run(pip, args: ["install", "--quiet", "-r", reqPath])

            // Install preen
            await updateProgress("Installing bird identification models...")
            try await run(pip, args: ["install", "--quiet", "birdpreen"])

            await MainActor.run {
                isSettingUp = false
                setupProgress = ""
            }
            logger.info("Python environment setup complete")
            return true
        } catch {
            logger.error("Setup failed: \(error)")
            await MainActor.run {
                isSettingUp = false
                setupFailed = true
                setupError = error.localizedDescription
            }
            return false
        }
    }

    private func updateProgress(_ message: String) async {
        await MainActor.run { setupProgress = message }
    }

    private func run(_ executable: String, args: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice

        let errPipe = Pipe()
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "ServerSetup", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: errStr.prefix(500).description])
        }
    }
}
