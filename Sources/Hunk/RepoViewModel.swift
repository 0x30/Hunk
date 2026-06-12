import SwiftUI
import AppKit
import HunkCore

enum ChangeArea: Hashable { case staged, unstaged, conflicted }

enum SidebarTab: String, CaseIterable, Identifiable {
    case changes, files, branches
    var id: String { rawValue }
}

enum SidebarSelection: Hashable {
    case change(path: String, area: ChangeArea)
    case file(path: String)
}

@MainActor
final class RepoViewModel: ObservableObject {

    // MARK: 仓库状态

    @Published var repoRoot: URL?
    @Published var changes: [FileChange] = []
    @Published var branches: [Branch] = []
    @Published var stashes: [Stash] = []
    @Published var currentBranch = ""
    @Published var sync = SyncStatus(upstream: nil, ahead: 0, behind: 0)
    @Published var headSummary: String?
    @Published var workspaceFiles: [String] = []
    @Published var workspaceTree: [FileNode] = []

    // MARK: 界面状态

    @Published var sidebarTab: SidebarTab = .changes
    @Published var selection: SidebarSelection? {
        didSet {
            guard selection != oldValue else { return }
            editingChangedFile = false
            Task { await loadDetail() }
        }
    }

    // MARK: Diff 详情

    @Published var diff: FileDiff?
    @Published var diffArea: ChangeArea = .unstaged
    @Published var selectedLineIDs: Set<Int> = []

    // MARK: 编辑器

    @Published var editorText = ""
    @Published var editorPath: String?
    @Published var editorDirty = false
    @Published var editingChangedFile = false  // 在更改详情里切到了编辑模式
    @Published var conflictBlocks: [ConflictBlock] = []
    @Published var conflictIndex = 0
    @Published var scrollToLine: Int?

    // MARK: 操作状态

    @Published var commitMessage = ""
    @Published var errorMessage: String?
    @Published var isSyncing = false
    @Published var pendingDiscard: FileChange?

    private(set) var repo: Repository?
    private let defaults = UserDefaults.standard

    init() {
        if let last = defaults.string(forKey: "lastRepo"),
           FileManager.default.fileExists(atPath: last) {
            Task { await open(URL(fileURLWithPath: last)) }
        }
    }

    // MARK: - 派生

    var stagedChanges: [FileChange] { changes.filter { $0.staged != nil } }
    var unstagedChanges: [FileChange] { changes.filter { $0.unstaged != nil && $0.unstaged != .conflicted } }
    var conflictedChanges: [FileChange] { changes.filter(\.isConflicted) }

    var recentRepos: [String] {
        (defaults.stringArray(forKey: "recentRepos") ?? [])
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    var selectedChangePath: String? {
        if case .change(let path, _) = selection { return path }
        return nil
    }

    // MARK: - 打开仓库

    func openRepoPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = tr("选择一个 git 仓库目录", "Choose a git repository folder")
        panel.prompt = tr("打开", "Open")
        if panel.runModal() == .OK, let url = panel.url {
            Task { await open(url) }
        }
    }

    func open(_ url: URL) async {
        do {
            let repository = try await Repository.discover(at: url)
            repo = repository
            repoRoot = repository.root
            selection = nil
            diff = nil
            editorPath = nil
            defaults.set(repository.root.path, forKey: "lastRepo")
            var recents = defaults.stringArray(forKey: "recentRepos") ?? []
            recents.removeAll { $0 == repository.root.path }
            recents.insert(repository.root.path, at: 0)
            defaults.set(Array(recents.prefix(8)), forKey: "recentRepos")
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func closeRepo() {
        repo = nil
        repoRoot = nil
        changes = []
        selection = nil
        diff = nil
        editorPath = nil
        defaults.removeObject(forKey: "lastRepo")
    }

    // MARK: - 刷新

    func refresh() async {
        guard let repo else { return }
        do {
            async let status = repo.status()
            async let branches = repo.branches()
            async let stashes = repo.stashes()
            async let branch = repo.currentBranch()
            async let sync = repo.syncStatus()
            async let head = repo.headSummary()
            async let files = repo.listFiles()

            self.changes = try await status
            self.branches = try await branches
            self.stashes = try await stashes
            self.currentBranch = try await branch
            self.sync = try await sync
            self.headSummary = try await head
            self.workspaceFiles = try await files
            self.workspaceTree = FileTreeBuilder.build(paths: self.workspaceFiles)

            // 选中的更改已不存在时清掉详情
            if case .change(let path, let area) = selection {
                let stillThere = changes.contains { change in
                    change.path == path && area == self.area(of: change, preferred: area)
                }
                if !stillThere {
                    selection = nil
                    diff = nil
                } else {
                    await loadDetail()
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func area(of change: FileChange, preferred: ChangeArea) -> ChangeArea {
        if change.isConflicted { return .conflicted }
        switch preferred {
        case .staged: return change.staged != nil ? .staged : .unstaged
        case .unstaged, .conflicted: return change.unstaged != nil ? .unstaged : .staged
        }
    }

    /// 包一层错误处理 + 刷新的通用操作入口。
    func perform(_ action: @escaping () async throws -> Void) {
        Task {
            do {
                try await action()
            } catch {
                errorMessage = error.localizedDescription
            }
            await refresh()
        }
    }

    // MARK: - 详情加载

    func loadDetail() async {
        guard let repo else { return }
        selectedLineIDs = []
        switch selection {
        case nil:
            diff = nil
        case .change(let path, let area):
            diffArea = area
            if area == .conflicted {
                openEditor(path: path)
                return
            }
            if editingChangedFile {
                openEditor(path: path)
            }
            do {
                let change = changes.first { $0.path == path }
                if area == .unstaged, change?.unstaged == .untracked {
                    diff = try await repo.untrackedDiff(for: path)
                } else {
                    diff = try await repo.diff(for: path, staged: area == .staged)
                }
            } catch {
                diff = nil
                errorMessage = error.localizedDescription
            }
        case .file(let path):
            diff = nil
            openEditor(path: path)
        }
    }

    // MARK: - 编辑器

    func openEditor(path: String) {
        guard let repo else { return }
        let url = repo.fileURL(for: path)
        if FileIcon.isImage(path) {
            editorPath = path
            editorText = ""
            editorDirty = false
            conflictBlocks = []
            return
        }
        do {
            editorText = try String(contentsOf: url, encoding: .utf8)
        } catch {
            editorText = (try? String(contentsOf: url, encoding: .isoLatin1)) ?? ""
        }
        editorPath = path
        editorDirty = false
        reparseConflicts()
    }

    func saveEditor() async {
        guard let repo, let path = editorPath, editorDirty else { return }
        do {
            try editorText.write(to: repo.fileURL(for: path), atomically: true, encoding: .utf8)
            editorDirty = false
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reparseConflicts() {
        conflictBlocks = ConflictParser.parse(editorText)
        if conflictIndex >= conflictBlocks.count { conflictIndex = max(0, conflictBlocks.count - 1) }
    }

    // MARK: - 冲突解决

    func resolveCurrentConflict(_ resolution: ConflictBlock.Resolution) {
        guard conflictBlocks.indices.contains(conflictIndex) else { return }
        let block = conflictBlocks[conflictIndex]
        editorText = ConflictParser.resolve(editorText, block: block, with: resolution)
        editorDirty = true
        reparseConflicts()
        if conflictBlocks.indices.contains(conflictIndex) {
            scrollToLine = conflictBlocks[conflictIndex].startLine
        }
    }

    func gotoConflict(offset: Int) {
        guard !conflictBlocks.isEmpty else { return }
        conflictIndex = (conflictIndex + offset + conflictBlocks.count) % conflictBlocks.count
        scrollToLine = conflictBlocks[conflictIndex].startLine
    }

    /// 保存并 git add，标记冲突已解决。
    func markConflictResolved() {
        guard let path = editorPath else { return }
        perform { [self] in
            if editorDirty, let repo = self.repo {
                try editorText.write(to: repo.fileURL(for: path), atomically: true, encoding: .utf8)
                await MainActor.run { editorDirty = false }
            }
            try await self.repo?.stage(paths: [path])
        }
    }

    // MARK: - 暂存操作

    func stageFile(_ path: String) {
        perform { try await self.repo?.stage(paths: [path]) }
    }

    func unstageFile(_ path: String) {
        perform { try await self.repo?.unstage(paths: [path]) }
    }

    func stageAll() {
        perform { try await self.repo?.stageAll() }
    }

    func unstageAll() {
        perform { try await self.repo?.unstageAll() }
    }

    func requestDiscard(_ change: FileChange) {
        pendingDiscard = change
    }

    func confirmDiscard() {
        guard let change = pendingDiscard else { return }
        pendingDiscard = nil
        perform { [self] in
            guard let repo = self.repo else { return }
            if change.unstaged == .untracked {
                try repo.deleteUntracked(path: change.path)
            } else {
                try await repo.discardWorktree(paths: [change.path])
            }
        }
    }

    // MARK: - 行级暂存

    func toggleLine(_ id: Int) {
        if selectedLineIDs.contains(id) {
            selectedLineIDs.remove(id)
        } else {
            selectedLineIDs.insert(id)
        }
    }

    func stageSelectedLines() {
        applySelectedLines(reverse: false, lineIDs: selectedLineIDs)
    }

    func unstageSelectedLines() {
        applySelectedLines(reverse: true, lineIDs: selectedLineIDs)
    }

    func stageHunk(_ hunk: DiffHunk) {
        applySelectedLines(reverse: diffArea == .staged, lineIDs: Set(hunk.changedLineIDs))
    }

    private func applySelectedLines(reverse: Bool, lineIDs: Set<Int>) {
        guard let diff, !lineIDs.isEmpty else { return }
        let patch = reverse
            ? PatchBuilder.unstagePatch(diff: diff, selectedLineIDs: lineIDs)
            : PatchBuilder.stagePatch(diff: diff, selectedLineIDs: lineIDs)
        guard let patch else { return }
        perform { try await self.repo?.applyPatch(patch, reverse: reverse) }
    }

    // MARK: - 提交

    func commit() {
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !stagedChanges.isEmpty else { return }
        perform { [self] in
            try await self.repo?.commit(message: message)
            await MainActor.run { commitMessage = "" }
        }
    }

    // MARK: - 贮藏

    func stashAll() {
        perform { try await self.repo?.stashPushAll(message: nil) }
    }

    func stashFile(_ path: String) {
        perform { try await self.repo?.stashPush(paths: [path]) }
    }

    func applyStash(_ stash: Stash, pop: Bool) {
        perform { try await self.repo?.stashApply(index: stash.index, pop: pop) }
    }

    func dropStash(_ stash: Stash) {
        perform { try await self.repo?.stashDrop(index: stash.index) }
    }

    // MARK: - 分支

    func checkout(_ branch: Branch) {
        guard !branch.isCurrent else { return }
        perform { try await self.repo?.checkout(branch: branch.name) }
    }

    func createBranch(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        perform { try await self.repo?.createBranch(trimmed) }
    }

    // MARK: - 远端同步

    func fetch() { syncAction { try await $0.fetch() } }
    func pull() { syncAction { try await $0.pull() } }
    func push() { syncAction { try await $0.push() } }

    private func syncAction(_ action: @escaping (Repository) async throws -> Void) {
        guard let repo, !isSyncing else { return }
        isSyncing = true
        Task {
            do {
                try await action(repo)
            } catch {
                errorMessage = error.localizedDescription
            }
            isSyncing = false
            await refresh()
        }
    }

    // MARK: - 杂项

    func revealInFinder(_ path: String) {
        guard let repo else { return }
        NSWorkspace.shared.activateFileViewerSelecting([repo.fileURL(for: path)])
    }

    func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }
}
