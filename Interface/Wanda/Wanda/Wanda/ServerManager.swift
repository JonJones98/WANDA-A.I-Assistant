//
//  ServerManager.swift
//  Wanda
//

import Foundation

/// Makes sure Wanda's Python server is running, starting it from the project's
/// `server` folder when it isn't. A server Wanda started is stopped when Wanda quits;
/// one that was already running is left alone.
@MainActor
final class ServerManager: ObservableObject {
    enum Status: Equatable {
        case unknown
        case starting
        case running
        case failed(String)
    }

    @Published private(set) var status: Status = .unknown

    let baseURL: URL
    let serverDirectory: URL?
    private let pythonURL: URL?
    private let startupTimeout: Duration
    private var process: Process?
    private var pendingCheck: Task<Bool, Never>?

    nonisolated static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Wanda/server.log")

    /// The server folder: a `WandaServerDirectory` user default if set, otherwise the
    /// path Xcode filled into Info.plist at build time (the repo's `server` folder).
    nonisolated static var configuredServerDirectory: URL? {
        let path = UserDefaults.standard.string(forKey: "WandaServerDirectory")
            ?? Bundle.main.object(forInfoDictionaryKey: "WandaServerDirectory") as? String
        guard let path, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).standardizingPath, isDirectory: true)
    }

    init(
        baseURL: URL = WandaAPIClient.defaultBaseURL,
        serverDirectory: URL? = ServerManager.configuredServerDirectory,
        pythonURL: URL? = nil,
        startupTimeout: Duration = .seconds(45)
    ) {
        self.baseURL = baseURL
        self.serverDirectory = serverDirectory
        self.pythonURL = pythonURL ?? serverDirectory?.appendingPathComponent("wandaenv/bin/python")
        self.startupTimeout = startupTimeout
    }

    /// Returns true once the server answers, starting it first if needed. Concurrent
    /// callers share one check, so the server is never launched twice.
    @discardableResult
    func ensureRunning() async -> Bool {
        if let pendingCheck { return await pendingCheck.value }
        let check = Task { await checkOrStart() }
        pendingCheck = check
        let isRunning = await check.value
        pendingCheck = nil
        return isRunning
    }

    /// Stops the server if Wanda started it.
    func stopIfLaunched() {
        guard let process, process.isRunning else { return }
        process.terminate()
        self.process = nil
    }

    private func checkOrStart() async -> Bool {
        if await isHealthy() {
            status = .running
            return true
        }
        if let error = launch() {
            status = .failed(error)
            return false
        }
        status = .starting

        let deadline = ContinuousClock.now + startupTimeout
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(400))
            if await isHealthy() {
                status = .running
                return true
            }
            if process?.isRunning != true {
                process = nil
                status = .failed("The server stopped while starting. See \(Self.logURL.path) for details.")
                return false
            }
        }
        stopIfLaunched()
        status = .failed("The server didn't respond within \(startupTimeout). See \(Self.logURL.path).")
        return false
    }

    /// True if Wanda's server (not some other program on the port) answers.
    func isHealthy() async -> Bool {
        var request = URLRequest(url: baseURL)
        request.timeoutInterval = 2
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
        return String(decoding: data, as: UTF8.self).contains("Wanda")
    }

    /// Starts uvicorn in the background. Returns an error message, or nil on success.
    private func launch() -> String? {
        guard let serverDirectory, let pythonURL else {
            return "Wanda doesn't know where its server folder is. Set it with: defaults write JourneyDev.Wanda WandaServerDirectory /path/to/server"
        }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: serverDirectory.appendingPathComponent("main.py").path) else {
            return "No server found at \(serverDirectory.path)."
        }
        guard fileManager.isExecutableFile(atPath: pythonURL.path) else {
            return "The server's Python environment is missing (\(pythonURL.path)). Create it with: python3 -m venv wandaenv && wandaenv/bin/pip install -r requirements.txt"
        }

        try? fileManager.createDirectory(at: Self.logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        fileManager.createFile(atPath: Self.logURL.path, contents: nil)
        let log = try? FileHandle(forWritingTo: Self.logURL)

        let process = Process()
        process.executableURL = pythonURL
        process.arguments = [
            "-m", "uvicorn", "main:app",
            "--host", baseURL.host ?? "127.0.0.1",
            "--port", String(baseURL.port ?? 8000),
        ]
        process.currentDirectoryURL = serverDirectory
        // Drop Xcode's DYLD_* debugging variables so the server runs as it would from Terminal.
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("DYLD_") }
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment
        process.standardOutput = log
        process.standardError = log
        do {
            try process.run()
        } catch {
            return "Couldn't start the server: \(error.localizedDescription)"
        }
        self.process = process
        return nil
    }
}
