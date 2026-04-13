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
    private let pythonServerPath: String

    init(port: Int = 8420) {
        self.port = port
        if let bundledPath = Bundle.main.path(forResource: "superpicky_server", ofType: "py", inDirectory: "PythonBackend") {
            self.pythonServerPath = bundledPath
        } else {
            self.pythonServerPath = NSString("~/projects/SuperPickyMac/python-server/superpicky_server.py").expandingTildeInPath
        }
    }

    func start() {
        guard !isRunning else { return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["python3", pythonServerPath, "--port", "\(port)"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.isRunning = false
                self?.isReady = false
            }
        }

        do {
            try proc.run()
            process = proc
            isRunning = true
            logger.info("Python server started on port \(self.port)")
            startHealthChecks()
        } catch {
            logger.error("Failed to start Python server: \(error)")
        }
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

    private func startHealthChecks() {
        healthCheckTask = Task { [weak self] in
            guard let self else { return }
            let client = HTTPInferenceClient(port: self.port)
            for _ in 0..<120 {
                if Task.isCancelled { return }
                do {
                    let health = try await client.healthCheck()
                    if health.status == "ready" {
                        await MainActor.run { self.isReady = true }
                        self.logger.info("Python server ready")
                        return
                    }
                } catch {
                    // Not ready yet
                }
                try? await Task.sleep(for: .seconds(1))
            }
            self.logger.error("Python server failed to become ready within 120s")
        }
    }
}
