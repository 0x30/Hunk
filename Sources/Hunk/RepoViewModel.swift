import SwiftUI
import AppKit
import HunkCore

enum ChangeArea: Hashable { case staged, unstaged, conflicted }

enum SidebarTab: String, CaseIterable, Identifiable {
    case files, changes
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

    @Published var sidebarTab: SidebarTab = .files
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
    /// diff 新侧（工作区 / 暂存区）的全文行，供「展开未更改区域」使用。
    @Published var diffNewSideLines: [String]?
    @Published var pendingDiscardHunk: DiffHunk?

    // MARK: 编辑器（多标签）

    struct EditorBuffer {
        var text: String
        var dirty: Bool
    }

    @Published var editorText = ""
    @Published var editorPath: String?
    @Published var editorDirty = false
    @Published var openTabs: [String] = []
    @Published var pendingCloseTab: String?
    @Published var editingChangedFile = false  // 在更改详情里切到了编辑模式
    @Published var conflictBlocks: [ConflictBlock] = []
    @Published var conflictIndex = 0
    @Published var scrollToLine: Int?
    @Published var blameText: String?
    private var buffers: [String: EditorBuffer] = [:]
    private var blameTask: Task<Void, Never>?
    private var blameCache: [String: String] = [:]

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
        openTabs = []
        buffers = [:]
        blameCache = [:]
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
            diffNewSideLines = nil
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
                await loadDiffContext(path: path, area: area)
            } catch {
                diff = nil
                diffNewSideLines = nil
                errorMessage = error.localizedDescription
            }
        case .file(let path):
            diff = nil
            diffNewSideLines = nil
            openEditor(path: path)
        }
    }

    /// 加载 diff 新侧全文，供「展开未更改区域」。
    private func loadDiffContext(path: String, area: ChangeArea) async {
        guard let repo, let diff, !diff.isBinary, !diff.isDeleted, !diff.hunks.isEmpty else {
            diffNewSideLines = nil
            return
        }
        var content: String?
        if area == .staged {
            content = try? await repo.indexContent(of: path)
        } else {
            content = try? String(contentsOf: repo.fileURL(for: path), encoding: .utf8)
        }
        guard var lines = content?.components(separatedBy: "\n") else {
            diffNewSideLines = nil
            return
        }
        if lines.last == "" { lines.removeLast() }
        diffNewSideLines = lines
    }

    // MARK: - 编辑器（多标签）

    func openEditor(path: String) {
        guard let repo else { return }
        stashActiveBuffer()

        if !openTabs.contains(path) {
            openTabs.append(path)
        }

        if FileIcon.isImage(path) {
            editorPath = path
            editorText = ""
            editorDirty = false
            conflictBlocks = []
            return
        }

        if let buffer = buffers[path] {
            editorText = buffer.text
            editorDirty = buffer.dirty
        } else {
            let url = repo.fileURL(for: path)
            do {
                editorText = try String(contentsOf: url, encoding: .utf8)
            } catch {
                editorText = (try? String(contentsOf: url, encoding: .isoLatin1)) ?? ""
            }
            editorDirty = false
        }
        editorPath = path
        blameText = nil
        reparseConflicts()
    }

    /// 把当前激活文件的内容存回缓冲区（切换标签前调用）。
    private func stashActiveBuffer() {
        guard let path = editorPath, !FileIcon.isImage(path) else { return }
        buffers[path] = EditorBuffer(text: editorText, dirty: editorDirty)
    }

    func selectTab(_ path: String) {
        guard path != editorPath else { return }
        selection = .file(path: path)
    }

    func closeTab(_ path: String) {
        if path == editorPath { stashActiveBuffer() }
        if buffers[path]?.dirty == true {
            pendingCloseTab = path
        } else {
            performCloseTab(path)
        }
    }

    func performCloseTab(_ path: String) {
        guard let index = openTabs.firstIndex(of: path) else { return }
        openTabs.remove(at: index)
        buffers[path] = nil
        if editorPath == path {
            if openTabs.isEmpty {
                editorPath = nil
                editorText = ""
                editorDirty = false
                selection = nil
            } else {
                let neighbor = openTabs[min(index, openTabs.count - 1)]
                selection = .file(path: neighbor)
                openEditor(path: neighbor)
            }
        }
    }

    func saveAndCloseTab(_ path: String) {
        Task {
            if let buffer = buffers[path], buffer.dirty, let repo {
                do {
                    try buffer.text.write(to: repo.fileURL(for: path), atomically: true, encoding: .utf8)
                    buffers[path]?.dirty = false
                    if editorPath == path { editorDirty = false }
                } catch {
                    errorMessage = error.localizedDescription
                    return
                }
            }
            performCloseTab(path)
            await refresh()
        }
    }

    /// 关闭已保存的标签（保留有未保存修改的）。
    func closeSavedTabs() {
        stashActiveBuffer()
        for path in openTabs where buffers[path]?.dirty != true {
            performCloseTab(path)
        }
    }

    func closeOtherTabs(keeping path: String) {
        stashActiveBuffer()
        for other in openTabs where other != path && buffers[other]?.dirty != true {
            performCloseTab(other)
        }
        if editorPath != path {
            selection = .file(path: path)
        }
    }

    func closeTabsToTheRight(of path: String) {
        stashActiveBuffer()
        guard let index = openTabs.firstIndex(of: path) else { return }
        for other in openTabs.suffix(from: index + 1) where buffers[other]?.dirty != true {
            performCloseTab(other)
        }
    }

    func closeActiveTab() {
        if let path = editorPath {
            closeTab(path)
        } else {
            NSApp.keyWindow?.performClose(nil)
        }
    }

    func activateNeighborTab(offset: Int) {
        guard let path = editorPath,
              let index = openTabs.firstIndex(of: path),
              openTabs.count > 1
        else { return }
        let next = (index + offset + openTabs.count) % openTabs.count
        selectTab(openTabs[next])
    }

    func isTabDirty(_ path: String) -> Bool {
        if path == editorPath { return editorDirty }
        return buffers[path]?.dirty ?? false
    }

    func saveEditor() async {
        guard let repo, let path = editorPath, editorDirty else { return }
        do {
            try editorText.write(to: repo.fileURL(for: path), atomically: true, encoding: .utf8)
            editorDirty = false
            buffers[path] = EditorBuffer(text: editorText, dirty: false)
            blameCache = blameCache.filter { !$0.key.hasPrefix("\(path)#") }
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - 行内 blame

    func requestBlame(line: Int) {
        blameTask?.cancel()
        guard let repo, let path = editorPath else { return }
        if editorDirty {
            blameText = tr("未保存的更改", "Unsaved changes")
            return
        }
        let key = "\(path)#\(line)"
        if let cached = blameCache[key] {
            blameText = cached
            return
        }
        blameText = nil
        blameTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let info = try? await repo.blame(path: path, line: line)
            guard !Task.isCancelled, let self else { return }
            let text: String
            if let info {
                if info.isUncommitted {
                    text = tr("未提交的更改", "Uncommitted changes")
                } else {
                    var parts = [info.author]
                    if let date = info.date {
                        let formatter = RelativeDateTimeFormatter()
                        formatter.unitsStyle = .abbreviated
                        parts.append(formatter.localizedString(for: date, relativeTo: Date()))
                    }
                    if !info.summary.isEmpty { parts.append(info.summary) }
                    text = parts.joined(separator: " · ")
                }
            } else {
                text = ""
            }
            await MainActor.run {
                self.blameCache[key] = text
                self.blameText = text.isEmpty ? nil : text
            }
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

    /// hunk 级撤销：把该块的工作区更改恢复成暂存区内容（危险操作，需确认）。
    func requestDiscardHunk(_ hunk: DiffHunk) {
        pendingDiscardHunk = hunk
    }

    func confirmDiscardHunk() {
        guard let diff, let hunk = pendingDiscardHunk else { return }
        pendingDiscardHunk = nil
        guard let patch = PatchBuilder.stagePatch(diff: diff, selectedLineIDs: Set(hunk.changedLineIDs)) else { return }
        perform { try await self.repo?.applyPatch(patch, reverse: true, cached: false) }
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
