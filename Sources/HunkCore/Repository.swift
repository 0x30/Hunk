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
        // -uall：未跟踪目录展开为单个文件，而不是一条 "dir/" 记录
        let result = try await git.run(["status", "--porcelain", "-uall", "-z"])
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

    /// 应用行级补丁。`cached` 为 true 时作用于暂存区（行级暂存），
    /// 为 false 时作用于工作区（hunk 级撤销）。
    public func applyPatch(_ patch: String, reverse: Bool, cached: Bool = true) async throws {
        var args = ["apply", "--whitespace=nowarn"]
        if cached { args.append("--cached") }
        if reverse { args.append("--reverse") }
        args.append("-")
        try await git.run(args, stdin: Data(patch.utf8))
    }

    /// 暂存区里某个文件的内容（diff 折叠展开需要新侧全文）。
    public func indexContent(of path: String) async throws -> String? {
        let result = try await git.run(["show", ":0:\(path)"], allowedExitCodes: [0, 128])
        return result.exitCode == 0 ? result.stdout : nil
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

    // MARK: - 提交历史

    public struct Commit: Identifiable, Hashable, Sendable {
        public let hash: String
        public let shortHash: String
        public let author: String
        public let subject: String
        public let date: Date
        /// 分支 / 标签装饰（HEAD -> main、origin/main…）
        public let refs: [String]
        public var id: String { hash }

        public init(hash: String, shortHash: String, author: String, subject: String, date: Date, refs: [String]) {
            self.hash = hash
            self.shortHash = shortHash
            self.author = author
            self.subject = subject
            self.date = date
            self.refs = refs
        }
    }

    /// 历史中的一行：提交行或纯图形延续行（"|/" 之类）。
    public struct LogEntry: Identifiable, Hashable, Sendable {
        public let id: Int
        public let graph: String
        public let commit: Commit?
    }

    /// 提交历史。`path` 非空时为单文件历史（--follow，无图形）；
    /// 否则为全分支图形历史。
    public func history(limit: Int = 300, path: String? = nil) async throws -> [LogEntry] {
        let format = "%x01%H%x09%h%x09%an%x09%at%x09%D%x09%s"
        let args: [String]
        if let path {
            args = ["log", "--follow", "-n", "\(limit)", "--format=\(format)", "--", path]
        } else {
            args = ["log", "--all", "--graph", "--date-order", "-n", "\(limit)", "--format=\(format)"]
        }
        let result = try await git.run(args, allowedExitCodes: [0, 128])
        guard result.exitCode == 0 else { return [] }

        var entries: [LogEntry] = []
        for (index, rawLine) in result.stdout.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            let line = String(rawLine)
            guard let marker = line.range(of: "\u{01}") else {
                entries.append(LogEntry(id: index, graph: line, commit: nil))
                continue
            }
            let graph = String(line[..<marker.lowerBound])
            let fields = line[marker.upperBound...]
                .split(separator: "\t", maxSplits: 5, omittingEmptySubsequences: false)
                .map(String.init)
            guard fields.count >= 6 else { continue }
            let refs = fields[4]
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            entries.append(LogEntry(
                id: index,
                graph: graph,
                commit: Commit(
                    hash: fields[0],
                    shortHash: fields[1],
                    author: fields[2],
                    subject: fields[5],
                    date: Date(timeIntervalSince1970: Double(fields[3]) ?? 0),
                    refs: refs
                )
            ))
        }
        return entries
    }

    public struct CommitFileChange: Identifiable, Hashable, Sendable {
        public let kind: ChangeKind
        public let path: String
        public let oldPath: String?
        public var id: String { path }
    }

    /// 某个提交改动的文件列表。
    public func filesChanged(in hash: String) async throws -> [CommitFileChange] {
        let result = try await git.run(["show", "--name-status", "--format=", hash])
        return Self.parseNameStatus(result.stdout)
    }

    /// 两个引用之间改动的文件列表。
    public func filesChanged(from base: String, to target: String) async throws -> [CommitFileChange] {
        let result = try await git.run(["diff", "--name-status", base, target])
        return Self.parseNameStatus(result.stdout)
    }

    /// 某个提交里单个文件的 diff。
    public func diff(in hash: String, path: String) async throws -> FileDiff? {
        let result = try await git.run(["show", "--format=", hash, "--", path])
        return DiffParser.parse(result.stdout).first
    }

    /// 两个引用之间单个文件的 diff。
    public func diff(from base: String, to target: String, path: String) async throws -> FileDiff? {
        let result = try await git.run(["diff", base, target, "--", path])
        return DiffParser.parse(result.stdout).first
    }

    private static func parseNameStatus(_ text: String) -> [CommitFileChange] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t").map(String.init)
            guard parts.count >= 2, let statusChar = parts[0].first else { return nil }
            let kind: ChangeKind
            switch statusChar {
            case "A": kind = .added
            case "D": kind = .deleted
            case "R": kind = .renamed
            case "C": kind = .copied
            case "T": kind = .typeChanged
            default: kind = .modified
            }
            if (statusChar == "R" || statusChar == "C"), parts.count >= 3 {
                return CommitFileChange(kind: kind, path: parts[2], oldPath: parts[1])
            }
            return CommitFileChange(kind: kind, path: parts[1], oldPath: nil)
        }
    }

    // MARK: - Blame

    public struct BlameInfo: Sendable {
        public let author: String
        public let summary: String
        public let date: Date?
        public let isUncommitted: Bool
    }

    /// 单行 blame（编辑器光标行内注解）。未跟踪文件或失败返回 nil。
    public func blame(path: String, line: Int) async throws -> BlameInfo? {
        guard line > 0 else { return nil }
        let result = try await git.run(
            ["blame", "--porcelain", "-L", "\(line),\(line)", "--", path],
            allowedExitCodes: [0, 128]
        )
        guard result.exitCode == 0 else { return nil }
        let lines = result.stdout.split(separator: "\n").map(String.init)
        guard let first = lines.first,
              let hash = first.split(separator: " ").first.map(String.init)
        else { return nil }

        var author = ""
        var summary = ""
        var date: Date?
        for entry in lines.dropFirst() {
            if entry.hasPrefix("author ") {
                author = String(entry.dropFirst("author ".count))
            } else if entry.hasPrefix("author-time ") {
                date = Double(entry.dropFirst("author-time ".count)).map { Date(timeIntervalSince1970: $0) }
            } else if entry.hasPrefix("summary ") {
                summary = String(entry.dropFirst("summary ".count))
            }
        }
        return BlameInfo(
            author: author,
            summary: summary,
            date: date,
            isUncommitted: hash.allSatisfy { $0 == "0" }
        )
    }

    /// 整个文件的逐行 blame（blame 视图用）。
    public struct BlameLine: Hashable, Sendable {
        public let line: Int
        public let hash: String
        public let author: String
        public let summary: String
        public let date: Date?
        public let isUncommitted: Bool
        public let text: String
    }

    public func blameFile(path: String) async throws -> [BlameLine] {
        let result = try await git.run(["blame", "--porcelain", "--", path], allowedExitCodes: [0, 128])
        guard result.exitCode == 0 else { return [] }

        struct Meta {
            var author = ""
            var summary = ""
            var date: Date?
        }
        var metas: [String: Meta] = [:]
        var lines: [BlameLine] = []
        var currentHash = ""
        var currentLine = 0

        for raw in result.stdout.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("\t") {
                // 内容行
                let meta = metas[currentHash] ?? Meta()
                lines.append(BlameLine(
                    line: currentLine,
                    hash: currentHash,
                    author: meta.author,
                    summary: meta.summary,
                    date: meta.date,
                    isUncommitted: currentHash.allSatisfy { $0 == "0" },
                    text: String(line.dropFirst())
                ))
            } else if line.count > 40,
                      line.prefix(40).allSatisfy(\.isHexDigit),
                      line.dropFirst(40).hasPrefix(" ") {
                // 头行：<hash> <orig> <final> [<num>]
                let parts = line.split(separator: " ")
                currentHash = String(parts[0])
                currentLine = parts.count > 2 ? Int(parts[2]) ?? 0 : 0
                if metas[currentHash] == nil { metas[currentHash] = Meta() }
            } else if line.hasPrefix("author ") {
                metas[currentHash]?.author = String(line.dropFirst("author ".count))
            } else if line.hasPrefix("author-time ") {
                metas[currentHash]?.date = Double(line.dropFirst("author-time ".count))
                    .map { Date(timeIntervalSince1970: $0) }
            } else if line.hasPrefix("summary ") {
                metas[currentHash]?.summary = String(line.dropFirst("summary ".count))
            }
        }
        return lines
    }

    // MARK: - 全局搜索

    public struct GrepHit: Identifiable, Hashable, Sendable {
        public let path: String
        public let line: Int
        public let text: String
        public var id: String { "\(path):\(line)" }
    }

    /// 全仓库内容搜索（git grep，含未跟踪文件，忽略二进制与大小写）。
    public func grep(_ query: String, limit: Int = 400) async throws -> [GrepHit] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let result = try await git.run(
            ["grep", "-n", "-I", "--untracked", "--ignore-case",
             "--max-count=50", "-e", trimmed, "--", "."],
            allowedExitCodes: [0, 1]  // 1 = 无匹配
        )
        guard result.exitCode == 0 else { return [] }

        var hits: [GrepHit] = []
        for raw in result.stdout.split(separator: "\n").prefix(limit) {
            let line = String(raw)
            guard let firstColon = line.firstIndex(of: ":"),
                  let secondColon = line[line.index(after: firstColon)...].firstIndex(of: ":")
            else { continue }
            let path = String(line[..<firstColon])
            guard let number = Int(line[line.index(after: firstColon)..<secondColon]) else { continue }
            let text = String(line[line.index(after: secondColon)...])
            hits.append(GrepHit(path: path, line: number, text: text))
        }
        return hits
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
