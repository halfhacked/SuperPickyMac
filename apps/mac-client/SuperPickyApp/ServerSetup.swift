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

            // Find Python ≥3.11
            guard let python = Self.findPython() else {
                throw NSError(domain: "ServerSetup", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Python 3.\(Self.minPythonMinor)+ is required but not found.\n\nInstall it with Homebrew:\n  brew install python3"
                ])
            }
            await updateProgress("Creating virtual environment (Python \(python.version))...")
            try await run(python.path, args: ["-m", "venv", Self.venvDir.path])

            // Upgrade pip first (system Python ships old pip)
            let pip = Self.venvDir.appendingPathComponent("bin/pip").path
            await updateProgress("Upgrading pip...")
            try await run(pip, args: ["install", "--upgrade", "pip"])

            // Install requirements
            await updateProgress("Installing dependencies...")
            let reqPath = Self.bundledServerDir.appendingPathComponent("requirements.txt").path
            try await run(pip, args: ["install", "-r", reqPath], streamProgress: true)

            // Install preen
            await updateProgress("Installing bird identification models...")
            try await run(pip, args: ["install", "birdpreen"], streamProgress: true)

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

    static let minPythonMinor = 11

    /// Find python3 and verify it's ≥3.11. Returns (path, version) or nil.
    static func findPython() -> (path: String, version: String)? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["python3", "--version"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try? proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        // Parse "Python 3.X.Y"
        guard let regex = try? NSRegularExpression(pattern: #"Python (3\.(\d+)\.\d+)"#),
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let versionRange = Range(match.range(at: 1), in: output),
              let minorRange = Range(match.range(at: 2), in: output),
              let minor = Int(output[minorRange]), minor >= minPythonMinor else { return nil }
        return ("python3", String(output[versionRange]))
    }

    private func updateProgress(_ message: String) async {
        await MainActor.run { setupProgress = message }
    }

    private func run(_ executable: String, args: [String], streamProgress: Bool = false) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        if streamProgress {
            outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
                // Parse pip output for package names
                for part in line.components(separatedBy: .newlines) where !part.isEmpty {
                    let trimmed = part.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("Collecting") || trimmed.hasPrefix("Downloading") ||
                       trimmed.hasPrefix("Installing") || trimmed.hasPrefix("Building") {
                        // Show just the package name, truncate long lines
                        let short = String(trimmed.prefix(60))
                        Task { @MainActor [weak self] in
                            self?.setupProgress = short
                        }
                    }
                }
            }
        }

        try process.run()
        process.waitUntilExit()
        outPipe.fileHandleForReading.readabilityHandler = nil

        if process.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "ServerSetup", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: errStr.prefix(500).description])
        }
    }
}
