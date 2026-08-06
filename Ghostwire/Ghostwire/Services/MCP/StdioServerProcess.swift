//
//  StdioServerProcess.swift
//  Ghostwire
//
//  GW-219: the swift-sdk StdioTransport wraps file descriptors — it does
//  NOT spawn the server. This owns the Process lifecycle: spawn with the
//  resolved absolute path + injected env (values from Keychain, in-memory
//  only), expose pipes as a StdioTransport, capture a stderr tail for
//  error remedies in the UI, and tear down hard (TERM, then KILL).
//

import Foundation
import MCP
import System

final class StdioServerProcess {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()

    /// Last ~2KB of stderr — surfaced in the server detail view on failure.
    private(set) var stderrTail = ""
    private var stderrRedactor = StdioSecretRedactor(values: [])
    var onTermination: ((Int32) -> Void)?

    var isRunning: Bool { process.isRunning }

    enum SpawnError: LocalizedError {
        case notExecutable(String)
        var errorDescription: String? {
            switch self {
            case .notExecutable(let path):
                return "\(path) is not an executable file. Is the server installed?"
            }
        }
    }

    /// `environment` values may include secrets — never log them.
    func start(executablePath: String, arguments: [String], environment: [String: String]) throws {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw SpawnError.notExecutable(executablePath)
        }
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        environment.forEach { env[$0.key] = $0.value }
        process.environment = env
        stderrRedactor = StdioSecretRedactor(values: Array(environment.values))
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self, let chunk = String(data: handle.availableData, encoding: .utf8),
                !chunk.isEmpty
            else { return }
            self.stderrTail = String(
                (self.stderrTail + self.stderrRedactor.redact(chunk)).suffix(2048))
        }
        process.terminationHandler = { [weak self] proc in
            self?.stderrPipe.fileHandleForReading.readabilityHandler = nil
            self?.onTermination?(proc.terminationStatus)
        }
        try process.run()
    }

    /// Transport over the child's stdio. Client writes -> child stdin;
    /// client reads <- child stdout.
    func makeTransport() -> StdioTransport {
        StdioTransport(
            input: FileDescriptor(rawValue: stdoutPipe.fileHandleForReading.fileDescriptor),
            output: FileDescriptor(rawValue: stdinPipe.fileHandleForWriting.fileDescriptor)
        )
    }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()  // SIGTERM
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { [process] in
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }
}

private struct StdioSecretRedactor {
    private let secrets: [String]

    init(values: [String]) {
        self.secrets = Array(Set(values.filter { $0.count >= 8 }))
            .sorted { $0.count > $1.count }
    }

    func redact(_ input: String) -> String {
        var output = input
        for secret in secrets {
            output = output.replacingOccurrences(of: secret, with: "[redacted]")
        }
        return output
    }
}
