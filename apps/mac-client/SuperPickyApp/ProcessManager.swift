import Foundation
import os

@Observable
final class ProcessManager {
    private var process: Process?
    private let logger = Logger(subsystem: "com.superpicky.mac", category: "ProcessManager")
    private(set) var isRunning = false
    private(set) var isReady = false
    private var healthCheckTask: Task<Void, Never>?

    let port: Int
    private let configuration: ProcessConfiguration

    init(port: Int = 8420, configuration: ProcessConfiguration = .resolve()) {
        self.port = port
        self.configuration = configuration
    }

    func start() {
        guard !isRunning else { return }

        // First check if a server is already running on this port
        healthCheckTask = Task { [weak self] in
            guard let self else { return }
            let client = HTTPInferenceClient(port: self.port)
            do {
                let health = try await client.healthCheck()
                if health.status == "ready" {
                    await MainActor.run {
                        self.isRunning = true
                        self.isReady = true
                    }
                    self.logger.info("Connected to existing server on port \(self.port)")
                    return
                }
            } catch {
                // No existing server, start one
            }
            await self.launchServer()
        }
    }

    private func launchServer() async {
        let serverScript = configuration.serverDir + "/superpicky_server.py"

        guard FileManager.default.fileExists(atPath: serverScript) else {
            logger.error("Server script not found at \(serverScript)")
            return
        }

        let proc = Process()
        proc.currentDirectoryURL = URL(fileURLWithPath: configuration.serverDir)

        if FileManager.default.fileExists(atPath: configuration.pythonPath) {
            proc.executableURL = URL(fileURLWithPath: configuration.pythonPath)
            proc.arguments = [serverScript, "--port", "\(port)"]
        } else {
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = ["python3", serverScript, "--port", "\(port)"]
        }

        var env = ProcessInfo.processInfo.environment
        env["MODELS_DIR"] = configuration.modelsDir
        proc.environment = env

        // Log stderr for debugging
        let errPipe = Pipe()
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = errPipe

        proc.terminationHandler = { [weak self] proc in
            // Read any error output
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            if let errStr = String(data: errData, encoding: .utf8), !errStr.isEmpty {
                self?.logger.error("Python server stderr: \(errStr.prefix(500))")
            }
            DispatchQueue.main.async {
                self?.isRunning = false
                self?.isReady = false
                self?.logger.info("Python server exited with code \(proc.terminationStatus)")
            }
        }

        do {
            try proc.run()
            await MainActor.run {
                self.process = proc
                self.isRunning = true
            }
            logger.info("Python server launched on port \(self.port)")
            await pollHealth()
        } catch {
            logger.error("Failed to start Python server: \(error)")
        }
    }

    private func pollHealth() async {
        let client = HTTPInferenceClient(port: self.port)
        for _ in 0..<120 {
            if Task.isCancelled { return }
            do {
                let health = try await client.healthCheck()
                if health.status == "ready" {
                    await MainActor.run { self.isReady = true }
                    logger.info("Python server ready")
                    return
                }
            } catch {
                // Not ready yet
            }
            try? await Task.sleep(for: .seconds(1))
        }
        logger.error("Python server failed to become ready within 120s")
    }

    func stop() {
        healthCheckTask?.cancel()
        healthCheckTask = nil
        process?.terminate()
        process = nil
        isRunning = false
        isReady = false
        logger.info("Python server stopped")
    }
}
