import Foundation

/// 仓库级高层 API。所有方法都是对 git CLI 的薄封装。
public final class Repository: @unchecked Sendable {
    public let root: URL
    private let git: GitClient

    public init(root: URL) {
        self.root = root
        self.git = GitClient(workDirectory: root)
    }

    /// 在给定目录（或其上层）发现仓库根。
    public static func discover(at url: URL) async throws -> Repository {
        let client = GitClient(workDirectory: url)
        let result = try await client.run(["rev-parse", "--show-toplevel"])
        let top = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !top.isEmpty else {
            throw GitError(command: "rev-parse --show-toplevel", exitCode: 1, stderr: "不是 git 仓库")
        }
        return Repository(root: URL(fileURLWithPath: top))
    }

    public func fileURL(for path: String) -> URL {
        root.appendingPathComponent(path)
    }

    // MARK: - 状态

    public func status() async throws -> [FileChange] {
        let result = try await git.run(["status", "--porcelain", "-z"])
        return StatusParser.parse(result.stdoutData)
    }

    public func currentBranch() async throws -> String {
        // symbolic-ref 在「尚无提交」的新仓库上也能给出分支名
        let result = try await git.run(["symbolic-ref", "--short", "-q", "HEAD"], allowedExitCodes: [0, 1])
        let name = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        // 分离 HEAD：退回短 hash
        let head = try await git.run(["rev-parse", "--short", "HEAD"], allowedExitCodes: [0, 128])
        let hash = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return hash.isEmpty ? "(无提交)" : "(分离头 \(hash))"
    }

    public func headSummary() async throws -> String? {
        let result = try await git.run(["log", "-1", "--format=%h %s"], allowedExitCodes: [0, 128])
        let line = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return line.isEmpty ? nil : line
    }

    public func syncStatus() async throws -> SyncStatus {
        let upstreamResult = try await git.run(
            ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"],
            allowedExitCodes: [0, 128]
        )
        let upstream = upstreamResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard upstreamResult.exitCode == 0, !upstream.isEmpty else {
            return SyncStatus(upstream: nil, ahead: 0, behind: 0)
        }
        let counts = try await git.run(
            ["rev-list", "--left-right", "--count", "@{upstream}...HEAD"],
            allowedExitCodes: [0, 128]
        )
        let parts = counts.stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\t")
            .compactMap { Int($0) }
        guard parts.count == 2 else {
            return SyncStatus(upstream: upstream, ahead: 0, behind: 0)
        }
        return SyncStatus(upstream: upstream, ahead: parts[1], behind: parts[0])
    }

    // MARK: - Diff

    /// 单个文件的 diff。`staged` 为 true 时取「暂存区 vs HEAD」，否则取「工作区 vs 暂存区」。
    public func diff(for path: String, staged: Bool) async throws -> FileDiff? {
        var args = staged ? ["diff", "--cached", "-M"] : ["diff"]
        args += ["--", path]
        let result = try await git.run(args)
        return DiffParser.parse(result.stdout).first
    }

    /// 未跟踪文件：与 /dev/null 比对，得到整文件新增的 diff。
    public func untrackedDiff(for path: String) async throws -> FileDiff? {
        let result = try await git.run(
            ["diff", "--no-index", "--", "/dev/null", path],
            allowedExitCodes: [0, 1]
        )
        guard var diff = DiffParser.parse(result.stdout).first else { return nil }
        diff.isNew = true
        if diff.newPath == nil { diff.newPath = path }
        return diff
    }

    // MARK: - 暂存

    public func stage(paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        try await git.run(["add", "--"] + paths)
    }

    public func stageAll() async throws {
        try await git.run(["add", "--all"])
    }

    public func unstage(paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        do {
            try await git.run(["reset", "-q", "HEAD", "--"] + paths)
        } catch {
            // 尚无提交（unborn HEAD）时 reset 不可用，改用 rm --cached
            try await git.run(["rm", "--cached", "-q", "-r", "--"] + paths)
        }
    }

    public func unstageAll() async throws {
        do {
            try await git.run(["reset", "-q", "HEAD", "--", "."])
        } catch {
            try await git.run(["rm", "--cached", "-q", "-r", "--", "."])
        }
    }

    /// 丢弃工作区更改（危险操作，调用方需确认）。
    public func discardWorktree(paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        try await git.run(["restore", "--worktree", "--"] + paths)
    }

    /// 删除未跟踪文件（危险操作，调用方需确认）。
    public func deleteUntracked(path: String) throws {
        try FileManager.default.removeItem(at: fileURL(for: path))
    }

    /// 应用行级暂存补丁。
    public func applyPatch(_ patch: String, reverse: Bool) async throws {
        var args = ["apply", "--cached", "--whitespace=nowarn"]
        if reverse { args.append("--reverse") }
        args.append("-")
        try await git.run(args, stdin: Data(patch.utf8))
    }

    // MARK: - 提交

    public func commit(message: String, amend: Bool = false) async throws {
        var args = ["commit", "-m", message]
        if amend { args.append("--amend") }
        try await git.run(args)
    }

    // MARK: - 分支

    public func branches() async throws -> [Branch] {
        let result = try await git.run(["for-each-ref", "refs/heads", "--format=%(HEAD)%(refname:short)"])
        return result.stdout
            .split(separator: "\n")
            .map(String.init)
            .compactMap { line in
                guard let first = line.first else { return nil }
                let name = String(line.dropFirst())
                return Branch(name: name, isCurrent: first == "*")
            }
    }

    public func checkout(branch: String) async throws {
        try await git.run(["checkout", branch])
    }

    public func createBranch(_ name: String, checkout: Bool = true) async throws {
        if checkout {
            try await git.run(["checkout", "-b", name])
        } else {
            try await git.run(["branch", name])
        }
    }

    // MARK: - 贮藏

    public func stashes() async throws -> [Stash] {
        let result = try await git.run(["stash", "list", "--format=%gs"])
        return result.stdout
            .split(separator: "\n")
            .enumerated()
            .map { Stash(index: $0.offset, message: String($0.element)) }
    }

    public func stashPushAll(includeUntracked: Bool = true, message: String? = nil) async throws {
        var args = ["stash", "push"]
        if includeUntracked { args.append("--include-untracked") }
        if let message, !message.isEmpty { args += ["-m", message] }
        try await git.run(args)
    }

    public func stashPush(paths: [String], message: String? = nil) async throws {
        guard !paths.isEmpty else { return }
        var args = ["stash", "push", "--include-untracked"]
        if let message, !message.isEmpty { args += ["-m", message] }
        args += ["--"] + paths
        try await git.run(args)
    }

    public func stashApply(index: Int, pop: Bool) async throws {
        try await git.run(["stash", pop ? "pop" : "apply", "stash@{\(index)}"])
    }

    public func stashDrop(index: Int) async throws {
        try await git.run(["stash", "drop", "stash@{\(index)}"])
    }

    // MARK: - 远端同步

    public func fetch() async throws {
        try await git.run(["fetch", "--prune"])
    }

    public func pull() async throws {
        // 冲突时 pull 以非零退出，但冲突文件已写入工作区，交由冲突 UI 处理
        try await git.run(["pull", "--no-rebase"], allowedExitCodes: [0, 1])
    }

    public func push() async throws {
        let sync = try await syncStatus()
        if sync.upstream == nil {
            let branch = try await currentBranch()
            try await git.run(["push", "-u", "origin", branch])
        } else {
            try await git.run(["push"])
        }
    }

    // MARK: - 文件列表

    /// 工作区文件（已跟踪 + 未跟踪未忽略），供文件树展示。
    public func listFiles() async throws -> [String] {
        let result = try await git.run(["ls-files", "--cached", "--others", "--exclude-standard", "-z"])
        let paths = result.stdoutData
            .split(separator: 0, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
        return Array(Set(paths)).sorted()
    }
}
