import Foundation
import os

/// Manages the lifecycle of the bundled Python Coral server.
///
/// On launch, starts the server as a subprocess and polls `/api/system/status`
/// until `startup_complete` is true. On app quit, terminates the process.
@Observable
final class ServerManager {
    private(set) var isReady = false
    private(set) var statusMessage = "Starting server…"
    private(set) var port: Int = 8420

    private var serverProcess: Process?
    private var healthCheckTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.coral.app", category: "ServerManager")

    /// Whether we're running with a bundled server or connecting to an external one.
    enum Mode {
        case bundled    // PyInstaller binary in app bundle
        case external   // Connect to already-running server (dev mode)
    }

    private(set) var mode: Mode = .external

    init() {
        // Check for CORAL_PORT environment variable
        if let envPort = ProcessInfo.processInfo.environment["CORAL_PORT"],
           let p = Int(envPort) {
            port = p
        }

        start()
    }

    /// Determine how to connect: external-only (dev), existing server, bundled, or external fallback.
    private func start() {
        let isDev = ProcessInfo.processInfo.environment["CORAL_DEV"] != nil

        if isDev {
            mode = .external
            startHealthCheck()
            return
        }

        // Probe the port first — if a server is already running, just use it.
        checkForExistingServer { [weak self] alreadyRunning in
            guard let self else { return }
            if alreadyRunning {
                self.mode = .external
                self.logger.info("Server already running on port \(self.port), using external mode")
                self.isReady = true
                self.statusMessage = "Ready (external server)"
            } else if let serverURL = self.bundledServerURL() {
                self.mode = .bundled
                self.launchBundledServer(at: serverURL)
            } else {
                // No bundled server found — fall back to external mode (dev).
                // This is the normal path when running from Xcode without PyInstaller.
                self.mode = .external
                self.logger.info("No bundled server found, connecting to external server on port \(self.port)")
                self.startHealthCheck()
            }
        }
    }

    deinit {
        shutdown()
    }

    // MARK: - Existing Server Detection

    /// Quick probe to see if a server is already responding on our port.
    private func checkForExistingServer(completion: @escaping (Bool) -> Void) {
        let url = URL(string: "http://127.0.0.1:\(port)/api/system/status")!
        let task = URLSession.shared.dataTask(with: url) { data, response, error in
            let running: Bool
            if let http = response as? HTTPURLResponse, http.statusCode == 200,
               let data,
               let status = try? JSONDecoder().decode(SystemStatus.self, from: data) {
                running = status.startupComplete
            } else {
                running = false
            }
            DispatchQueue.main.async { completion(running) }
        }
        task.resume()
    }

    // MARK: - Bundled Server

    private func bundledServerURL() -> URL? {
        // Look for the PyInstaller-compiled server in the app bundle
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let serverBinary = resourceURL
            .appendingPathComponent("coral-server")
            .appendingPathComponent("coral-server")

        if FileManager.default.isExecutableFile(atPath: serverBinary.path) {
            return serverBinary
        }
        return nil
    }

    private func launchBundledServer(at url: URL) {
        statusMessage = "Launching server…"

        let process = Process()
        process.executableURL = url
        process.arguments = ["--host", "127.0.0.1", "--port", String(port)]
        process.environment = ProcessInfo.processInfo.environment

        // Capture server output for debugging
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                self?.logger.warning("Server process terminated with status \(proc.terminationStatus)")
                if !(self?.isReady ?? true) {
                    self?.statusMessage = "Server failed to start (exit \(proc.terminationStatus))"
                }
            }
        }

        do {
            try process.run()
            serverProcess = process
            logger.info("Launched bundled server (PID \(process.processIdentifier)) on port \(self.port)")
            startHealthCheck()
        } catch {
            statusMessage = "Failed to launch server: \(error.localizedDescription)"
            logger.error("Failed to launch server: \(error)")
        }
    }

    // MARK: - Health Check

    private func startHealthCheck() {
        healthCheckTask = Task { @MainActor in
            let url = URL(string: "http://127.0.0.1:\(port)/api/system/status")!
            var attempt = 0
            let maxAttempts = 60  // 30 seconds at 500ms intervals

            while !Task.isCancelled && attempt < maxAttempts {
                attempt += 1
                statusMessage = "Waiting for server… (\(attempt))"

                do {
                    let (data, response) = try await URLSession.shared.data(from: url)
                    if let httpResponse = response as? HTTPURLResponse,
                       httpResponse.statusCode == 200 {
                        let status = try JSONDecoder().decode(SystemStatus.self, from: data)
                        if status.startupComplete {
                            isReady = true
                            statusMessage = "Ready"
                            logger.info("Server is ready after \(attempt) health checks")
                            return
                        }
                    }
                } catch {
                    // Server not up yet, keep polling
                }

                try? await Task.sleep(for: .milliseconds(500))
            }

            if !isReady {
                statusMessage = "Server did not become ready in time"
                logger.error("Server health check timed out after \(attempt) attempts")
            }
        }
    }

    // MARK: - Shutdown

    func shutdown() {
        healthCheckTask?.cancel()
        healthCheckTask = nil

        guard let process = serverProcess, process.isRunning else { return }

        logger.info("Shutting down server (PID \(process.processIdentifier))")

        // Send SIGTERM for graceful shutdown
        process.terminate()

        // Give it a few seconds to clean up
        DispatchQueue.global().async {
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            if process.isRunning {
                // Force kill if it didn't stop gracefully
                process.interrupt()
            }
        }

        serverProcess = nil
    }
}

// MARK: - Models

private struct SystemStatus: Decodable {
    let startupComplete: Bool

    enum CodingKeys: String, CodingKey {
        case startupComplete = "startup_complete"
    }
}
