import SwiftUI
import AppKit
import Combine
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

/// 非文件类的「视图标签」：工作区 diff / 提交 / 比较 / 搜索。各自独立，可同时开多个
/// （文件标签仍在 openTabs[String] 里，这些另存一份列表 openViewTabs）。
enum ViewTab: Hashable, Identifiable {
    case diff(String, ChangeArea)
    case commit(Repository.Commit)
    case compare(String, String)
    case search
    case rebase  // 交互式变基编排（单例：一个仓库同时只整理一处）

    var id: String {
        switch self {
        case .diff(let p, let a): return "diff:\(a):\(p)"
        case .commit(let c): return "commit:\(c.hash)"
        case .compare(let b, let t): return "compare:\(b)..\(t)"
        case .search: return "search"
        case .rebase: return "rebase"
        }
    }
}

/// 右侧详情区当前激活的标签：文件编辑 或 某个视图标签。
enum ActiveDetail: Hashable {
    case file(String)
    case view(ViewTab)
}

@MainActor
final class RepoViewModel: ObservableObject {

    // MARK: 仓库状态

    @Published var repoRoot: URL?
    /// 当前根是否 git 仓库（false = 非 git 目录 / 单文件 → 隐藏 git 功能）
    @Published var isGitRepo = false
    /// 单文件模式（无文件树；tab 右键只保留复制路径 / Finder）
    @Published var isStandaloneFile = false
    /// 工作区根：打开的是「装了多个 git 项目的文件夹」时，记录这个父目录。
    /// 非空且 discoveredRepos 非空 ⇒ 侧边栏出现仓库切换器。单仓库/普通目录时为 nil。
    @Published var workspaceRoot: URL?
    /// 工作区里扫描到的子仓库（标准化绝对路径，已排序）。
    @Published var discoveredRepos: [URL] = []
    /// 当前激活的工作区子仓库（nil = 正在看「整个文件夹」总览）。
    @Published var activeWorkspaceRepo: URL?

    /// 是否处于多仓库工作区（决定是否显示切换器）。
    var isWorkspace: Bool { workspaceRoot != nil && !discoveredRepos.isEmpty }
    @Published var changes: [FileChange] = []
    @Published var branches: [Branch] = []
    @Published var stashes: [Stash] = []
    @Published var worktrees: [Worktree] = []
    @Published var tags: [Tag] = []
    /// 当前分支(HEAD)可达的提交 hash 集合，供历史右键区分提交在不在当前分支
    @Published var headReachable: Set<String> = []
    @Published var currentBranch = ""
    @Published var sync = SyncStatus(upstream: nil, ahead: 0, behind: 0)
    @Published var headSummary: String?
    @Published var workspaceFiles: [String] = []
    @Published var workspaceTree: [FileNode] = []
    /// 被忽略条目缓存（仅用于变更检测，避免每次刷新重建整树）
    private var workspaceIgnored: [String] = []
    /// 已展开并加载过内容的「被忽略目录」(相对路径)，避免重复枚举
    private var loadedIgnoredDirs: Set<String> = []
    /// 懒加载得到的忽略目录内部条目(目录以 `/` 结尾)，与 workspaceIgnored 合并建树
    private var ignoredDirContents: [String] = []

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
            // 选择驱动「激活的详情标签」：文件→文件标签；变更→diff 标签(并记下其路径)。
            // 不再清 historyDetail / 搜索——它们是各自独立的标签，切到文件/diff 时仍保留。
            switch selection {
            case .file(let p): activeDetail = .file(p)
            case .change(let p, let a):
                let t = ViewTab.diff(p, a)
                if !openViewTabs.contains(t) { openViewTabs.append(t) }
                activeDetail = .view(t)
            case nil: break
            }
            loadDetailTask?.cancel()
            loadDetailTask = Task { await loadDetail() }
        }
    }

    /// 当前激活的详情标签（统一标签系统的「选中」）。变更时同步搜索可见标志、记访问历史。
    @Published var activeDetail: ActiveDetail? {
        didSet {
            showGlobalSearch = (activeDetail == .view(.search))
            recordHistory(previous: oldValue)
        }
    }
    /// 非文件类标签（diff/提交/比较/搜索），可同时存在多个，各自独立。
    @Published var openViewTabs: [ViewTab] = []

    /// 标签访问历史（MRU，最近访问的「上一个」在末尾，不含当前标签）。
    /// 关闭当前标签时据此回到上一个看过的标签，而非空间上的相邻标签。
    private var detailHistory: [ActiveDetail] = []

    /// 某标签当前是否仍开着（用于过滤历史里已关闭的脏条目）。
    private func isOpen(_ detail: ActiveDetail) -> Bool {
        switch detail {
        case .file(let p): return openTabs.contains(p)
        case .view(let t): return openViewTabs.contains(t)
        }
    }

    /// 每次激活变更时调用：把「上一个」记进历史（仅当它仍开着，避免脏数据）。
    private func recordHistory(previous: ActiveDetail?) {
        guard previous != activeDetail else { return }
        if let cur = activeDetail { detailHistory.removeAll { $0 == cur } }  // 当前的不算「上一个」
        guard let prev = previous, isOpen(prev) else { return }
        detailHistory.removeAll { $0 == prev }  // 去重后挪到末尾(最近)
        detailHistory.append(prev)
        if detailHistory.count > 50 { detailHistory.removeFirst(detailHistory.count - 50) }
    }

    /// 弹出历史里最近一个仍开着的标签（跳过已关闭的）。
    private func popHistory() -> ActiveDetail? {
        while let last = detailHistory.popLast() {
            if isOpen(last) { return last }
        }
        return nil
    }

    /// 激活某标签（文件走编辑器、视图走对应内容加载）。
    private func activate(_ detail: ActiveDetail) {
        switch detail {
        case .file(let p): selectTab(p)
        case .view(let t): activateViewTab(t)
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
    /// 当前编辑文件的基线内容（HEAD 版本）；与编辑器内容做行级 diff 画改动标记。
    /// nil = 未跟踪/无仓库/尚未加载，编辑器据此把整文件视为新增或不画标记。
    @Published var editorBaseline: String?
    /// 当前编辑文件是二进制（含 NUL）→ 显示 hex 查看器而非纯文本编辑器
    @Published var editorIsBinary = false
    @Published var editorLoading = false   // 大文件异步读盘期间为 true
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
    /// 新建文件后请求编辑器抢键盘焦点（⌘N 后无需再点一下即可输入）；编辑器消费后清空。
    @Published var pendingEditorFocus = false
    @Published var blameText: String?
    /// 当前光标行所属提交的 hash（committed 行才有）；供行内注解悬浮卡取详情。
    @Published var blameHash: String?
    /// blame 视图：非空且等于当前文件时，编辑区显示整文件 blame 块
    @Published var blameViewPath: String?
    @Published var fileBlame: [Repository.BlameLine] = []
    private var buffers: [String: EditorBuffer] = [:]
    private var blameTask: Task<Void, Never>?
    private var blameCache: [String: (text: String, hash: String?)] = [:]
    /// 提交详情缓存（blame 悬浮卡），按 hash 去重，避免重复 git show。
    private var commitDetailCache: [String: Repository.CommitDetail] = [:]

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
    /// 搜索标签：searchTabOpen=标签存在；显示与否由 activeDetail==.search 决定（showGlobalSearch 同步它）。
    @Published var showGlobalSearch = false
    @Published var searchTabOpen = false
    /// 每次 ⌘⇧F/⌘⇧R 自增——搜索面板据此重新聚焦输入框（标签已存在时 onAppear 不再触发，
    /// 只靠它无法聚焦；用一个递增 nonce 保证每次都把焦点+全选给到搜索框）。
    @Published var searchFocusNonce = 0
    /// 全局搜索状态提到视图模型，标签开/关、失活/激活都不丢查询与结果。
    @Published var globalSearchQuery = ""
    @Published var globalSearchHits: [Repository.GrepHit] = []
    @Published var globalSearchExact = false
    /// 全局面板进入「替换」模式（⌘⇧R）：强制精确匹配、显示替换字段。
    @Published var globalSearchReplace = false

    // MARK: - 统一标签：激活 / 打开 / 关闭

    /// 关闭当前标签后，激活并加载一个仍存在的标签：优先回到「上一个看过的」(访问历史)，
    /// 其次当前文件、任意文件，再其次视图标签。
    private func activateFallback() {
        if let prev = popHistory() { activate(prev); return }
        if let p = editorPath, openTabs.contains(p) { selectTab(p); return }
        if let first = openTabs.first { selectTab(first); return }
        if let v = openViewTabs.last { activateViewTab(v); return }
        activeDetail = nil
        selection = nil
    }

    /// 点视图标签:重新激活（diff/提交 需要重载对应内容；搜索直接显示）。
    func activateViewTab(_ tab: ViewTab) {
        switch tab {
        case .diff(let p, let a):
            if selection != .change(path: p, area: a) {
                selection = .change(path: p, area: a)  // didSet → activeDetail=.view(.diff) + loadDetail
            } else {
                activeDetail = .view(tab)
            }
        case .commit(let c):
            openHistoryDetail(.commit(c))
        case .compare(let b, let t):
            openHistoryDetail(.compare(base: b, target: t))
        case .search:
            activeDetail = .view(.search)
        case .rebase:
            activeDetail = .view(.rebase)
        }
    }

    /// 关闭某视图标签。
    func closeViewTab(_ tab: ViewTab) {
        let wasActive = activeDetail == .view(tab)
        openViewTabs.removeAll { $0 == tab }
        if case .search = tab { searchTabOpen = false }
        if case .rebase = tab {
            rebaseSteps = []
            rebaseBase = nil
            rebaseDetailCommit = nil
            rebaseDetailFiles = []
            rebaseDetailDiff = nil
            rebaseDetailDiffPath = nil
        }
        if wasActive {
            // 关的是当前显示的标签:提交/比较内容作废,然后回退激活别的标签
            switch tab {
            case .commit, .compare: historyDetail = nil
            default: break
            }
            activateFallback()
        }
    }

    /// 打开（或聚焦）搜索标签：⌘⇧F 查找 / ⌘⇧R 替换。
    func openSearchTab(replace: Bool) {
        globalSearchReplace = replace
        searchTabOpen = true
        if !openViewTabs.contains(.search) { openViewTabs.append(.search) }
        activeDetail = .view(.search)
        searchFocusNonce &+= 1   // 即便标签已存在也重新聚焦输入框
    }
    func activateSearchTab() { activeDetail = .view(.search) }
    func closeSearchTab() { closeViewTab(.search) }

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

    /// 打开全局搜索结果：跳到对应文件并滚动选中该块的首个命中行。
    func openSearchResult(_ hit: Repository.GrepHit) {
        openSearchLocation(path: hit.path, line: hit.line)
    }

    /// 跳到指定文件的指定行（块内点具体某行时用，行号 1 起）。
    func openSearchLocation(path: String, line: Int) {
        // 打开文件标签(让搜索标签失活、保留);revealInFiles 会设 selection=.file → activeDetail=.file
        revealInFiles(path)
        Task {
            // 等编辑器装载新文件后再滚动定位
            try? await Task.sleep(nanoseconds: 250_000_000)
            scrollToLine = line - 1
        }
    }

    /// 全仓库字面量替换（⌘⇧R，区分大小写）：写回文件后刷新状态，改动进工作区交 git 复核。
    func replaceAllInRepo(query: String, replacement: String) async {
        guard let repo else { return }
        do {
            let result = try await repo.replaceAll(query, with: replacement)
            showGlobalSearch = false
            globalSearchReplace = false
            await refresh()
            if result.filesChanged == 0 {
                notice = tr("没有可替换的内容", "Nothing to replace")
            } else {
                notice = tr("已在 \(result.filesChanged) 个文件替换 \(result.occurrences) 处",
                            "Replaced \(result.occurrences) occurrence(s) in \(result.filesChanged) file(s)")
            }
        } catch {
            errorMessage = error.localizedDescription
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
        pendingEditorFocus = true   // 让编辑器一挂载就抢焦点,⌘N 后直接打字
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
    /// 关窗口前查未保存的代理；window.delegate 是 weak，这里强持有。
    private var closeGuard: WindowCloseGuard?
    /// 请求在新窗口打开仓库：由 ContentView 调用 openWindow 兑现
    @Published var openWindowRequest: String?

    /// `restoreLast` 为 false 时不恢复上次仓库（⌘⇧N 的空白欢迎窗口）。
    private var cancellables: Set<AnyCancellable> = []

    init(initialPath: String? = nil, restoreLast: Bool = true) {
        let savedHeight = UserDefaults.standard.double(forKey: "terminalHeight")
        terminalHeight = savedHeight > 0 ? CGFloat(savedHeight) : 240
        RepoViewModel.instances.add(self)
        // 隐藏名单设置变化时实时重建文件树(延一帧确保 @Published 值已落定)
        SettingsStore.shared.$hiddenFileNames
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.rebuildWorkspaceTree() }
            }
            .store(in: &cancellables)
        if let initialPath, FileManager.default.fileExists(atPath: initialPath) {
            Task { await open(URL(fileURLWithPath: initialPath)) }
        } else if restoreLast,
                  !CLIOpenRouter.hasChannelContent,
                  let last = defaults.string(forKey: "lastRepo"),
                  FileManager.default.fileExists(atPath: last) {
            // 命令行带了路径时不恢复上次仓库，交给路由处理，避免竞态盖掉 CLI 文件
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
        if repository == nil {
            // 不是仓库：先看是不是「装了多个 git 项目的文件夹」——扫子目录找 .git
            let subs = await Task.detached(priority: .userInitiated) {
                RepoViewModel.discoverRepos(in: url)
            }.value
            if !subs.isEmpty {
                Diagnostics.log("工作区模式：\(url.lastPathComponent) 含 \(subs.count) 个 git 仓库")
                workspaceRoot = url
                discoveredRepos = subs
                persistRecent(url)             // 记住父目录，重开仍进工作区
                // 默认激活第一个仓库（完整 git UI），切换器可换别的或看整个文件夹
                let first = try? await Repository.discover(at: subs[0])
                activeWorkspaceRepo = subs[0]
                await activateRoot(subs[0], repository: first)
                return
            }
        }
        // 单仓库 / 普通非 git 目录：清掉工作区状态
        workspaceRoot = nil
        discoveredRepos = []
        activeWorkspaceRepo = nil
        let root = repository?.root ?? url
        persistRecent(root)
        await activateRoot(root, repository: repository)
    }

    /// 工作区内切换激活仓库（保留切换器与 discoveredRepos）。
    func selectRepo(_ url: URL) async {
        guard activeWorkspaceRepo != url else { return }
        let repository = try? await Repository.discover(at: url)
        activeWorkspaceRepo = url
        await activateRoot(url, repository: repository)
    }

    /// 工作区：切到「整个文件夹」总览（无 git、平铺文件树）。
    func selectWorkspaceOverview() async {
        guard let ws = workspaceRoot, activeWorkspaceRepo != nil else { return }
        activeWorkspaceRepo = nil
        await activateRoot(ws, repository: nil)
    }

    /// 切到某个根并刷新。repository 非空=git 仓库，否则按非 git 目录处理。
    /// 不动 workspaceRoot/discoveredRepos/activeWorkspaceRepo——由调用方维护。
    private func activateRoot(_ root: URL, repository: Repository?) async {
        repo = repository
        isGitRepo = repository != nil
        isStandaloneFile = false
        repoRoot = repository?.root ?? root
        selection = nil
        diff = nil
        editorPath = nil
        // 换根：编辑器 tab/缓冲都是按旧根的相对路径，必须清掉避免错位
        openTabs = []
        buffers = [:]
        blameCache = [:]
        // 换根关掉搜索标签（结果是旧仓库的，作废）
        searchTabOpen = false
        showGlobalSearch = false
        globalSearchHits = []
        openViewTabs = []
        detailHistory = []
        activeDetail = nil
        // 换根重置文件树展开状态，让新根重新做首层展开
        fileTreeExpanded = []
        fileTreeDidInitialExpand = false
        loadedIgnoredDirs = []
        ignoredDirContents = []
        await refresh()
    }

    /// 写入「最近打开」与 lastRepo。
    private func persistRecent(_ url: URL) {
        defaults.set(url.path, forKey: "lastRepo")
        var recents = defaults.stringArray(forKey: "recentRepos") ?? []
        recents.removeAll { $0 == url.path }
        recents.insert(url.path, at: 0)
        defaults.set(Array(recents.prefix(8)), forKey: "recentRepos")
    }

    /// 总览模式下，某个文件树目录是否是扫描到的子仓库（用于树里加角标 + 右键「作为仓库打开」）。
    func discoveredRepoURL(forTreePath path: String) -> URL? {
        guard repo == nil, let ws = workspaceRoot else { return nil }  // 仅总览模式
        let abs = ws.appendingPathComponent(path).standardizedFileURL
        return discoveredRepos.first { $0.path == abs.path }
    }

    /// 扫描文件夹找出其中的 git 仓库（深度 ≤ maxDepth）。遇到 .git 即记为仓库根、不再下钻。
    /// 跳过 node_modules 等噪声目录。纯文件系统探测，放后台线程跑。
    nonisolated static func discoverRepos(in root: URL, maxDepth: Int = 2, limit: Int = 100) -> [URL] {
        let skip: Set<String> = [
            ".git", "node_modules", ".build", "build", "target", "dist", ".next",
            "DerivedData", ".venv", "venv", "__pycache__", ".gradle", "Pods", ".idea", ".cache",
        ]
        let fm = FileManager.default
        var found: [URL] = []

        func scan(_ dir: URL, depth: Int) {
            if found.count >= limit { return }
            // 含 .git（目录或文件，后者用于 worktree/submodule）即视为仓库根，不再下钻
            if fm.fileExists(atPath: dir.appendingPathComponent(".git").path) {
                found.append(dir.standardizedFileURL)
                return
            }
            guard depth < maxDepth else { return }
            guard let entries = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            ) else { return }
            for entry in entries {
                let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard isDir, !skip.contains(entry.lastPathComponent) else { continue }
                scan(entry, depth: depth + 1)
            }
        }

        // root 本身已确认不是仓库（调用前 discover 失败），从子目录开始扫
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir, !skip.contains(entry.lastPathComponent) else { continue }
            scan(entry, depth: 1)
        }
        return found.sorted { $0.path < $1.path }
    }

    func closeRepo() {
        repo = nil
        isGitRepo = false
        isStandaloneFile = false
        repoRoot = nil
        workspaceRoot = nil
        discoveredRepos = []
        activeWorkspaceRepo = nil
        changes = []
        selection = nil
        diff = nil
        editorPath = nil
        openTabs = []
        buffers = [:]
        blameCache = [:]
        searchTabOpen = false
        showGlobalSearch = false
        globalSearchHits = []
        openViewTabs = []
        detailHistory = []
        activeDetail = nil
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
            async let worktrees = repo.worktrees()
            async let tags = repo.tags()
            async let headReachable = repo.headReachableHashes()
            async let rebaseInProgress = repo.rebaseInProgress()
            async let branch = repo.currentBranch()
            async let sync = repo.syncStatus()
            async let head = repo.headSummary()
            async let files = repo.listFiles()
            async let ignoredFiles = repo.listIgnored()

            // 只在值真正变化时赋值：避免每次激活刷新都触发整树重绘
            // （工具栏项重建会吞掉紧随其后的第一次点击）
            assignIfChanged(try await status, to: \.changes)
            assignIfChanged(try await branches, to: \.branches)
            assignIfChanged(try await stashes, to: \.stashes)
            assignIfChanged(try await worktrees, to: \.worktrees)
            assignIfChanged(try await tags, to: \.tags)
            assignIfChanged(try await headReachable, to: \.headReachable)
            assignIfChanged(try await rebaseInProgress, to: \.rebaseInProgress)
            assignIfChanged(try await branch, to: \.currentBranch)
            assignIfChanged(try await sync, to: \.sync)
            assignIfChanged(try await head, to: \.headSummary)
            let newFiles = try await files
            let newIgnored = (try? await ignoredFiles) ?? []
            if newFiles != self.workspaceFiles || newIgnored != self.workspaceIgnored {
                self.workspaceFiles = newFiles
                self.workspaceIgnored = newIgnored
                self.rebuildWorkspaceTree()
                Diagnostics.log("工作区树重建 文件=\(newFiles.count) 忽略=\(newIgnored.count) 顶层节点=\(self.workspaceTree.count)")
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
            // 提交/检出/暂存后 HEAD 可能变了，刷新编辑器改动标记基线
            if let editorPath, !isUntitled(editorPath) {
                loadEditorBaseline(editorPath)
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
        worktrees = []
        tags = []
        headReachable = []
        rebaseInProgress = false
        history = []
        currentBranch = ""
        sync = SyncStatus(upstream: nil, ahead: 0, behind: 0)
        headSummary = nil
        guard let root = repoRoot, !isStandaloneFile else {
            workspaceFiles = []        // 单文件模式：无文件树
            workspaceIgnored = []
            workspaceTree = []
            return
        }
        let files = await Task.detached(priority: .userInitiated) {
            RepoViewModel.listFilesOnDisk(root: root)
        }.value
        if files != workspaceFiles || !workspaceIgnored.isEmpty {
            workspaceFiles = files
            workspaceIgnored = []   // 非 git 根无忽略概念
            rebuildWorkspaceTree()
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

    /// 用当前缓存(跟踪文件 + 忽略折叠项 + 已懒加载的忽略目录内容)重建文件树。
    /// 隐藏名单按用户设置过滤(仅作用于文件树视图)。
    private func rebuildWorkspaceTree() {
        workspaceTree = FileTreeBuilder.build(
            paths: workspaceFiles,
            ignored: workspaceIgnored + ignoredDirContents,
            hidden: SettingsStore.shared.hiddenFileNames
        )
    }

    /// 展开某个被忽略的目录时,懒加载其直接子项(只一层),让用户可逐级浏览内部内容。
    /// 因为 build 用了「父忽略则子继承忽略」,加载进来的条目会自动以淡色展示。
    func loadIgnoredDirIfNeeded(_ relPath: String) {
        guard let root = repoRoot, !loadedIgnoredDirs.contains(relPath) else { return }
        loadedIgnoredDirs.insert(relPath)
        let children = RepoViewModel.listDirectChildren(root: root, relDir: relPath)
        guard !children.isEmpty else { return }
        ignoredDirContents.append(contentsOf: children)
        rebuildWorkspaceTree()
    }

    /// 列某相对目录的直接子项(目录以 `/` 结尾)。供忽略目录懒加载浏览。
    nonisolated static func listDirectChildren(root: URL, relDir: String) -> [String] {
        let dirURL = root.appendingPathComponent(relDir)
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dirURL, includingPropertiesForKeys: [.isDirectoryKey], options: []
        ) else { return [] }
        var result: [String] = []
        for url in entries {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let rel = relDir + "/" + url.lastPathComponent
            result.append(isDir ? rel + "/" : rel)
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
        editorLoading = false
        editorBaseline = nil   // 换文件先清基线，异步加载完再画改动标记，避免串台

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
            blameHash = nil
            return
        }
        editorIsBinary = false

        if let buffer = buffers[path] {
            editorText = buffer.text
            editorDirty = buffer.dirty
            editorPath = path
            blameText = nil
            blameHash = nil
            reparseConflicts()
            loadEditorBaseline(path)
        } else if isUntitled(path) {
            editorText = ""
            editorDirty = false
            editorPath = path
            blameText = nil
            blameHash = nil
            reparseConflicts()
        } else {
            // 异步读盘：大文件同步读会顿住主线程。先清空 + 标记加载，后台读完再回主线程填入。
            let url = editorFileURL(path)
            editorText = ""
            editorDirty = false
            editorPath = path
            blameText = nil
            blameHash = nil
            conflictBlocks = []
            editorLoading = true
            let targetPath = path
            Task {
                let content = await Task.detached(priority: .userInitiated) {
                    (try? String(contentsOf: url, encoding: .utf8))
                        ?? (try? String(contentsOf: url, encoding: .isoLatin1)) ?? ""
                }.value
                await MainActor.run {
                    // 读盘期间用户可能切了文件，只有仍是目标文件才填入
                    guard self.editorPath == targetPath else { return }
                    self.editorText = content
                    self.editorLoading = false
                    self.reparseConflicts()
                    self.loadEditorBaseline(targetPath)
                }
            }
        }
    }

    /// 加载改动标记的基线：取该文件的 HEAD 版本。未跟踪/尚无提交 → 基线设为空串，
    /// 让编辑器把整文件当作新增（全绿）。无仓库/单文件模式不画标记（基线保持 nil）。
    func loadEditorBaseline(_ path: String) {
        guard let repo, !isUntitled(path), !path.hasPrefix("/") else {
            editorBaseline = nil
            return
        }
        Task { [weak self] in
            let content = try? await repo.headContent(of: path)
            await MainActor.run {
                guard let self, self.editorPath == path else { return }
                // headContent 为 nil = 文件未跟踪 → 整文件视为新增
                let next = content ?? ""
                if self.editorBaseline != next { self.editorBaseline = next }  // 不变就不重发，省一次重绘
            }
        }
    }

    /// 编辑器读盘用的 URL：绝对路径（单文件模式 / 仓库外文件）直接用，相对路径走仓库根。
    func editorFileURL(_ path: String) -> URL {
        path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : (repo?.fileURL(for: path) ?? URL(fileURLWithPath: path))
    }

    /// 在当前工作区窗口里「预览」一个外部文件(VS Code 式):只把编辑器切到该文件,
    /// 不改 repoRoot / workspace / 侧栏,当前仓库上下文原样保留。
    func previewExternalFile(_ url: URL) {
        Diagnostics.log("预览外部文件 \(url.lastPathComponent)(不切换目录)")
        selection = .file(path: url.path)
    }

    /// 打开单个文件（不要求 git 仓库）：以文件所在目录为根、repo=nil，纯查看/编辑。
    func openStandaloneFile(_ url: URL) {
        Diagnostics.log("单文件模式打开 \(url.lastPathComponent)（无 git 仓库）")
        repo = nil
        isGitRepo = false
        isStandaloneFile = true
        workspaceRoot = nil
        discoveredRepos = []
        activeWorkspaceRepo = nil
        repoRoot = url.deletingLastPathComponent()  // 目录作根（无 git），让主界面显示编辑器
        sidebarVisible = false                       // 单文件无文件树，收起侧边栏只看文件
        workspaceFiles = []
        workspaceIgnored = []
        loadedIgnoredDirs = []
        ignoredDirContents = []
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
        // 点文件标签：激活该文件标签（即便已是当前文件，也要从 diff/搜索/提交切回编辑器）
        activeDetail = .file(path)
        guard selection != .file(path: path) else { return }
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
        let wasActive = activeDetail == .file(path)
        openTabs.remove(at: index)
        buffers[path] = nil

        // editorPath 仍指向被关文件(它正被编辑器持有,哪怕此刻在看它的 diff):必须清空。
        // 否则随后激活别的标签时,openEditor 开头的 stashActiveBuffer 会把「还留在 editorText
        // 里的这份陈旧文本」按 editorPath 写回邻居缓冲,把邻居标签弄空/串台(⌘W 关 B 却把 A 清空)。
        if editorPath == path {
            editorPath = nil
            editorText = ""
            editorDirty = false
            editorBaseline = nil
        }

        guard wasActive else { return }  // 关的不是当前激活标签:列表移除即可,不切显示

        // 关的是当前激活标签:回到上一个看过的(访问历史),其次相邻文件,再次视图标签,最后清空
        if let prev = popHistory() {
            activate(prev)
        } else if !openTabs.isEmpty {
            selectTab(openTabs[min(index, openTabs.count - 1)])
        } else if let v = openViewTabs.last {
            activateViewTab(v)
        } else {
            activeDetail = nil
            selection = nil
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
        // 统一标签栏:「关闭其他」也清掉 diff/提交/搜索等视图标签
        for tab in openViewTabs {
            closeViewTab(tab)
        }
        selection = .file(path: path)
    }

    func closeTabsToTheRight(of path: String) {
        stashActiveBuffer()
        guard let index = openTabs.firstIndex(of: path) else { return }
        for other in openTabs.suffix(from: index + 1) where buffers[other]?.dirty != true {
            performCloseTab(other)
        }
    }

    // MARK: 视图标签的批量关闭（右键菜单：diff / 提交 / 比较 / 搜索）

    /// 关闭除该视图标签外的全部标签（含文件标签）；有未保存修改的文件标签保留。
    func closeOtherTabs(keepingViewTab keep: ViewTab) {
        stashActiveBuffer()
        for path in openTabs where buffers[path]?.dirty != true {
            performCloseTab(path)
        }
        for tab in openViewTabs where tab != keep {
            closeViewTab(tab)
        }
        activateViewTab(keep)
    }

    /// 关闭该视图标签右侧的视图标签。
    func closeViewTabsToTheRight(of tab: ViewTab) {
        guard let index = openViewTabs.firstIndex(of: tab) else { return }
        for other in Array(openViewTabs.suffix(from: index + 1)) {
            closeViewTab(other)
        }
    }

    /// 关闭全部标签（文件 + 视图）；有未保存修改的文件标签保留。
    func closeAllTabs() {
        stashActiveBuffer()
        for path in openTabs where buffers[path]?.dirty != true {
            performCloseTab(path)
        }
        for tab in openViewTabs {
            closeViewTab(tab)
        }
    }

    /// ⌘W:关闭当前激活的标签——文件标签 / diff·提交·比较·搜索视图标签一视同仁;
    /// 真没有任何标签时才关窗。
    func closeActiveTab() {
        switch activeDetail {
        case .file(let path):
            closeTab(path)
        case .view(let tab):
            closeViewTab(tab)
        case .none:
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

    // MARK: - 关窗口 / 退出前的未保存提示

    /// 本窗口是否有未保存改动（当前文件或任一缓冲）。
    func hasUnsavedChanges() -> Bool {
        if editorDirty { return true }
        return buffers.values.contains { $0.dirty }
    }

    /// 放弃本窗口所有未保存改动（只清脏标记，不写盘）。关窗口选「不保存」时用——
    /// 顺带让随后的退出检查不再把它当脏窗口，避免「关窗口」和「退出」各弹一次。
    func discardAllDirty() {
        editorDirty = false
        for key in buffers.keys where buffers[key]?.dirty == true {
            buffers[key]?.dirty = false
        }
    }

    /// 落盘本窗口所有已命名的脏标签（当前文件 + 各缓冲）。未命名缓冲需另存对话框，这里跳过。
    func saveAllDirty() async {
        stashActiveBuffer()  // 当前编辑内容先刷回缓冲，统一从 buffers 落盘
        for (path, buffer) in buffers where buffer.dirty && !isUntitled(path) {
            do {
                try buffer.text.write(to: editorFileURL(path), atomically: true, encoding: .utf8)
                buffers[path]?.dirty = false
                if editorPath == path { editorDirty = false }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        if repo != nil { await refresh() }
    }

    /// 关窗口前确认未保存改动：弹原生 sheet（保存 / 不保存 / 取消）。
    /// 在 windowShouldClose 里返回 false 后调用，由这里异步决定是否真的关。
    func confirmCloseWindow(_ window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = tr("有未保存的修改", "You have unsaved changes")
        alert.informativeText = tr("关闭窗口前是否保存?", "Save your changes before closing this window?")
        alert.addButton(withTitle: tr("保存", "Save"))
        alert.addButton(withTitle: tr("不保存", "Don't Save"))
        alert.addButton(withTitle: tr("取消", "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] resp in
            switch resp {
            case .alertFirstButtonReturn:            // 保存
                Task { @MainActor in
                    await self?.saveAllDirty()
                    window.close()                   // close() 不再走 windowShouldClose，直接关
                }
            case .alertSecondButtonReturn:           // 不保存：丢弃改动再关，避免退出检查重复弹框
                self?.discardAllDirty()
                window.close()
            default:                                 // 取消：什么都不做
                break
            }
        }
    }

    /// 给窗口装上「关闭前查未保存」的代理（转发其余事件给 SwiftUI 原代理）。
    func installCloseGuard(on window: NSWindow) {
        if let existing = window.delegate as? WindowCloseGuard {
            existing.vm = self
            closeGuard = existing
            return
        }
        let guardDelegate = WindowCloseGuard()
        guardDelegate.vm = self
        guardDelegate.original = window.delegate
        window.delegate = guardDelegate
        closeGuard = guardDelegate  // delegate 是 weak，自己强持有
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
        blameHash = nil
        guard let repo, let path = editorPath, !isUntitled(path) else { return }
        if editorDirty {
            blameText = tr("未保存的更改", "Unsaved changes")
            return
        }
        let key = "\(path)#\(line)"
        if let cached = blameCache[key] {
            blameText = cached.text
            blameHash = cached.hash
            return
        }
        blameText = nil
        blameTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let info = try? await repo.blame(path: path, line: line)
            guard !Task.isCancelled, let self else { return }
            let text: String
            var hash: String?
            if let info {
                if info.isUncommitted {
                    text = tr("未提交的更改", "Uncommitted changes")
                } else {
                    hash = info.hash
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
                self.blameCache[key] = (text: text, hash: hash)
                self.blameText = text.isEmpty ? nil : text
                self.blameHash = hash
            }
        }
    }

    /// 取提交详情（blame 悬浮卡用），带进程内缓存。
    func commitDetail(hash: String) async -> Repository.CommitDetail? {
        if let cached = commitDetailCache[hash] { return cached }
        guard let repo else { return nil }
        guard let detail = try? await repo.commitDetail(hash: hash) else { return nil }
        commitDetailCache[hash] = detail
        return detail
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

    // MARK: 目录级批量操作（文件树父节点）

    /// 某目录下属于指定区域的变更文件路径。
    private func changePaths(under dir: String, area: ChangeArea) -> [String] {
        let prefix = dir.isEmpty ? "" : dir + "/"
        let list: [FileChange]
        switch area {
        case .staged: list = stagedChanges
        case .unstaged: list = unstagedChanges
        case .conflicted: list = conflictedChanges
        }
        return list.filter { dir.isEmpty || $0.path.hasPrefix(prefix) }.map(\.path)
    }

    /// 暂存某目录下的全部更改。
    func stageDirectory(_ dir: String) {
        let paths = changePaths(under: dir, area: .unstaged)
        guard !paths.isEmpty else { return }
        perform { try await self.repo?.stage(paths: paths) }
    }

    /// 取消暂存某目录下的全部更改。
    func unstageDirectory(_ dir: String) {
        let paths = changePaths(under: dir, area: .staged)
        guard !paths.isEmpty else { return }
        perform { try await self.repo?.unstage(paths: paths) }
    }

    /// 待确认丢弃的目录（非 nil 时弹确认框）。
    @Published var pendingDiscardDir: String?

    func requestDiscardDirectory(_ dir: String) {
        pendingDiscardDir = dir
    }

    /// 丢弃某目录下的全部更改：已跟踪的恢复工作区，未跟踪的删除。
    func confirmDiscardDirectory() {
        guard let dir = pendingDiscardDir else { return }
        pendingDiscardDir = nil
        let prefix = dir.isEmpty ? "" : dir + "/"
        let targets = unstagedChanges.filter { dir.isEmpty || $0.path.hasPrefix(prefix) }
        perform { [self] in
            guard let repo = self.repo else { return }
            let tracked = targets.filter { $0.unstaged != .untracked }.map(\.path)
            if !tracked.isEmpty { try await repo.discardWorktree(paths: tracked) }
            for c in targets where c.unstaged == .untracked {
                try repo.deleteUntracked(path: c.path)
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

    // MARK: 撤销 / 修改最近提交

    /// 撤销最近提交的确认开关
    @Published var pendingUndoLastCommit = false
    /// 「修改提交消息」表单
    @Published var showRewordCommit = false
    @Published var rewordMessage = ""

    func promptUndoLastCommit() { pendingUndoLastCommit = true }

    /// 撤销最近一次提交：改动回到暂存区，原消息回填到提交框，便于重新修改后再提交。
    func confirmUndoLastCommit() {
        pendingUndoLastCommit = false
        guard let repo else { return }
        Task {
            do {
                let original = try await repo.lastCommitMessage()
                try await repo.undoLastCommit()
                await MainActor.run {
                    // 提交框为空才回填，避免覆盖用户正在输入的内容
                    if commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        commitMessage = original
                    }
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            await refresh()
        }
    }

    /// 打开「修改提交消息」表单，预填最近提交的消息。
    func startRewordLastCommit() {
        guard let repo else { return }
        Task {
            let original = (try? await repo.lastCommitMessage()) ?? ""
            await MainActor.run {
                rewordMessage = original
                showRewordCommit = true
            }
        }
    }

    func confirmRewordCommit() {
        let msg = rewordMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty else { return }
        showRewordCommit = false
        perform { try await self.repo?.commit(message: msg, amend: true) }
    }

    /// 待确认还原(revert)的提交
    @Published var commitToRevert: Repository.Commit?

    func promptRevertCommit(_ commit: Repository.Commit) {
        commitToRevert = commit
    }

    /// 还原该提交：生成反向提交;冲突文件进「合并更改」区，解决后提交完成 revert。
    func confirmRevertCommit() {
        guard let commit = commitToRevert else { return }
        commitToRevert = nil
        perform { try await self.repo?.revert(commit: commit.hash) }
    }

    /// 待选择模式并重置到的目标提交
    @Published var commitToReset: Repository.Commit?

    func promptResetToCommit(_ commit: Repository.Commit) {
        commitToReset = commit
    }

    func resetToCommit(_ mode: Repository.ResetMode) {
        guard let commit = commitToReset else { return }
        commitToReset = nil
        perform { try await self.repo?.reset(to: commit.hash, mode: mode) }
    }

    /// 待确认摘取(cherry-pick)的提交
    @Published var commitToCherryPick: Repository.Commit?

    func promptCherryPick(_ commit: Repository.Commit) {
        commitToCherryPick = commit
    }

    func confirmCherryPick() {
        guard let commit = commitToCherryPick else { return }
        commitToCherryPick = nil
        perform { try await self.repo?.cherryPick(commit: commit.hash) }
    }

    // MARK: - 交互式变基

    @Published var rebaseSteps: [RebaseStep] = []
    @Published var rebaseBase: String?
    /// 变基冲突中断中（由 refresh 检测 .git/rebase-merge）
    @Published var rebaseInProgress = false

    // rebase tab 底部「选中提交详情」状态
    @Published var rebaseDetailCommit: Repository.Commit?
    @Published var rebaseDetailFiles: [Repository.CommitFileChange] = []
    @Published var rebaseDetailDiff: FileDiff?
    @Published var rebaseDetailDiffPath: String?

    /// 打开（或聚焦）交互式变基 tab。
    func openRebaseTab() {
        if !openViewTabs.contains(.rebase) { openViewTabs.append(.rebase) }
        activeDetail = .view(.rebase)
    }

    /// 整理某提交「之后」到 HEAD 的提交（base..HEAD），并打开变基 tab。
    func startRebaseEditor(after base: Repository.Commit) {
        guard let repo else { return }
        Task {
            let commits = (try? await repo.commitsToRebase(after: base.hash)) ?? []
            await MainActor.run {
                rebaseBase = base.hash
                rebaseSteps = commits.map { RebaseStep(commit: $0, action: .pick) }
                rebaseDetailCommit = nil
                rebaseDetailFiles = []
                rebaseDetailDiff = nil
                rebaseDetailDiffPath = nil
                if rebaseSteps.isEmpty {
                    notice = tr("该提交之后没有可整理的提交。", "No commits after this one to reorganize.")
                } else {
                    openRebaseTab()
                }
            }
        }
    }

    func moveRebaseStep(from source: IndexSet, to destination: Int) {
        rebaseSteps.move(fromOffsets: source, toOffset: destination)
    }

    func setRebaseAction(_ action: RebaseAction, for id: String) {
        if let i = rebaseSteps.firstIndex(where: { $0.id == id }) {
            rebaseSteps[i].action = action
        }
    }

    /// 在 rebase tab 里选中一个待整理的提交，加载它改动的文件列表。
    func selectRebaseStep(_ step: RebaseStep) {
        guard let repo else { return }
        rebaseDetailCommit = step.commit
        rebaseDetailFiles = []
        rebaseDetailDiff = nil
        rebaseDetailDiffPath = nil
        Task {
            do {
                let files = try await repo.filesChanged(in: step.commit.hash)
                await MainActor.run {
                    rebaseDetailFiles = files
                    if files.count == 1 { selectRebaseDetailFile(files[0]) }
                }
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription }
            }
        }
    }

    /// 在 rebase 详情里选中一个文件，加载它在该提交里的 diff。
    func selectRebaseDetailFile(_ file: Repository.CommitFileChange) {
        guard let repo, let commit = rebaseDetailCommit else { return }
        rebaseDetailDiffPath = file.path
        Task {
            do {
                let d = try await repo.diff(in: commit.hash, path: file.path)
                await MainActor.run { rebaseDetailDiff = d }
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription }
            }
        }
    }

    func runInteractiveRebase() {
        guard let repo, let base = rebaseBase else { return }
        let todo = rebaseSteps.map { (hash: $0.commit.hash, action: $0.action) }
        closeViewTab(.rebase)
        perform { try await repo.interactiveRebase(onto: base, todo: todo) }
    }

    func continueRebase() {
        perform { try await self.repo?.rebaseContinue() }
    }

    func abortRebase() {
        perform { try await self.repo?.rebaseAbort() }
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

    // MARK: - 工作树

    /// 待确认移除的工作树（非 nil 时弹确认框）
    @Published var worktreeToRemove: Worktree?
    /// 新建工作树表单是否展示
    @Published var showCreateWorktree = false

    /// 当前窗口打开的工作树。
    var currentWorktree: Worktree? { worktrees.first(where: \.isCurrent) }
    /// 当前窗口打开的是否为链接工作树（非主工作树）——用于工具栏标志。
    var isLinkedWorktree: Bool { currentWorktree.map { !$0.isMain } ?? false }
    /// 主工作树名（链接工作树窗口的标志 tooltip 用）。
    var mainWorktreeName: String? { worktrees.first(where: \.isMain)?.name }
    /// 已被某个工作树占用的分支名（新建工作树时这些分支不可再选）。
    var branchesInUse: Set<String> { Set(worktrees.compactMap(\.branch)) }

    /// 在当前窗口切换到该工作树目录（左键点击行）。
    func switchToWorktree(_ wt: Worktree) {
        guard !wt.isCurrent else { return }
        Task { await open(URL(fileURLWithPath: wt.path)) }
    }

    /// 被「其他」工作树(非当前)占用的分支 → 持有它的工作树。
    /// 这些分支无法在当前工作树 checkout（git 限制：一个分支只能被一个工作树检出），
    /// 分支面板据此把「切换分支」改为「切到那个工作树」。
    var branchToWorktree: [String: Worktree] {
        var map: [String: Worktree] = [:]
        for wt in worktrees where !wt.isCurrent {
            if let b = wt.branch { map[b] = wt }
        }
        return map
    }

    /// 在新窗口打开工作树目录（SwiftUI 对相同路径会聚焦已存在窗口，天然防重复）。
    func openWorktree(_ wt: Worktree) {
        guard !wt.isCurrent else { return }
        openWindowRequest = wt.path
    }

    /// 把工作树检出的分支（detached 时为其 HEAD）与当前 HEAD 对比，复用比较视图。
    func compareWorktree(_ wt: Worktree) {
        guard !wt.isCurrent else { return }
        openHistoryDetail(.compare(base: wt.refName, target: "HEAD"))
    }

    func createWorktree(path: String, branch: String, createBranch: Bool) {
        let p = path.trimmingCharacters(in: .whitespaces)
        let b = branch.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty, !b.isEmpty else { return }
        showCreateWorktree = false
        perform { try await self.repo?.addWorktree(path: p, branch: b, createBranch: createBranch) }
    }

    func promptRemoveWorktree(_ wt: Worktree) {
        guard !wt.isMain, !wt.isCurrent else { return }  // 主工作树 / 当前工作树不可移除
        worktreeToRemove = wt
    }

    func confirmRemoveWorktree(force: Bool) {
        guard let wt = worktreeToRemove else { return }
        worktreeToRemove = nil
        perform { try await self.repo?.removeWorktree(path: wt.path, force: force) }
    }

    // MARK: - 标签

    /// 待确认删除的标签
    @Published var tagToDelete: Tag?
    /// 新建标签表单是否展示
    @Published var showCreateTag = false

    func createTag(name: String, message: String?, ref: String = "HEAD") {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        showCreateTag = false
        perform { try await self.repo?.createTag(name: n, message: message, ref: ref) }
    }

    func promptDeleteTag(_ tag: Tag) {
        tagToDelete = tag
    }

    func confirmDeleteTag() {
        guard let tag = tagToDelete else { return }
        tagToDelete = nil
        perform { try await self.repo?.deleteTag(tag.name) }
    }

    func pushTag(_ tag: Tag) {
        perform { try await self.repo?.pushTag(tag.name) }
    }

    /// 把标签与当前 HEAD 对比，复用比较视图。
    func compareTag(_ tag: Tag) {
        openHistoryDetail(.compare(base: tag.name, target: "HEAD"))
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
        // 作为视图标签打开/聚焦(可多个提交标签并存)
        let tab: ViewTab
        switch detail {
        case .commit(let c): tab = .commit(c)
        case .compare(let b, let t): tab = .compare(b, t)
        }
        if !openViewTabs.contains(tab) { openViewTabs.append(tab) }
        activeDetail = .view(tab)
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
        // 关掉当前显示的提交/比较视图标签
        if case .view(let v) = activeDetail, case .commit = v { closeViewTab(v); return }
        if case .view(let v) = activeDetail, case .compare = v { closeViewTab(v); return }
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
