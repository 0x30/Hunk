import Foundation

/// 一次 git 调用的结果。
public struct GitResult {
    public let exitCode: Int32
    public let stdoutData: Data
    public let stderr: String

    public var stdout: String { String(data: stdoutData, encoding: .utf8) ?? "" }
}

public struct GitError: Error, LocalizedError {
    public let command: String
    public let exitCode: Int32
    public let stderr: String

    public init(command: String, exitCode: Int32, stderr: String) {
        self.command = command
        self.exitCode = exitCode
        self.stderr = stderr
    }

    public var errorDescription: String? {
        let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return "git \(command) 失败（退出码 \(exitCode)）" + (detail.isEmpty ? "" : "：\(detail)")
    }
}

/// 对系统 git CLI 的进程封装。所有调用都带 `-c core.quotepath=false`，
/// 保证非 ASCII 路径按 UTF-8 原样输出。
public final class GitClient: @unchecked Sendable {
    public let workDirectory: URL

    public init(workDirectory: URL) {
        self.workDirectory = workDirectory
    }

    /// 执行 git 命令；退出码不在 `allowedExitCodes` 内时抛出 GitError。
    @discardableResult
    public func run(
        _ arguments: [String],
        stdin: Data? = nil,
        allowedExitCodes: Set<Int32> = [0]
    ) async throws -> GitResult {
        let result = try await raw(arguments, stdin: stdin)
        guard allowedExitCodes.contains(result.exitCode) else {
            throw GitError(
                command: arguments.joined(separator: " "),
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }
        return result
    }

    /// 执行 git 命令，不检查退出码。
    public func raw(_ arguments: [String], stdin: Data? = nil) async throws -> GitResult {
        let dir = workDirectory
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try Self.runSync(arguments, in: dir, stdin: stdin))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func runSync(_ arguments: [String], in dir: URL, stdin: Data?) throws -> GitResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-c", "core.quotepath=false", "-C", dir.path] + arguments

        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"  // 永不交互式询问凭据
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let stdinPipe = Pipe()
        if stdin != nil { process.standardInput = stdinPipe }

        try process.run()
        if let stdin {
            stdinPipe.fileHandleForWriting.write(stdin)
            stdinPipe.fileHandleForWriting.closeFile()
        }
        // 先读完输出再 waitUntilExit，避免管道缓冲区写满导致死锁
        let out = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let err = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return GitResult(
            exitCode: process.terminationStatus,
            stdoutData: out,
            stderr: String(data: err, encoding: .utf8) ?? ""
        )
    }
}
