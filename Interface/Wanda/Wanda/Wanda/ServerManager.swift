//
//  ServerManager.swift
//  Wanda
//

import Foundation

/// Makes sure Wanda's Python server is running, starting it from the project's
/// `server` folder when it isn't, and stops it when Wanda quits (`stopServer()`).
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

    nonisolated static let defaultLogURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Wanda/server.log")
    /// Where the server's output goes.
    let logURL: URL

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
        startupTimeout: Duration = .seconds(45),
        logURL: URL = ServerManager.defaultLogURL
    ) {
        self.logURL = logURL
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

    /// Stops Wanda's server, whether Wanda started it or it was already running (started
    /// in Terminal, or left over from a crash). Only processes running `uvicorn` from
    /// Wanda's server folder on Wanda's port are touched; each gets a few seconds to shut
    /// down cleanly before it's forced.
    func stopServer(timeout: TimeInterval = 3) {
        let own = process.flatMap { $0.isRunning ? $0 : nil }
        var pids = Set(Self.serverProcessIDs(port: baseURL.port ?? 8000, directory: serverDirectory))
        if let own { pids.remove(own.processIdentifier) }
        own?.terminate()
        for pid in pids { kill(pid, SIGTERM) }

        func isRunning(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, own?.isRunning == true || pids.contains(where: isRunning) {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if let own, own.isRunning { kill(own.processIdentifier, SIGKILL) }
        for pid in pids where isRunning(pid) { kill(pid, SIGKILL) }
        process = nil
        status = .unknown
    }

    /// Stops the server only if Wanda started it (used when a start attempt times out).
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
                status = .failed("The server stopped while starting. See \(logURL.path) for details.")
                return false
            }
        }
        stopIfLaunched()
        status = .failed("The server didn't respond within \(startupTimeout). See \(logURL.path).")
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

    /// Processes serving Wanda: listening on `port`, running uvicorn, from `directory`.
    /// Includes uvicorn's `--reload` watcher so it can't start the server again.
    nonisolated static func serverProcessIDs(port: Int, directory: URL?) -> [pid_t] {
        guard let directory else { return [] }
        let listening = run("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"])
            .split(whereSeparator: \.isNewline).compactMap { pid_t($0) }
        var result = Set<pid_t>()
        for pid in listening where isWandaServer(pid, directory: directory) {
            result.insert(pid)
            if let parent = pid_t(run("/bin/ps", ["-o", "ppid=", "-p", String(pid)]).trimmingCharacters(in: .whitespaces)),
               parent > 1, isWandaServer(parent, directory: directory) {
                result.insert(parent)
            }
        }
        return Array(result)
    }

    private nonisolated static func isWandaServer(_ pid: pid_t, directory: URL) -> Bool {
        let command = run("/bin/ps", ["-o", "command=", "-p", String(pid)])
        guard command.contains("uvicorn") else { return false }
        // `lsof -Fn` prints the working directory as a line starting with "n".
        let cwd = run("/usr/sbin/lsof", ["-a", "-p", String(pid), "-d", "cwd", "-Fn"])
            .split(whereSeparator: \.isNewline)
            .first { $0.hasPrefix("n") }
            .map { String($0.dropFirst()) }
        let expected = directory.resolvingSymlinksInPath().standardizedFileURL.path
        return cwd.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path } == expected
    }

    private nonisolated static func run(_ executable: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
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

        try? fileManager.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        fileManager.createFile(atPath: logURL.path, contents: nil)
        let log = try? FileHandle(forWritingTo: logURL)

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
