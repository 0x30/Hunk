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
            throw GitError(command: "rev-parse --show-toplevel", exitCode: 1, stderr: ctr("不是 git 仓库", "Not a git repository"))
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
        return hash.isEmpty ? ctr("(无提交)", "(no commits)") : ctr("(分离头 \(hash))", "(detached \(hash))")
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

    /// HEAD（上次提交）里某个文件的内容；用作编辑器改动标记的基线。
    /// 文件未跟踪 / 尚无提交（128）→ 返回 nil，调用方按「整文件新增」处理。
    public func headContent(of path: String) async throws -> String? {
        let result = try await git.run(["show", "HEAD:\(path)"], allowedExitCodes: [0, 128])
        return result.exitCode == 0 ? result.stdout : nil
    }

    // MARK: - 提交

    public func commit(message: String, amend: Bool = false) async throws {
        var args = ["commit", "-m", message]
        if amend { args.append("--amend") }
        try await git.run(args)
    }

    /// 撤销最近一次提交，改动保留在暂存区（git reset --soft HEAD~1）。
    public func undoLastCommit() async throws {
        try await git.run(["reset", "--soft", "HEAD~1"])
    }

    /// 最近一次提交的完整消息（%B，含多行正文）。
    public func lastCommitMessage() async throws -> String {
        let result = try await git.run(["log", "-1", "--format=%B"], allowedExitCodes: [0, 128])
        return result.stdout.trimmingCharacters(in: .newlines)
    }

    /// 还原（revert）一个提交：生成一个抵消其改动的新提交（不重写历史，已推送也安全）。
    /// 冲突时以非零退出，冲突文件已写入工作区，交由「合并更改」UI 处理（解决后提交即完成 revert）。
    public func revert(commit hash: String) async throws {
        try await git.run(["revert", "--no-edit", hash], allowedExitCodes: [0, 1])
    }

    /// reset 模式：soft 改动留暂存区，mixed 改动留工作区(默认)，hard 丢弃所有改动。
    public enum ResetMode: String, Sendable { case soft, mixed, hard }

    /// 把当前分支 HEAD 重置到指定提交。hard 为危险操作（丢弃工作区与暂存区），调用方需确认。
    public func reset(to hash: String, mode: ResetMode) async throws {
        try await git.run(["reset", "--\(mode.rawValue)", hash])
    }

    /// 把指定提交摘取（cherry-pick）到当前分支：生成一个改动相同的新提交。
    /// 冲突时暂停，冲突文件已写入工作区，交由「合并更改」UI 处理（解决后提交完成）。
    public func cherryPick(commit hash: String) async throws {
        try await git.run(["cherry-pick", hash], allowedExitCodes: [0, 1])
    }

    /// 当前分支(HEAD)可达的提交 hash 集合（限量）。历史右键据此区分提交在不在当前分支：
    /// revert/reset 仅对当前分支的提交有意义，cherry-pick 仅对其他分支的提交有意义。
    public func headReachableHashes(limit: Int = 2000) async throws -> Set<String> {
        let result = try await git.run(["rev-list", "--max-count=\(limit)", "HEAD"], allowedExitCodes: [0, 128])
        guard result.exitCode == 0 else { return [] }
        return Set(result.stdout.split(separator: "\n").map(String.init))
    }

    // MARK: - 交互式变基（interactive rebase）

    /// base..HEAD 之间的提交（旧→新顺序），供交互式变基编排。
    public func commitsToRebase(after base: String) async throws -> [Commit] {
        let format = "%H%x09%h%x09%an%x09%at%x09%s"
        let result = try await git.run(
            ["log", "--reverse", "--format=\(format)", "\(base)..HEAD"],
            allowedExitCodes: [0, 128]
        )
        guard result.exitCode == 0 else { return [] }
        return result.stdout.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 5 else { return nil }
            return Commit(hash: f[0], shortHash: f[1], author: f[2], subject: f[4],
                          date: Date(timeIntervalSince1970: Double(f[3]) ?? 0), refs: [])
        }
    }

    /// 执行交互式变基：把编排好的 todo 注入 `git rebase -i base`。
    /// pick 原样、squash 用 fixup(合并进上一条)、drop 省略该行；
    /// GIT_SEQUENCE_EDITOR 用我们的 todo 覆盖 git 待办，GIT_EDITOR=true 跳过任何消息编辑不卡住。
    /// 冲突时以非零退出，交由「合并更改」UI 解决后 `rebaseContinue()`。
    public func interactiveRebase(onto base: String, todo: [(hash: String, action: RebaseAction)]) async throws {
        var lines: [String] = []
        for item in todo {
            switch item.action {
            case .pick: lines.append("pick \(item.hash)")
            case .squash: lines.append("fixup \(item.hash)")
            case .drop: break
            }
        }
        let todoText = lines.joined(separator: "\n") + "\n"
        let todoURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hunk-rebase-todo-\(UUID().uuidString)")
        try todoText.write(to: todoURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: todoURL) }
        try await git.run(
            ["rebase", "-i", base],
            allowedExitCodes: [0, 1],
            extraEnv: [
                "GIT_SEQUENCE_EDITOR": "cp '\(todoURL.path)'",
                "GIT_EDITOR": "true",
            ]
        )
    }

    /// 是否有变基正在进行（冲突中断等）。
    public func rebaseInProgress() async throws -> Bool {
        let fm = FileManager.default
        for name in ["rebase-merge", "rebase-apply"] {
            let r = try await git.run(["rev-parse", "--git-path", name], allowedExitCodes: [0, 128])
            let p = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !p.isEmpty else { continue }
            let url = p.hasPrefix("/") ? URL(fileURLWithPath: p) : root.appendingPathComponent(p)
            if fm.fileExists(atPath: url.path) { return true }
        }
        return false
    }

    /// 继续变基（需先解决并暂存冲突）。GIT_EDITOR=true 跳过续作时的消息编辑。
    public func rebaseContinue() async throws {
        try await git.run(["rebase", "--continue"], allowedExitCodes: [0, 1], extraEnv: ["GIT_EDITOR": "true"])
    }

    /// 中止变基，回到变基前状态。
    public func rebaseAbort() async throws {
        try await git.run(["rebase", "--abort"])
    }

    // MARK: - 分支

    public func branches() async throws -> [Branch] {
        let result = try await git.run(["for-each-ref", "refs/heads", "--format=%(HEAD)%(refname:short)"])
        // 已合并进 HEAD 的分支集合，用于在列表里标记「已合并」。
        // 空仓库（unborn HEAD）跑 --merged 会 fatal，容错为「无已合并分支」。
        let mergedResult = try await git.run(["branch", "--format=%(refname:short)", "--merged"], allowedExitCodes: [0, 128])
        let merged = Set(mergedResult.stdout.split(separator: "\n").map(String.init))
        return result.stdout
            .split(separator: "\n")
            .map(String.init)
            .compactMap { line in
                guard let first = line.first else { return nil }
                let name = String(line.dropFirst())
                return Branch(name: name, isCurrent: first == "*", isMerged: merged.contains(name))
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

    /// 已合并进当前分支的本地分支（不含当前分支与 main/master/develop 主干）。
    public func mergedBranches() async throws -> [String] {
        let result = try await git.run(["branch", "--format=%(refname:short)", "--merged"], allowedExitCodes: [0, 128])
        let protected: Set<String> = ["main", "master", "develop"]
        let current = try await currentBranch()
        return result.stdout
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty && $0 != current && !protected.contains($0) }
    }

    /// 删除本地分支（仅限已合并的，等价 `git branch -d`）。
    public func deleteBranch(_ name: String) async throws {
        try await git.run(["branch", "-d", name])
    }

    /// 把指定分支合并进当前分支（冲突时正常返回，由状态列表呈现冲突文件）。
    public func merge(branch: String) async throws {
        try await git.run(["merge", "--no-edit", branch], allowedExitCodes: [0, 1])
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

    // MARK: - 工作树（worktree）

    /// 所有工作树（主 + 链接）。porcelain 第一条记录是主工作树。
    /// 解析 `git worktree list --porcelain`：每条记录由若干 `key value` 行组成，记录间以空行分隔。
    public func worktrees() async throws -> [Worktree] {
        let result = try await git.run(["worktree", "list", "--porcelain"], allowedExitCodes: [0, 128])
        guard result.exitCode == 0 else { return [] }

        let myRoot = root.resolvingSymlinksInPath().path
        var trees: [Worktree] = []
        var recordIndex = 0

        // 一条记录的可变累加器
        var path: String?
        var head = ""
        var branch: String?
        var locked = false
        var prunable = false
        var bare = false

        func flush() {
            defer {
                path = nil; head = ""; branch = nil
                locked = false; prunable = false; bare = false
            }
            guard let path else { return }
            let idx = recordIndex
            recordIndex += 1
            // 裸仓库条目没有工作目录，不在列表里展示
            guard !bare else { return }
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            trees.append(Worktree(
                path: path,
                branch: branch,
                head: String(head.prefix(7)),
                isMain: idx == 0,
                isCurrent: resolved == myRoot,
                isLocked: locked,
                isPrunable: prunable
            ))
        }

        for raw in result.stdout.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("worktree ") {
                flush()  // 上一条记录可能未遇空行（输出末尾）
                path = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("HEAD ") {
                head = String(line.dropFirst("HEAD ".count))
            } else if line.hasPrefix("branch ") {
                let ref = String(line.dropFirst("branch ".count))
                branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
            } else if line == "detached" {
                branch = nil
            } else if line == "bare" {
                bare = true
            } else if line == "locked" || line.hasPrefix("locked ") {
                locked = true
            } else if line == "prunable" || line.hasPrefix("prunable ") {
                prunable = true
            }
        }
        flush()  // 输出末尾无空行时补最后一条
        return trees
    }

    /// 新建工作树。`createBranch` 为 true 时同时新建分支（基于当前 HEAD），
    /// 否则检出一个已有分支（该分支不能已被其他工作树占用）。
    public func addWorktree(path: String, branch: String, createBranch: Bool) async throws {
        var args = ["worktree", "add"]
        if createBranch {
            args += ["-b", branch, path]
        } else {
            args += [path, branch]
        }
        try await git.run(args)
    }

    /// 移除一个工作树（不能移除主工作树）。`force` 用于有未提交更改或已锁定的情况。
    public func removeWorktree(path: String, force: Bool = false) async throws {
        var args = ["worktree", "remove"]
        if force { args.append("--force") }
        args.append(path)
        try await git.run(args)
    }

    // MARK: - 标签（tag）

    /// 所有标签，按创建时间倒序。区分附注标签(annotated)与轻量标签(lightweight)。
    public func tags() async throws -> [Tag] {
        // 字段：名 / 对象类型 / 对象短hash / 解引用提交短hash(仅 annotated) / 标题
        let format = ["%(refname:short)", "%(objecttype)", "%(objectname:short)",
                      "%(*objectname:short)", "%(contents:subject)"].joined(separator: "%09")
        let result = try await git.run(
            ["for-each-ref", "refs/tags", "--sort=-creatordate", "--format=\(format)"],
            allowedExitCodes: [0, 128]
        )
        guard result.exitCode == 0 else { return [] }
        return result.stdout.split(separator: "\n", omittingEmptySubsequences: true).compactMap { raw in
            let f = raw.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 5, !f[0].isEmpty else { return nil }
            let isAnnotated = f[1] == "tag"
            // 附注标签的目标是解引用后的提交(f[3])，轻量标签直接指向提交(f[2])
            let target = isAnnotated ? f[3] : f[2]
            return Tag(name: f[0], target: target, isAnnotated: isAnnotated, subject: f[4])
        }
    }

    /// 新建标签。`message` 非空时创建附注标签(-a -m)，否则轻量标签。`ref` 默认 HEAD。
    public func createTag(name: String, message: String?, ref: String = "HEAD") async throws {
        var args = ["tag"]
        if let message, !message.isEmpty {
            args += ["-a", name, "-m", message, ref]
        } else {
            args += [name, ref]
        }
        try await git.run(args)
    }

    /// 删除本地标签。
    public func deleteTag(_ name: String) async throws {
        try await git.run(["tag", "-d", name])
    }

    /// 推送单个标签到 origin。
    public func pushTag(_ name: String) async throws {
        try await git.run(["push", "origin", name])
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

    /// 提交历史（含父指针，供泳道图布局）。
    /// `path` 非空时为单文件历史（--follow），人工串成单线。
    public func history(limit: Int = 300, path: String? = nil) async throws -> [GraphCommit] {
        let format = "%H%x09%h%x09%P%x09%an%x09%at%x09%D%x09%s"
        let args: [String]
        if let path {
            args = ["log", "--follow", "-n", "\(limit)", "--format=\(format)", "--", path]
        } else {
            args = ["log", "--all", "--date-order", "-n", "\(limit)", "--format=\(format)"]
        }
        let result = try await git.run(args, allowedExitCodes: [0, 128])
        guard result.exitCode == 0 else { return [] }

        var commits: [GraphCommit] = []
        for rawLine in result.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = rawLine
                .split(separator: "\t", maxSplits: 6, omittingEmptySubsequences: false)
                .map(String.init)
            guard fields.count >= 7 else { continue }
            let refs = fields[5]
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            commits.append(GraphCommit(
                hash: fields[0],
                shortHash: fields[1],
                parents: fields[2].split(separator: " ").map(String.init),
                author: fields[3],
                subject: fields[6],
                date: Date(timeIntervalSince1970: Double(fields[4]) ?? 0),
                refs: refs
            ))
        }

        // 文件历史：截断的父指针会断图，人工串成单线
        if path != nil {
            commits = commits.enumerated().map { index, commit in
                GraphCommit(
                    hash: commit.hash,
                    shortHash: commit.shortHash,
                    parents: index + 1 < commits.count ? [commits[index + 1].hash] : [],
                    author: commit.author,
                    subject: commit.subject,
                    date: commit.date,
                    refs: commit.refs
                )
            }
        }
        return commits
    }

    public struct CommitFileChange: Identifiable, Hashable, Sendable {
        public let kind: ChangeKind
        public let path: String
        public let oldPath: String?
        public var id: String { path }
    }

    /// 某个提交改动的文件列表。
    public func filesChanged(in hash: String) async throws -> [CommitFileChange] {
        // -m --first-parent:合并提交默认不输出 diff,取相对第一个 parent 的变化;普通提交无影响
        let result = try await git.run(["show", "--name-status", "--format=", "-m", "--first-parent", hash])
        return Self.parseNameStatus(result.stdout)
    }

    /// 两个引用之间改动的文件列表。
    public func filesChanged(from base: String, to target: String) async throws -> [CommitFileChange] {
        let result = try await git.run(["diff", "--name-status", base, target])
        return Self.parseNameStatus(result.stdout)
    }

    /// 某个提交里单个文件的 diff。
    public func diff(in hash: String, path: String) async throws -> FileDiff? {
        let result = try await git.run(["show", "--format=", "-m", "--first-parent", hash, "--", path])
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
        public let hash: String
        public let author: String
        public let email: String
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
        var email = ""
        var summary = ""
        var date: Date?
        for entry in lines.dropFirst() {
            if entry.hasPrefix("author ") {
                author = String(entry.dropFirst("author ".count))
            } else if entry.hasPrefix("author-mail ") {
                // 形如 <a@b.com>，去掉尖括号
                email = String(entry.dropFirst("author-mail ".count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            } else if entry.hasPrefix("author-time ") {
                date = Double(entry.dropFirst("author-time ".count)).map { Date(timeIntervalSince1970: $0) }
            } else if entry.hasPrefix("summary ") {
                summary = String(entry.dropFirst("summary ".count))
            }
        }
        return BlameInfo(
            hash: hash,
            author: author,
            email: email,
            summary: summary,
            date: date,
            isUncommitted: hash.allSatisfy { $0 == "0" }
        )
    }

    // MARK: - 提交详情（blame 悬浮卡）

    public struct CommitDetail: Sendable, Hashable {
        public let hash: String
        public let shortHash: String
        public let author: String
        public let email: String
        public let date: Date
        public let subject: String
        public let body: String        // 完整多行消息正文（不含 subject）
        public let filesChanged: Int
    }

    /// 单个提交的详情：作者/邮箱/时间/标题/完整正文 + 改动文件数。
    /// 用 1F 分隔字段、1E 结束格式段，正文可含换行而不破坏解析；其后是 --name-status 文件列表。
    public func commitDetail(hash: String) async throws -> CommitDetail? {
        let sep = "\u{1f}", end = "\u{1e}"
        let format = ["%H", "%h", "%an", "%ae", "%at", "%s", "%b"].joined(separator: sep) + end
        // --name-only：diff 区只列文件名（不是完整 patch），消息后紧跟文件清单
        let result = try await git.run(
            ["show", "--name-only", "--format=\(format)", hash],
            allowedExitCodes: [0, 128]
        )
        guard result.exitCode == 0 else { return nil }

        let parts = result.stdout.components(separatedBy: end)
        let fields = parts[0].components(separatedBy: sep)
        guard fields.count >= 7 else { return nil }
        let fileBlock = parts.count > 1 ? parts[1] : ""
        let fileCount = fileBlock
            .split(separator: "\n", omittingEmptySubsequences: true)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .count

        return CommitDetail(
            hash: fields[0],
            shortHash: fields[1],
            author: fields[2],
            email: fields[3],
            date: Date(timeIntervalSince1970: Double(fields[4]) ?? 0),
            subject: fields[5],
            body: fields[6].trimmingCharacters(in: .whitespacesAndNewlines),
            filesChanged: fileCount
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

    /// 搜索结果块里的一行：行号、文本、是否为命中行（命中行高亮，其余是上下文）。
    public struct GrepLine: Hashable, Sendable {
        public let number: Int
        public let text: String
        public let isMatch: Bool
    }

    /// 一段搜索结果块：同一文件中相邻（含已合并）的命中，连同其前后若干行上下文。
    /// 多个命中挨得近时（上下文窗口相接/重叠）会并入同一块，避免重复展示中间的上下文。
    public struct GrepHit: Identifiable, Hashable, Sendable {
        public let path: String
        public let lines: [GrepLine]
        /// 块内首个命中行（打开文件时定位到这里，也用作稳定 id）。
        public var line: Int { lines.first(where: { $0.isMatch })?.number ?? lines.first?.number ?? 1 }
        /// 块内命中行数（用于统计「N 处匹配」）。
        public var matchCount: Int { lines.reduce(0) { $0 + ($1.isMatch ? 1 : 0) } }
        public var id: String { "\(path):\(line)" }
    }

    /// 全仓库内容搜索（git grep，含未跟踪文件，忽略二进制）。
    /// exact=true：区分大小写的字面量匹配（`-F`），与全仓库替换的语义一致；
    /// exact=false：不区分大小写的正则（默认，搜索更宽松）。
    /// 命中行会带上 `context` 行前后文；同一文件里挨得近的命中合并成一块。
    public func grep(_ query: String, exact: Bool = false, limit: Int = 400, context: Int = 2) async throws -> [GrepHit] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        var args = ["grep", "-n", "-I", "--untracked", "--max-count=50"]
        if exact { args.append("-F") } else { args.append("--ignore-case") }
        args += ["-e", trimmed, "--", "."]
        let result = try await git.run(args, allowedExitCodes: [0, 1])  // 1 = 无匹配
        guard result.exitCode == 0 else { return [] }

        // 先解析出命中位置（path:line），保持 git grep 的文件出现顺序。
        var fileOrder: [String] = []
        var matchesByFile: [String: [(line: Int, text: String)]] = [:]
        for raw in result.stdout.split(separator: "\n").prefix(limit) {
            let line = String(raw)
            guard let firstColon = line.firstIndex(of: ":"),
                  let secondColon = line[line.index(after: firstColon)...].firstIndex(of: ":")
            else { continue }
            let path = String(line[..<firstColon])
            guard let number = Int(line[line.index(after: firstColon)..<secondColon]) else { continue }
            // 命中行只存有界前缀：minified/压缩文件一行可达数 MB，整行存进结果模型会撑爆内存
            // （UI 本就只显示前 240 字符）。截到 500 足够展示与高亮。
            var text = String(line[line.index(after: secondColon)...])
            if text.count > 500 { text = String(text.prefix(500)) }
            if matchesByFile[path] == nil { fileOrder.append(path) }
            matchesByFile[path, default: []].append((number, text))
        }

        var hits: [GrepHit] = []
        let ctx = max(0, context)
        for path in fileOrder {
            let matches = matchesByFile[path] ?? []
            guard !matches.isEmpty else { continue }
            let matchLines = Set(matches.map(\.line))
            // 命中行 → 文本，读盘失败时作为兜底（无上下文，仅命中行）。
            let matchText = Dictionary(matches.map { ($0.line, $0.text) }, uniquingKeysWith: { a, _ in a })

            // 读盘取整行上下文；失败（二进制/已删）则退化为只展示命中行。
            let fileLines: [String]?
            if let content = try? String(contentsOf: fileURL(for: path), encoding: .utf8) {
                fileLines = content.components(separatedBy: "\n")
            } else {
                fileLines = nil
            }

            // 把每个命中扩成 [line-ctx, line+ctx] 的窗口；相接/重叠的窗口合并成一块。
            let sorted = matchLines.sorted()
            var ranges: [(lo: Int, hi: Int)] = []
            for m in sorted {
                let lo = max(1, m - ctx)
                let hi = m + ctx
                if var last = ranges.last, lo <= last.hi + 1 {
                    last.hi = max(last.hi, hi)
                    ranges[ranges.count - 1] = last
                } else {
                    ranges.append((lo, hi))
                }
            }

            for range in ranges {
                var blockLines: [GrepLine] = []
                if let fileLines {
                    let hi = min(range.hi, fileLines.count)
                    guard range.lo <= hi else { continue }
                    for n in range.lo...hi {
                        var text = fileLines[n - 1]
                        if text.count > 500 { text = String(text.prefix(500)) }
                        blockLines.append(GrepLine(number: n, text: text, isMatch: matchLines.contains(n)))
                    }
                } else {
                    // 兜底：只列命中行本身。
                    for n in sorted where n >= range.lo && n <= range.hi {
                        blockLines.append(GrepLine(number: n, text: matchText[n] ?? "", isMatch: true))
                    }
                }
                guard !blockLines.isEmpty else { continue }
                hits.append(GrepHit(path: path, lines: blockLines))
            }
        }
        return hits
    }

    public struct ReplaceResult: Sendable {
        public let filesChanged: Int
        public let occurrences: Int
    }

    /// 全仓库字面量替换（区分大小写，非正则）：先用 `git grep -l` 列出含匹配的文件，
    /// 再逐个读盘做精确字符串替换写回。只动确有匹配的文件，写回后由调用方刷新状态走 git 复核。
    /// query 与替换搜索保持一致（trim 后作为针），replacement 原样使用（可为空=删除）。
    public func replaceAll(_ query: String, with replacement: String, limit: Int = 5000) async throws -> ReplaceResult {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty, needle != replacement else { return ReplaceResult(filesChanged: 0, occurrences: 0) }

        // -l 只列文件名，区分大小写字面量匹配，含未跟踪、跳过二进制
        let listResult = try await git.run(
            ["grep", "-l", "-I", "--untracked", "-F", "-e", needle, "--", "."],
            allowedExitCodes: [0, 1]
        )
        guard listResult.exitCode == 0 else { return ReplaceResult(filesChanged: 0, occurrences: 0) }

        var filesChanged = 0
        var occurrences = 0
        for raw in listResult.stdout.split(separator: "\n").prefix(limit) {
            let path = String(raw)
            guard !path.isEmpty else { continue }
            let url = fileURL(for: path)
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let parts = content.components(separatedBy: needle)
            let count = parts.count - 1
            guard count > 0 else { continue }
            let updated = parts.joined(separator: replacement)
            do {
                try updated.write(to: url, atomically: true, encoding: .utf8)
                filesChanged += 1
                occurrences += count
            } catch {
                continue  // 单个文件写失败不影响其余
            }
        }
        return ReplaceResult(filesChanged: filesChanged, occurrences: occurrences)
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

    /// 被 .gitignore 忽略的条目，供文件树以低透明度展示。
    /// `--directory` 让整个被忽略的目录折叠成一条（以 `/` 结尾），
    /// 否则 `.build/` 之类会展开出成千上万个文件。
    public func listIgnored() async throws -> [String] {
        let result = try await git.run(["ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z"])
        let paths = result.stdoutData
            .split(separator: 0, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
        return Array(Set(paths)).sorted()
    }
}
