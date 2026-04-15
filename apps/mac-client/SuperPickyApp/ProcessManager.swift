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

    init(port: Int = 8420) {
        self.port = port
    }

    /// Server script path — bundled inside the app, or dev fallback
    private var serverDir: String {
        let bundled = ServerSetup.bundledServerDir.path
        if FileManager.default.fileExists(atPath: bundled + "/superpicky_server.py") {
            return bundled
        }
        #if DEBUG
        let dev = NSString("~/projects/SuperPickyMac/python-server").expandingTildeInPath
        if FileManager.default.fileExists(atPath: dev + "/superpicky_server.py") {
            return dev
        }
        #endif
        return bundled // fallback
    }

    /// Python executable — managed venv, or dev venv fallback
    private var pythonPath: String {
        let managed = ServerSetup.pythonPath
        if FileManager.default.fileExists(atPath: managed) { return managed }
        #if DEBUG
        let dev = NSString("~/projects/SuperPickyMac/python-server/.venv/bin/python").expandingTildeInPath
        if FileManager.default.fileExists(atPath: dev) { return dev }
        #endif
        return "/usr/bin/env python3"
    }

    func start() {
        guard !isRunning else { return }

        healthCheckTask = Task { [weak self] in
            guard let self else { return }
            // Check if server already running
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
            } catch {}
            await self.launchServer()
        }
    }

    private func launchServer() async {
        let script = serverDir + "/superpicky_server.py"

        guard FileManager.default.fileExists(atPath: script) else {
            logger.error("Server script not found at \(script)")
            return
        }

        let proc = Process()
        proc.currentDirectoryURL = URL(fileURLWithPath: serverDir)
        proc.executableURL = URL(fileURLWithPath: pythonPath)
        proc.arguments = [script, "--port", "\(port)"]

        var env = ProcessInfo.processInfo.environment
        #if DEBUG
        let modelsDir = NSString("~/projects/SuperPicky/models").expandingTildeInPath
        if FileManager.default.fileExists(atPath: modelsDir) {
            env["MODELS_DIR"] = modelsDir
        }
        #endif
        proc.environment = env

        let errPipe = Pipe()
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = errPipe

        proc.terminationHandler = { [weak self] proc in
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            if let errStr = String(data: errData, encoding: .utf8), !errStr.isEmpty {
                self?.logger.error("Python server stderr: \(errStr.prefix(500))")
            }
            DispatchQueue.main.async {
                self?.isRunning = false
                self?.isReady = false
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
            } catch {}
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
    }
}
