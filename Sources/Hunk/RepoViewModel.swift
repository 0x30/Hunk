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
    /// 当前根是否 git 仓库（false = 非 git 目录 / 单文件 → 隐藏 git 功能）
    @Published var isGitRepo = false
    /// 单文件模式（无文件树；tab 右键只保留复制路径 / Finder）
    @Published var isStandaloneFile = false
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
    @Published var sidebarVisible = true

    /// 文件树展开的目录路径（提到视图模型，切换侧边栏标签后保活，不再丢失/重新全展开）
    @Published var fileTreeExpanded: Set<String> = []
    /// 文件树是否已做过首层展开（避免每次回到文件标签又全展开）
    @Published var fileTreeDidInitialExpand = false
    /// 源代码管理两个模块的折叠状态（点击头部切换）
    @Published var changesPanelCollapsed = false
    @Published var historyPanelCollapsed = false

    /// Xcode 式导航器切换：点未选中的标签则切换并展开，点已选中的则收起侧边栏。
    func toggleSidebarTab(_ tab: SidebarTab) {
        if sidebarVisible && sidebarTab == tab {
            sidebarVisible = false
        } else {
            sidebarTab = tab
            sidebarVisible = true
        }
    }
    /// 当前的详情加载任务，切换选择时取消上一个，避免快速切换堆积 loadDetail
    private var loadDetailTask: Task<Void, Never>?
    @Published var selection: SidebarSelection? {
        didSet {
            guard selection != oldValue else { return }
            editingChangedFile = false
            if selection != nil { historyDetail = nil }
            loadDetailTask?.cancel()
            loadDetailTask = Task { await loadDetail() }
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
    /// 当前编辑文件是二进制（含 NUL）→ 显示 hex 查看器而非纯文本编辑器
    @Published var editorIsBinary = false
    /// 底部状态栏：光标行列（1 基）+ 选中行数
    @Published var editorCursorLine = 1
    @Published var editorCursorColumn = 1
    @Published var editorSelectedLines = 0
    /// 手动指定的高亮语言扩展名；nil = 按文件名推断。
    /// 新建未保存文件没有扩展名时，可借此提前选语言高亮（如 Markdown）。
    @Published var editorLanguageOverride: String?
    @Published var openTabs: [String] = []
    @Published var pendingCloseTab: String?
    @Published var editingChangedFile = false  // 在更改详情里切到了编辑模式
    @Published var conflictBlocks: [ConflictBlock] = []
    @Published var conflictIndex = 0
    @Published var scrollToLine: Int?
    @Published var blameText: String?
    /// blame 视图：非空且等于当前文件时，编辑区显示整文件 blame 块
    @Published var blameViewPath: String?
    @Published var fileBlame: [Repository.BlameLine] = []
    private var buffers: [String: EditorBuffer] = [:]
    private var blameTask: Task<Void, Never>?
    private var blameCache: [String: String] = [:]

    // MARK: 操作状态

    @Published var commitMessage = ""
    @Published var errorMessage: String?
    /// 一般性提示（如命令行工具安装结果）
    @Published var notice: String?
    @Published var isSyncing = false
    @Published var pendingDiscard: FileChange?
    @Published var pendingFolderDrop: URL?
    @Published var showQuickOpen = false
    @Published var showBranchPanel = false
    @Published var showGlobalSearch = false

    // MARK: 内嵌终端（⌘J）

    @Published var showTerminal = false
    /// 终端会话列表：跨显示/隐藏保活，挂在视图模型上随窗口走
    @Published var terminals: [TerminalSession] = []
    @Published var activeTerminalID: UUID?
    /// 终端是否持有键盘焦点（⌘N/⌘W 据此切换为终端语义）
    @Published var terminalFocused = false
    /// 面板高度：拖拽调整后持久化，开关面板/切换文件都不会变
    @Published var terminalHeight: CGFloat {
        didSet { defaults.set(Double(terminalHeight), forKey: "terminalHeight") }
    }

    var activeTerminal: TerminalSession? {
        terminals.first { $0.id == activeTerminalID } ?? terminals.first
    }

    func toggleTerminal() {
        showTerminal.toggle()
        if showTerminal {
            if terminals.isEmpty { newTerminal() }
        } else {
            terminalFocused = false
            // 关闭面板后把键盘还给主内容
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }

    /// 新建一个 shell 会话并切为当前（终端聚焦时 ⌘N）。
    func newTerminal() {
        let session = TerminalSession()
        session.onExit = { [weak self] session in
            Task { @MainActor in self?.removeTerminal(session) }
        }
        session.onFocusChange = { [weak self] focused in
            Task { @MainActor in self?.terminalFocused = focused }
        }
        terminals.append(session)
        activeTerminalID = session.id
        showTerminal = true
    }

    /// 结束当前会话（终端聚焦时 ⌘W）；最后一个会话关闭后收起面板。
    func closeActiveTerminal() {
        guard let session = activeTerminal else { return }
        closeTerminal(session)
    }

    /// 结束指定会话（标签上的 × 按钮）。
    func closeTerminal(_ session: TerminalSession) {
        session.terminate()
        removeTerminal(session)
    }

    /// 清空当前终端（⌘K）。
    func clearActiveTerminal() {
        activeTerminal?.clear()
    }

    /// 在终端标签间循环切换（终端聚焦时 ⌘⇧[ / ⌘⇧]）。
    func cycleTerminal(offset: Int) {
        guard terminals.count > 1,
              let current = activeTerminal,
              let index = terminals.firstIndex(where: { $0.id == current.id })
        else { return }
        activeTerminalID = terminals[(index + offset + terminals.count) % terminals.count].id
    }

    /// 右键菜单：批量结束一组会话，并修正当前选中/空面板状态。
    func closeTerminals(_ targets: [TerminalSession]) {
        guard !targets.isEmpty else { return }
        let killIDs = Set(targets.map(\.id))
        for session in targets { session.terminate() }
        terminals.removeAll { killIDs.contains($0.id) }
        if let active = activeTerminalID, killIDs.contains(active) {
            activeTerminalID = terminals.last?.id
        }
        if terminals.isEmpty {
            showTerminal = false
            terminalFocused = false
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }

    func closeTerminalsToLeft(of session: TerminalSession) {
        guard let index = terminals.firstIndex(where: { $0.id == session.id }) else { return }
        closeTerminals(Array(terminals[..<index]))
    }

    func closeTerminalsToRight(of session: TerminalSession) {
        guard let index = terminals.firstIndex(where: { $0.id == session.id }) else { return }
        closeTerminals(Array(terminals[(index + 1)...]))
    }

    func closeOtherTerminals(_ session: TerminalSession) {
        closeTerminals(terminals.filter { $0.id != session.id })
    }

    func closeAllTerminals() {
        closeTerminals(terminals)
    }

    private func removeTerminal(_ session: TerminalSession) {
        guard let index = terminals.firstIndex(where: { $0.id == session.id }) else { return }
        terminals.remove(at: index)
        if activeTerminalID == session.id {
            activeTerminalID = terminals.indices.contains(index) ? terminals[index].id : terminals.last?.id
        }
        if terminals.isEmpty {
            showTerminal = false
            terminalFocused = false
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }

    /// 打开全局搜索结果：跳到对应文件并滚动选中该行。
    func openSearchResult(_ hit: Repository.GrepHit) {
        showGlobalSearch = false
        revealInFiles(hit.path)
        Task {
            // 等编辑器装载新文件后再滚动定位
            try? await Task.sleep(nanoseconds: 250_000_000)
            scrollToLine = hit.line - 1
        }
    }
    /// 请求文件列表定位某个文件（展开祖先目录并选中）。
    @Published var revealFileRequest: String?

    // MARK: 新建文件

    struct NewFilePrompt: Identifiable {
        /// 相对仓库根的目录，"" 表示根目录
        let directory: String
        /// 非空时表示在给「未命名」缓冲命名落盘
        var untitledPath: String? = nil
        /// 保存后是否关闭标签（关闭未保存的未命名 tab 时走这里）
        var closeAfterSave = false
        var id: String { directory + (untitledPath ?? "") }
    }

    @Published var newFilePrompt: NewFilePrompt?
    @Published var newFileName = ""

    static let untitledPrefix = "untitled://"
    private var untitledCounter = 0

    func isUntitled(_ path: String) -> Bool {
        path.hasPrefix(Self.untitledPrefix)
    }

    /// 标签显示名（未命名缓冲显示「未命名 N」）。
    func displayName(for path: String) -> String {
        guard isUntitled(path) else {
            return (path as NSString).lastPathComponent
        }
        let number = path.dropFirst(Self.untitledPrefix.count)
        return number == "1" ? tr("未命名", "Untitled") : tr("未命名 \(number)", "Untitled \(number)")
    }

    /// ⌘N：立即新建一个未命名标签（仅内存），保存/关闭时才询问文件名。
    func newUntitledFile() {
        guard repoRoot != nil else { return }
        stashActiveBuffer()
        untitledCounter += 1
        let path = Self.untitledPrefix + "\(untitledCounter)"
        buffers[path] = EditorBuffer(text: "", dirty: false)
        selection = .file(path: path)
    }

    func promptNewFile(in directory: String? = nil) {
        guard repoRoot != nil else { return }
        newFileName = ""
        newFilePrompt = NewFilePrompt(directory: directory ?? "")
    }

    /// 给未命名缓冲命名（保存 / 保存并关闭时调用）。
    func promptSaveUntitled(_ path: String, closeAfterSave: Bool) {
        newFileName = ""
        newFilePrompt = NewFilePrompt(directory: "", untitledPath: path, closeAfterSave: closeAfterSave)
    }

    func confirmNewFile() {
        guard let prompt = newFilePrompt, let repo else { return }
        newFilePrompt = nil
        let name = newFileName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let relativePath = prompt.directory.isEmpty ? name : prompt.directory + "/" + name
        let url = repo.fileURL(for: relativePath)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = tr("「\(relativePath)」已存在", "“\(relativePath)” already exists")
            return
        }

        // 未命名缓冲：写入其内容；普通新建：写入空文件
        let content: String
        if let untitled = prompt.untitledPath {
            content = untitled == editorPath ? editorText : (buffers[untitled]?.text ?? "")
        } else {
            content = ""
        }

        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        if let untitled = prompt.untitledPath {
            // 未命名 tab 原位替换为真实路径
            buffers[relativePath] = EditorBuffer(text: content, dirty: false)
            buffers[untitled] = nil
            if let index = openTabs.firstIndex(of: untitled) {
                openTabs[index] = relativePath
            }
            if editorPath == untitled {
                editorPath = relativePath
                editorDirty = false
            }
            if case .file(let selected) = selection, selected == untitled {
                selection = .file(path: relativePath)
            }
            if prompt.closeAfterSave {
                performCloseTab(relativePath)
            }
        }

        Task {
            await refresh()
            if prompt.untitledPath == nil || !prompt.closeAfterSave {
                revealInFiles(relativePath)
            }
        }
    }

    // MARK: 历史

    enum HistoryDetail: Equatable {
        case commit(Repository.Commit)
        case compare(base: String, target: String)

        var title: String {
            switch self {
            case .commit(let commit): return "\(commit.shortHash) \(commit.subject)"
            case .compare(let base, let target): return "\(base) ↔ \(target)"
            }
        }
    }

    @Published var history: [GraphRow] = []
    @Published var historyMaxColumns = 1
    @Published var historyFilterPath: String?
    /// 历史分页：当前加载条数上限（触底自动 +500）、是否还有更多、是否正在加载
    @Published var historyLimit = 300
    @Published var hasMoreHistory = true
    @Published var isLoadingMoreHistory = false
    @Published var historyDetail: HistoryDetail?
    @Published var historyFiles: [Repository.CommitFileChange] = []
    @Published var historyDiff: FileDiff?
    @Published var historyDiffPath: String?

    private(set) var repo: Repository?
    private let defaults = UserDefaults.standard

    // MARK: 多窗口路由

    /// 所有存活窗口的视图模型（弱引用），命令行打开请求据此分发
    static let instances = NSHashTable<RepoViewModel>.weakObjects()
    /// 所在窗口（WindowAccessor 注入），用于聚焦
    weak var window: NSWindow?
    /// 请求在新窗口打开仓库：由 ContentView 调用 openWindow 兑现
    @Published var openWindowRequest: String?

    /// `restoreLast` 为 false 时不恢复上次仓库（⌘⇧N 的空白欢迎窗口）。
    init(initialPath: String? = nil, restoreLast: Bool = true) {
        let savedHeight = UserDefaults.standard.double(forKey: "terminalHeight")
        terminalHeight = savedHeight > 0 ? CGFloat(savedHeight) : 240
        RepoViewModel.instances.add(self)
        if let initialPath, FileManager.default.fileExists(atPath: initialPath) {
            Task { await open(URL(fileURLWithPath: initialPath)) }
        } else if restoreLast,
                  let last = defaults.string(forKey: "lastRepo"),
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
        Diagnostics.log("open repo \(url.path)")
        // 非 git 目录也能打开：discover 失败就以 url 本身作根（无 git 功能），不报错
        let repository = try? await Repository.discover(at: url)
        let root = repository?.root ?? url
        repo = repository
        isGitRepo = repository != nil
        isStandaloneFile = false
        repoRoot = root
        selection = nil
        diff = nil
        editorPath = nil
        // 换根重置文件树展开状态，让新根重新做首层展开
        fileTreeExpanded = []
        fileTreeDidInitialExpand = false
        defaults.set(root.path, forKey: "lastRepo")
        var recents = defaults.stringArray(forKey: "recentRepos") ?? []
        recents.removeAll { $0 == root.path }
        recents.insert(root.path, at: 0)
        defaults.set(Array(recents.prefix(8)), forKey: "recentRepos")
        await refresh()
    }

    func closeRepo() {
        repo = nil
        isGitRepo = false
        isStandaloneFile = false
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

    /// refresh 防重入：窗口频繁激活/连续触发时合并，避免并发刷新风暴
    /// （每个 refresh 会起 7 个 git 子进程 + 重建文件树/graph，并发会拖垮主线程渲染）
    private var isRefreshing = false

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        // 非 git 目录：每次刷新尝试重新 discover（用户可能刚 git init），仍不是就只刷文件树
        if repo == nil, !isStandaloneFile, let root = repoRoot,
           let rediscovered = try? await Repository.discover(at: root) {
            repo = rediscovered
            isGitRepo = true
        }
        guard let repo else {
            await refreshNonGit()
            return
        }
        Diagnostics.log("refresh 开始（变更 \(changes.count)）")
        defer { Diagnostics.log("refresh 结束") }
        do {
            async let status = repo.status()
            async let branches = repo.branches()
            async let stashes = repo.stashes()
            async let branch = repo.currentBranch()
            async let sync = repo.syncStatus()
            async let head = repo.headSummary()
            async let files = repo.listFiles()

            // 只在值真正变化时赋值：避免每次激活刷新都触发整树重绘
            // （工具栏项重建会吞掉紧随其后的第一次点击）
            assignIfChanged(try await status, to: \.changes)
            assignIfChanged(try await branches, to: \.branches)
            assignIfChanged(try await stashes, to: \.stashes)
            assignIfChanged(try await branch, to: \.currentBranch)
            assignIfChanged(try await sync, to: \.sync)
            assignIfChanged(try await head, to: \.headSummary)
            let newFiles = try await files
            if newFiles != self.workspaceFiles {
                self.workspaceFiles = newFiles
                self.workspaceTree = FileTreeBuilder.build(paths: newFiles)
                Diagnostics.log("工作区树重建 文件=\(newFiles.count) 顶层节点=\(self.workspaceTree.count)")
            }
            // 保持已加载的分页量（用户触底加载到多少，刷新后维持多少）
            let commits = (try? await repo.history(limit: self.historyLimit, path: self.historyFilterPath)) ?? []
            hasMoreHistory = commits.count >= self.historyLimit
            let graph = GraphBuilder.rows(from: commits)
            assignIfChanged(graph.rows, to: \.history)
            assignIfChanged(graph.maxColumns, to: \.historyMaxColumns)

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

    /// 非 git 根的刷新：清空所有 git 状态，文件树改用文件系统列。
    private func refreshNonGit() async {
        changes = []
        branches = []
        stashes = []
        history = []
        currentBranch = ""
        sync = SyncStatus(upstream: nil, ahead: 0, behind: 0)
        headSummary = nil
        guard let root = repoRoot, !isStandaloneFile else {
            workspaceFiles = []        // 单文件模式：无文件树
            workspaceTree = []
            return
        }
        let files = await Task.detached(priority: .userInitiated) {
            RepoViewModel.listFilesOnDisk(root: root)
        }.value
        if files != workspaceFiles {
            workspaceFiles = files
            workspaceTree = FileTreeBuilder.build(paths: files)
            Diagnostics.log("非 git 文件树 文件=\(files.count) 顶层=\(workspaceTree.count)")
        }
    }

    /// 文件系统列文件（非 git 目录用）：排除 .git / 常见大目录 / 隐藏文件，限量防 OOM。
    nonisolated static func listFilesOnDisk(root: URL, limit: Int = 5000) -> [String] {
        let skip: Set<String> = [
            ".git", "node_modules", ".build", "build", "target", "dist", ".next",
            "DerivedData", ".venv", "venv", "__pycache__", ".gradle", "Pods", ".idea", ".cache",
        ]
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let prefixLen = root.path.count + 1
        var result: [String] = []
        for case let url as URL in enumerator {
            if result.count >= limit { break }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                if skip.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            if url.path.count > prefixLen {
                result.append(String(url.path.dropFirst(prefixLen)))
            }
        }
        return result
    }

    private func assignIfChanged<T: Equatable>(_ value: T, to keyPath: ReferenceWritableKeyPath<RepoViewModel, T>) {
        if self[keyPath: keyPath] != value {
            self[keyPath: keyPath] = value
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

    /// 已为哪个路径因「diff 为空」自动刷新过，防止合法空 diff（chmod/重命名）反复刷新
    private var emptyDiffRefreshedPath: String?

    func loadDetail() async {
        guard let repo else { return }
        // 快速切换时上一个任务已被取消：直接跳过，别再跑一遍重活
        //（取消只在 await 边界生效，所以下面每个 await 之后还要再查一次）
        if Task.isCancelled { return }
        Diagnostics.log("loadDetail \(selection.map { "\($0)" } ?? "nil")")
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
                let loaded: FileDiff?
                if area == .unstaged, change?.unstaged == .untracked {
                    loaded = try await repo.untrackedDiff(for: path)
                } else {
                    loaded = try await repo.diff(for: path, staged: area == .staged)
                }
                // 选择已切走（任务被取消）：丢弃这份已是过期的 diff，别覆盖新选择
                if Task.isCancelled { return }
                diff = loaded
                if let d = loaded {
                    // 诊断：用 reduce 累加，不实体化大数组（避免诊断自身加压内存）
                    let lineCount = d.hunks.reduce(0) { $0 + $1.lines.count }
                    let maxLineLen = d.hunks.reduce(0) { acc, h in
                        max(acc, h.lines.reduce(0) { max($0, $1.text.count) })
                    }
                    Diagnostics.log("diff \(path) hunks=\(d.hunks.count) 行=\(lineCount) 最长行=\(maxLineLen) bin=\(d.isBinary)")
                }
                // 列表标记为有变化、diff 实际却为空（非二进制/删除/新建）→
                // 多半是文件已被外部命令提交/暂存/丢弃，自动刷新一次让状态对齐。
                // 每个路径最多自动刷新一次，避免 chmod/重命名等合法空 diff 反复刷新。
                let looksEmpty: Bool = {
                    guard let d = diff else { return true }
                    return d.hunks.isEmpty && !d.isBinary && !d.isDeleted && !d.isNew
                }()
                if change != nil, looksEmpty, emptyDiffRefreshedPath != path {
                    emptyDiffRefreshedPath = path
                    await refresh()
                    return
                }
                emptyDiffRefreshedPath = nil
                await loadDiffContext(path: path, area: area)
            } catch {
                diff = nil
                diffNewSideLines = nil
                errorMessage = error.localizedDescription
            }
        case .file(let path):
            if Task.isCancelled { return }
            diff = nil
            diffNewSideLines = nil
            // 大文件读盘移出主线程：快速切换时主线程同步 IO 会卡。
            // 预读进缓冲，openEditor 命中缓冲分支即可，不在主线程再读一次。
            // 二进制文件跳过——会走 hex 查看器，预读全文进 buffer 纯属浪费内存。
            let url = repo.fileURL(for: path)
            if buffers[path] == nil, !isUntitled(path), !FileIcon.isImage(path),
               !BinaryDetector.isBinary(url: url) {
                let text = await Task.detached(priority: .userInitiated) {
                    (try? String(contentsOf: url, encoding: .utf8))
                        ?? (try? String(contentsOf: url, encoding: .isoLatin1))
                }.value
                if Task.isCancelled { return }
                buffers[path] = EditorBuffer(text: text ?? "", dirty: false)
            }
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
        Diagnostics.log("loadDiffContext \(path) 新侧行数=\(lines.count) 字节≈\(content?.utf8.count ?? 0)")
    }

    // MARK: - 编辑器（多标签）

    func openEditor(path: String) {
        if path != editorPath {
            editorLanguageOverride = nil  // 换文件才重置手动选的语言
            editorCursorLine = 1; editorCursorColumn = 1; editorSelectedLines = 0
        }
        stashActiveBuffer()

        if !openTabs.contains(path) {
            openTabs.append(path)
            pruneTabsIfNeeded(active: path)
        }

        if FileIcon.isImage(path) {
            editorPath = path
            editorText = ""
            editorDirty = false
            conflictBlocks = []
            editorIsBinary = false
            return
        }

        // 二进制文件（含 NUL）→ 走 hex 查看器，不把字节读成乱码文本
        if !isUntitled(path), BinaryDetector.isBinary(url: editorFileURL(path)) {
            editorPath = path
            editorText = ""
            editorDirty = false
            editorIsBinary = true
            conflictBlocks = []
            blameText = nil
            return
        }
        editorIsBinary = false

        if let buffer = buffers[path] {
            editorText = buffer.text
            editorDirty = buffer.dirty
        } else if isUntitled(path) {
            editorText = ""
            editorDirty = false
        } else {
            let url = editorFileURL(path)
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

    /// 编辑器读盘用的 URL：绝对路径（单文件模式 / 仓库外文件）直接用，相对路径走仓库根。
    func editorFileURL(_ path: String) -> URL {
        path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : (repo?.fileURL(for: path) ?? URL(fileURLWithPath: path))
    }

    /// 打开单个文件（不要求 git 仓库）：以文件所在目录为根、repo=nil，纯查看/编辑。
    func openStandaloneFile(_ url: URL) {
        Diagnostics.log("单文件模式打开 \(url.lastPathComponent)（无 git 仓库）")
        repo = nil
        isGitRepo = false
        isStandaloneFile = true
        repoRoot = url.deletingLastPathComponent()  // 目录作根（无 git），让主界面显示编辑器
        sidebarVisible = false                       // 单文件无文件树，收起侧边栏只看文件
        workspaceFiles = []
        workspaceTree = []
        changes = []
        diff = nil
        selection = .file(path: url.path)
    }

    /// 状态栏：更新光标行列与选中行数。
    func updateEditorCursor(line: Int, column: Int, selectedLines: Int) {
        editorCursorLine = line
        editorCursorColumn = column
        editorSelectedLines = selectedLines
    }

    /// 状态栏显示的当前高亮语言名（手动覆盖 ?? 文件名推断 ?? 纯文本）。
    var editorLanguageName: String {
        if let ext = editorLanguageOverride, let def = Lexer.language(forFileExtension: ext) {
            return def.name
        }
        if let path = editorPath,
           let def = Lexer.language(forFileName: (path as NSString).lastPathComponent) {
            return def.name
        }
        return tr("纯文本", "Plain Text")
    }

    /// 标签上限：扫树/快速切换会给每个划过的文件开标签并常驻其全文，
    /// 超过上限就回收最早的、未修改、非当前的标签，把内存增长卡死在一个上界。
    private func pruneTabsIfNeeded(active: String) {
        let cap = 30
        guard openTabs.count > cap else { return }
        var overflow = openTabs.count - cap
        // filter 保持插入顺序：从最早的可回收标签开始删
        let candidates = openTabs.filter {
            $0 != active && !isUntitled($0) && buffers[$0]?.dirty != true
        }
        for path in candidates where overflow > 0 {
            if let index = openTabs.firstIndex(of: path) {
                openTabs.remove(at: index)
                buffers[path] = nil
                overflow -= 1
            }
        }
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
        // 未命名缓冲：先命名落盘，再关闭
        if isUntitled(path) {
            promptSaveUntitled(path, closeAfterSave: true)
            return
        }
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
        // 未命名缓冲：⌘S 时询问文件名
        if let path = editorPath, isUntitled(path) {
            promptSaveUntitled(path, closeAfterSave: false)
            return
        }
        guard let path = editorPath, editorDirty else { return }
        do {
            try editorText.write(to: editorFileURL(path), atomically: true, encoding: .utf8)
            editorDirty = false
            buffers[path] = EditorBuffer(text: editorText, dirty: false)
            blameCache = blameCache.filter { !$0.key.hasPrefix("\(path)#") }
            if repo != nil { await refresh() }  // 单文件模式无 git，无需刷新状态
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 切换当前文件的 blame 视图。
    func toggleBlameView() {
        guard let path = editorPath, !isUntitled(path) else { return }
        if blameViewPath == path {
            blameViewPath = nil
            return
        }
        blameViewPath = path
        fileBlame = []
        Task {
            guard let repo else { return }
            fileBlame = (try? await repo.blameFile(path: path)) ?? []
        }
    }

    // MARK: - 行内 blame

    func requestBlame(line: Int) {
        blameTask?.cancel()
        guard let repo, let path = editorPath, !isUntitled(path) else { return }
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
                        parts.append(relativeTime(date))
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

    /// 把分支与当前 HEAD 做对比（历史详情的比较视图）。
    func compareBranch(_ branch: Branch) {
        openHistoryDetail(.compare(base: branch.name, target: "HEAD"))
    }

    /// 把指定分支合并进当前分支；冲突文件会出现在「合并更改」区。
    func mergeBranch(_ branch: Branch) {
        perform { try await self.repo?.merge(branch: branch.name) }
    }

    // MARK: 删除分支

    /// 待确认删除的分支列表（非 nil 时弹确认框）
    @Published var branchesToDelete: [String]?

    /// 删除单个分支（弹确认）。
    func promptDeleteBranch(_ branch: Branch) {
        branchesToDelete = [branch.name]
    }

    /// 查找已合并的本地分支并弹出确认。
    func promptCleanupMergedBranches() {
        guard let repo else { return }
        Task {
            do {
                let merged = try await repo.mergedBranches()
                if merged.isEmpty {
                    notice = tr("没有可删除的分支：本地不存在已合并进当前分支的其他分支。",
                                "Nothing to delete: no local branches are fully merged into the current branch.")
                } else {
                    branchesToDelete = merged
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// 执行删除（逐个删，失败的跳过并汇总）。
    func confirmDeleteBranches() {
        guard let repo, let branches = branchesToDelete else { return }
        branchesToDelete = nil
        Task {
            var deleted: [String] = []
            var failed: [String] = []
            for name in branches {
                do {
                    try await repo.deleteBranch(name)
                    deleted.append(name)
                } catch {
                    failed.append(name)
                }
            }
            await refresh()
            var lines: [String] = []
            if !deleted.isEmpty {
                lines.append(tr("已删除 \(deleted.count) 个分支：\(deleted.joined(separator: "、"))",
                                "Deleted \(deleted.count) branch(es): \(deleted.joined(separator: ", "))"))
            }
            if !failed.isEmpty {
                lines.append(tr("删除失败：\(failed.joined(separator: "、"))",
                                "Failed: \(failed.joined(separator: ", "))"))
            }
            notice = lines.joined(separator: "\n")
        }
    }

    // MARK: - 远端同步

    /// 正在执行的同步动作（"fetch" / "pull" / "push"），驱动对应图标的 loading
    @Published var syncingAction: String?

    func fetch() { syncAction("fetch") { try await $0.fetch() } }
    func pull() { syncAction("pull") { try await $0.pull() } }
    func push() { syncAction("push") { try await $0.push() } }

    private func syncAction(_ name: String, _ action: @escaping (Repository) async throws -> Void) {
        guard let repo, !isSyncing else { return }
        isSyncing = true
        syncingAction = name
        Task {
            do {
                try await action(repo)
            } catch {
                errorMessage = error.localizedDescription
            }
            isSyncing = false
            syncingAction = nil
            await refresh()
        }
    }

    // MARK: - 历史

    func setHistoryFilter(_ path: String?) {
        historyFilterPath = path
        historyLimit = 300       // 换过滤条件，分页从头开始
        hasMoreHistory = true
        Task {
            guard let repo else { return }
            let commits = (try? await repo.history(limit: historyLimit, path: path)) ?? []
            hasMoreHistory = commits.count >= historyLimit
            let graph = GraphBuilder.rows(from: commits)
            history = graph.rows
            historyMaxColumns = graph.maxColumns
        }
    }

    /// 历史列表触底：再多加载一批（泳道线要连续，所以整段重拉重算，不能简单 append）。
    func loadMoreHistory() {
        guard hasMoreHistory, !isLoadingMoreHistory, let repo else { return }
        isLoadingMoreHistory = true
        let newLimit = historyLimit + 500
        let path = historyFilterPath
        Task {
            let commits = (try? await repo.history(limit: newLimit, path: path)) ?? []
            historyLimit = newLimit
            hasMoreHistory = commits.count >= newLimit
            let graph = GraphBuilder.rows(from: commits)
            history = graph.rows
            historyMaxColumns = graph.maxColumns
            isLoadingMoreHistory = false
        }
    }

    /// 在历史面板查看某个文件的全部提交（侧边栏收起时自动展开）。
    func showFileHistory(_ path: String) {
        sidebarVisible = true
        sidebarTab = .changes
        historyPanelCollapsed = false
        setHistoryFilter(path)
    }

    func openHistoryDetail(_ detail: HistoryDetail) {
        historyDetail = detail
        historyFiles = []
        historyDiff = nil
        historyDiffPath = nil
        Task {
            guard let repo else { return }
            do {
                switch detail {
                case .commit(let commit):
                    historyFiles = try await repo.filesChanged(in: commit.hash)
                case .compare(let base, let target):
                    historyFiles = try await repo.filesChanged(from: base, to: target)
                }
                Diagnostics.log("历史详情文件数=\(historyFiles.count)")
                // 历史详情里若只改了一个文件，直接展示它的 diff
                if let first = historyFiles.first, historyFiles.count == 1 {
                    selectHistoryFile(first)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func closeHistoryDetail() {
        historyDetail = nil
        historyDiff = nil
        historyDiffPath = nil
    }

    func selectHistoryFile(_ file: Repository.CommitFileChange) {
        guard let repo, let detail = historyDetail else { return }
        historyDiffPath = file.path
        Task {
            do {
                switch detail {
                case .commit(let commit):
                    historyDiff = try await repo.diff(in: commit.hash, path: file.path)
                case .compare(let base, let target):
                    historyDiff = try await repo.diff(from: base, to: target, path: file.path)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// 在文件列表中定位并打开（侧边栏收起时自动展开）。
    func revealInFiles(_ path: String) {
        sidebarVisible = true
        sidebarTab = .files
        selection = .file(path: path)
        revealFileRequest = path
    }

    // MARK: - 命令行打开

    /// `hunk [path]`：目录直接打开仓库；文件则打开其所在仓库并定位该文件。
    func openFromCLI(_ path: String) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return }
        // 解析符号链接，与 git 返回的仓库根对齐
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        Task {
            if isDirectory.boolValue {
                await open(url)
            } else if (try? await Repository.discover(at: url.deletingLastPathComponent())) != nil {
                // 文件在 git 仓库内：打开仓库并定位到该文件
                await open(url.deletingLastPathComponent())
                if let root = repoRoot, url.path.hasPrefix(root.path + "/") {
                    revealInFiles(String(url.path.dropFirst(root.path.count + 1)))
                }
            } else {
                // 文件不在任何 git 仓库：单文件查看模式，不报错
                openStandaloneFile(url)
            }
        }
    }

    // MARK: - 拖拽打开

    /// 拖入文件：仓库内的直接打开；拖入文件夹：弹出「当前/新窗口」选择。
    func handleDrop(url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }
        if isDirectory.boolValue {
            // 欢迎页（空窗口）拖入文件夹：直接打开，不再询问在哪个窗口
            if repoRoot == nil {
                Task { await open(url) }
            } else {
                pendingFolderDrop = url
            }
            return
        }
        if let root = repoRoot, url.path.hasPrefix(root.path + "/") {
            let relative = String(url.path.dropFirst(root.path.count + 1))
            sidebarTab = .files
            selection = .file(path: relative)
        } else {
            errorMessage = tr(
                "该文件不在当前仓库内。拖入它所在的文件夹可以打开对应仓库。",
                "This file is outside the current repository. Drop its folder to open that repository."
            )
        }
    }

    // MARK: - 杂项

    func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([editorFileURL(path)])
    }

    func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(editorFileURL(path).path, forType: .string)
    }
}
