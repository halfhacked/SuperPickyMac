import Foundation

/// Resolves machine-specific filesystem paths needed to launch the Python
/// inference server. Resolution priority for each value is:
///   1. Environment variable override (useful for CI / packaged builds)
///   2. Bundled resource directory (when shipped inside an .app)
///   3. Developer fallback paths under `~/projects/...`
///
/// The struct is `Sendable` so it can be passed across actor boundaries.
struct ProcessConfiguration: Sendable {
    /// Directory containing `superpicky_server.py` and the Python `.venv`.
    let serverDir: String
    /// Directory containing model weights, exported to the child process as `MODELS_DIR`.
    let modelsDir: String
    /// Path to the Python interpreter to launch the server with.
    /// May be either an absolute path to a binary or `/usr/bin/env python3`.
    let pythonPath: String

    init(serverDir: String, modelsDir: String, pythonPath: String) {
        self.serverDir = serverDir
        self.modelsDir = modelsDir
        self.pythonPath = pythonPath
    }

    /// Resolves a configuration using env vars, bundle resources, and dev fallbacks.
    static func resolve() -> ProcessConfiguration {
        let env = ProcessInfo.processInfo.environment

        let serverDir = env["SUPERPICKY_SERVER_DIR"]
            ?? Bundle.main.resourceURL?.appendingPathComponent("python-server").path
            ?? NSString("~/projects/SuperPickyMac/python-server").expandingTildeInPath

        let modelsDir = env["SUPERPICKY_MODELS_DIR"]
            ?? Bundle.main.resourceURL?.appendingPathComponent("models").path
            ?? NSString("~/projects/SuperPicky/models").expandingTildeInPath

        let pythonPath: String
        if let override = env["SUPERPICKY_PYTHON"] {
            pythonPath = override
        } else {
            let venvPython = serverDir + "/.venv/bin/python"
            if FileManager.default.fileExists(atPath: venvPython) {
                pythonPath = venvPython
            } else {
                pythonPath = "/usr/bin/env python3"
            }
        }

        return ProcessConfiguration(
            serverDir: serverDir,
            modelsDir: modelsDir,
            pythonPath: pythonPath
        )
    }
}
