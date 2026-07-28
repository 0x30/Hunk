import SwiftUI
import HunkCore

struct SidebarView: View {
    @EnvironmentObject var vm: RepoViewModel
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        VStack(spacing: 0) {
            // 变基进行中(冲突中断):两个标签页都能看到的状态条
            if vm.rebaseInProgress {
                RebaseBanner()
                Divider()
            }
            switch vm.sidebarTab {
            case .files:
                FilesView()
            case .changes:
                VStack(spacing: 0) {
                    if vm.isWorkspace {
                        WorkspaceRepositoryScopeBar()
                        Divider()
                    }
                    if vm.isWorkspace && vm.activeWorkspaceRepo == nil {
                        WorkspaceGitOverview()
                    } else {
                        VStack(spacing: 0) {
                            // 「文件变化」模块：提交输入框 + 变更列表，一起折叠
                            PanelHeader(
                                title: tr("文件变化", "Changes"),
                                count: vm.changes.count,
                                collapsed: $vm.changesPanelCollapsed
                            ) {
                                // 手动刷新工作区状态：不必再失焦/回焦才更新
                                Button {
                                    Task { await vm.refresh() }
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 11, weight: .semibold))
                                }
                                .buttonStyle(.plain)
                                .help(tr("刷新更改", "Refresh changes"))
                            }
                            if !vm.changesPanelCollapsed {
                                CommitBarView()
                                ChangesListView()
                            }
                            Divider()
                            HistoryPanel()
                            if vm.changesPanelCollapsed && vm.historyPanelCollapsed {
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
            }
            // 多仓库工作区：底部一条仓库切换芯片（VS Code 式，不占文件树空间）
            if vm.isWorkspace {
                Divider()
                WorkspaceStatusBar()
            }
        }
        .toolbar(removing: .sidebarToggle)
        // 导航图标在侧边栏标题区，紧贴交通灯（Xcode 式）
        .toolbar {
            ToolbarItem {
                SidebarNavButtons()
            }
        }
    }
}

/// 多仓库 Source Control 的就近 scope 导航。仓库像 section header 一样并排展示，
/// 当前项用底部强调线标记；查看 History 时无需再移动到底部状态栏。
private struct WorkspaceRepositoryScopeBar: View {
    @EnvironmentObject var vm: RepoViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(tr("仓库", "Repositories"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await vm.refreshRepositorySummaries() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help(tr("刷新所有仓库", "Refresh all repositories"))
                Button {
                    vm.addFolderPanel()
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help(tr("添加文件夹到工作区", "Add folder to workspace"))
            }
            .padding(.horizontal, 10)
            .frame(height: 24)

            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    scopeButton(
                        title: tr("全部", "All"),
                        detail: "\(vm.repositorySummaries.count)",
                        count: vm.repositorySummaries.reduce(0) { $0 + $1.changeCount },
                        selected: vm.activeWorkspaceRepo == nil
                    ) {
                        Task { await vm.selectWorkspaceOverview() }
                    }

                    ForEach(vm.repositorySummaries) { summary in
                        scopeButton(
                            title: vm.repositoryDisplayName(summary.url),
                            detail: summary.branch,
                            count: summary.changeCount,
                            selected: vm.activeWorkspaceRepo?.path == summary.url.path
                        ) {
                            Task { await vm.selectRepo(summary.url) }
                        }
                    }
                }
                .padding(.horizontal, 6)
            }
            .scrollIndicators(.hidden)
            .frame(height: 36)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func scopeButton(
        title: String,
        detail: String,
        count: Int,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.system(size: 11, weight: selected ? .semibold : .medium))
                        .lineLimit(1)
                    if count > 0 {
                        Text("\(count)")
                            .font(.system(size: 8.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(selected ? Color.accentColor : .secondary)
                    }
                }
                Text(detail.isEmpty ? tr("无提交", "No commits") : detail)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(minWidth: 62, minHeight: 32, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.08) : .clear)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(selected ? Color.accentColor : .clear)
                    .frame(height: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 多仓库工作区的底部状态条：一条芯片显示当前激活的仓库（或「整个文件夹」），
/// 点击弹出下拉，列「整个文件夹」总览 + 扫描到的各子仓库（带 ✓）来切换。不占文件树空间。
private struct WorkspaceStatusBar: View {
    @EnvironmentObject var vm: RepoViewModel

    /// 子仓库相对工作区根的显示名（如 foo、group/bar）。
    private func displayName(_ url: URL) -> String {
        vm.repositoryDisplayName(url)
    }

    /// 当前激活范围的显示名。
    private var activeName: String {
        if let active = vm.activeWorkspaceRepo { return displayName(active) }
        return tr("所有仓库", "All Repositories")
    }

    var body: some View {
        Menu {
            Button {
                Task { await vm.selectWorkspaceOverview() }
            } label: {
                Label(
                    tr("所有仓库", "All Repositories"),
                    systemImage: vm.activeWorkspaceRepo == nil ? "checkmark" : "folder"
                )
            }
            Divider()
            ForEach(vm.discoveredRepos, id: \.self) { url in
                Button {
                    Task { await vm.selectRepo(url) }
                } label: {
                    Label(displayName(url),
                          systemImage: vm.activeWorkspaceRepo == url ? "checkmark" : "arrow.triangle.branch")
                }
            }
            Divider()
            Button {
                vm.addFolderPanel()
            } label: {
                Label(tr("添加文件夹…", "Add Folder…"), systemImage: "folder.badge.plus")
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: vm.activeWorkspaceRepo == nil ? "folder" : "arrow.triangle.branch")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(activeName)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text("\(vm.discoveredRepos.count)")
                    .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help(tr("此文件夹含 \(vm.discoveredRepos.count) 个 git 仓库",
                             "\(vm.discoveredRepos.count) git repositories in this folder"))
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .background(Color(nsColor: .windowBackgroundColor))
        .help(tr("切换仓库", "Switch repository"))
    }
}

/// 可折叠模块的头部（chevron + 标题 + 计数 + 右侧操作槽）。
struct PanelHeader<Trailing: View>: View {
    let title: String
    var count: Int = 0
    @Binding var collapsed: Bool
    @ViewBuilder var trailing: () -> Trailing

    init(title: String, count: Int = 0, collapsed: Binding<Bool>,
         @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.count = count
        self._collapsed = collapsed
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 5) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    collapsed.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(count > 0 ? "\(count)" : "")
                        .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, count > 0 ? 4.5 : 0)
                        .padding(.vertical, count > 0 ? 1 : 0)
                        .background(Capsule().fill(.quaternary.opacity(count > 0 ? 0.6 : 0)))
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            trailing()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }
}

/// 文件 / 源代码管理导航（点击已选中的会收起侧边栏）。
/// 单个 ToolbarItem 内的固定布局：系统会自动包一层玻璃胶囊，
/// 两种侧边栏状态下几何与外观都恒定，无需自绘背景。
struct SidebarNavButtons: View {
    @EnvironmentObject var vm: RepoViewModel

    var body: some View {
        HStack(spacing: 8) {
            navButton(
                tab: .files,
                systemImage: "folder",
                help: tr("文件 (⌘1)", "Files (⌘1)")
            )
            // 源代码管理仅 git 仓库可用
            if vm.isGitRepo || vm.isWorkspace {
                navButton(
                    tab: .changes,
                    systemImage: "point.3.connected.trianglepath.dotted",
                    badge: vm.activeWorkspaceRepo == nil
                        ? vm.repositorySummaries.reduce(0) { $0 + $1.changeCount }
                        : vm.changes.count,
                    help: tr("源代码管理 (⌘2)", "Source Control (⌘2)")
                )
            }
        }
    }

    private func navButton(tab: SidebarTab, systemImage: String, badge: Int = 0, help: String) -> some View {
        let selected = vm.sidebarVisible && vm.sidebarTab == tab
        return Button {
            vm.toggleSidebarTab(tab)
        } label: {
            // Xcode 式：选中用圆角胶囊背景包裹，而非给图标染色（无符号动画）
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .frame(width: 26, height: 22)
                .background {
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(selected ? 0.1 : 0))
                }
                // 固定框 + 角标 overlay：计数变化不会让图标移位
                .overlay(alignment: .topTrailing) {
                    if badge > 0 {
                        Text("\(min(badge, 99))")
                            .font(.system(size: 8, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 0.5)
                            .background(Capsule().fill(selected ? Color.accentColor : Color.secondary))
                            .offset(x: 5, y: -4)
                    }
                }
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// “所有仓库”只做安全摘要；选择一个仓库后进入完整 Changes + History。
private struct WorkspaceGitOverview: View {
    @EnvironmentObject var vm: RepoViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(tr("所有仓库", "All Repositories"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("\(vm.repositorySummaries.count)")
                    .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await vm.refreshRepositorySummaries() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help(tr("刷新所有仓库", "Refresh all repositories"))
            }
            .padding(.horizontal, 10)
            .frame(height: 28)

            Divider()

            if vm.repositorySummaries.isEmpty {
                ContentUnavailableView(
                    tr("没有 Git 仓库", "No Git Repositories"),
                    systemImage: "arrow.triangle.branch",
                    description: Text(tr("添加一个 Git 项目后会在这里显示。",
                                         "Add a Git project to see it here."))
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(vm.repositorySummaries) { summary in
                            Button {
                                Task { await vm.selectRepo(summary.url) }
                            } label: {
                                repositoryRow(summary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func repositoryRow(_ summary: RepoViewModel.RepositorySummary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(summary.conflictCount > 0 ? Color.orange : Color.accentColor)
                Text(vm.repositoryDisplayName(summary.url))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer()
                if summary.changeCount > 0 {
                    Text("\(summary.changeCount)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(summary.conflictCount > 0 ? Color.orange : .secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 6) {
                Text(summary.branch.isEmpty ? tr("无提交", "No commits") : summary.branch)
                if summary.sync.ahead > 0 { Text("↑\(summary.sync.ahead)") }
                if summary.sync.behind > 0 { Text("↓\(summary.sync.behind)") }
                if summary.conflictCount > 0 {
                    Text(tr("\(summary.conflictCount) 个冲突", "\(summary.conflictCount) conflict(s)"))
                        .foregroundStyle(.orange)
                }
                Spacer()
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            if let head = summary.headSummary {
                Text(head)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

// MARK: - 工具栏：仓库 + 分支（Xcode 式）

struct BranchMenu: View {
    @EnvironmentObject var vm: RepoViewModel

    var body: some View {
        if vm.isGitRepo {
            // git 仓库：仓库名 + 当前分支 + 下拉箭头，点击出分支面板
            Button {
                vm.showBranchPanel.toggle()
            } label: {
                HStack(spacing: 6) {
                    // 链接工作树窗口：图标换成「分屏」并染主题色，与主仓库窗口一眼区分
                    Image(systemName: vm.isLinkedWorktree ? "square.split.2x1" : "arrow.triangle.branch")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(vm.isLinkedWorktree ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(vm.repositoryDisplayName)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            Text(vm.worktreeDisplayDetail)
                                .font(.system(size: 10.5))
                                .lineLimit(1)
                            if vm.isLinkedWorktree {
                                BranchTagLabel(tr("工作树", "worktree"))
                            }
                            Image(systemName: "chevron.down")
                                .font(.system(size: 7, weight: .semibold))
                        }
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .help(vm.isLinkedWorktree
                  ? tr("当前：\(vm.repositoryDisplayName) · \(vm.worktreeDisplayDetail)",
                       "Current: \(vm.repositoryDisplayName) · \(vm.worktreeDisplayDetail)")
                  : tr("分支：切换 / 新建", "Branches: switch / create"))
        } else if vm.isWorkspace && vm.activeWorkspaceRepo == nil {
            // 多仓库总览不是“非 git 目录”，明确标成工作区范围，避免用户误以为
            // back/front 的 Git 仓库失效。
            HStack(spacing: 5) {
                Image(systemName: "folder")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text(tr("所有仓库", "All Repositories"))
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(tr("\(vm.workspaceFolders.count) 个文件夹",
                            "\(vm.workspaceFolders.count) folders"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .help(tr("当前显示整个工作区的 Git 摘要",
                     "Showing the Git summary for the whole workspace"))
        } else {
            // 普通非 git 目录 / 单文件：没有分支概念，只静态显示当前文件夹名。
            HStack(spacing: 5) {
                Image(systemName: "folder")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(vm.repoRoot?.lastPathComponent ?? "Hunk")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .help(tr("非 git 目录（无分支）", "Non-git folder (no branches)"))
        }
    }
}

/// 分支按钮里的小号标签（如「工作树」）。
private struct BranchTagLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 4)
            .padding(.vertical, 0.5)
            .background(Capsule().fill(Color.accentColor.opacity(0.16)))
    }
}

/// Xcode 式分支面板：搜索、当前分支信息、切换、新建。
/// 以窗口内浮层呈现（工具栏 popover 锚点不可靠）。
struct BranchPopover: View {
    @EnvironmentObject var vm: RepoViewModel
    @Binding var isPresented: Bool
    @State private var query = ""
    @State private var newBranchName = ""
    @FocusState private var searchFocused: Bool

    private var filtered: [Branch] {
        vm.branches.filter {
            !$0.isCurrent && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(tr("查找分支", "Find branch"), text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onKeyPress(.escape) {
                        isPresented = false
                        return .handled
                    }
            }
            .padding(10)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(tr("当前分支", "Current Branch"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .padding(.bottom, 2)

                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.branch")
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(vm.currentBranch)
                                .font(.system(size: 13, weight: .semibold))
                            if let head = vm.headSummary {
                                Text(head)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)

                    if !filtered.isEmpty {
                        Divider()
                            .padding(.vertical, 4)
                        HStack {
                            Text(tr("切换到", "Switch To"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            // 一键删除所有已合并的分支（main/master/develop 受保护）
                            if vm.branches.contains(where: { $0.isMerged && !$0.isCurrent }) {
                                Button {
                                    isPresented = false
                                    vm.promptCleanupMergedBranches()
                                } label: {
                                    Image(systemName: "trash.slash")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                                .help(tr("删除所有已合并的分支", "Delete all merged branches"))
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 2)

                        ForEach(filtered) { branch in
                            // 被其他工作树占用的分支无法在此 checkout：点击改为切换到那个工作树
                            let occupying = vm.branchToWorktree[branch.name]
                            BranchPopoverRow(branch: branch, occupyingWorktreeName: occupying?.name) {
                                isPresented = false
                                if let occupying {
                                    vm.switchToWorktree(occupying)
                                } else {
                                    vm.checkout(branch)
                                }
                            } onCompare: {
                                isPresented = false
                                vm.compareBranch(branch)
                            } onMerge: {
                                isPresented = false
                                vm.mergeBranch(branch)
                            } onDelete: {
                                isPresented = false
                                vm.promptDeleteBranch(branch)
                            }
                        }
                    }
                }
                .padding(.bottom, 6)
            }
            .frame(maxHeight: 280)

            Divider()

            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                TextField(tr("新建分支并切换…", "New branch & switch…"), text: $newBranchName)
                    .textFieldStyle(.plain)
                    .onSubmit { create() }
                    .onKeyPress(.escape) {
                        isPresented = false
                        return .handled
                    }
                if !newBranchName.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button(tr("创建", "Create")) { create() }
                        .controlSize(.small)
                }
            }
            .padding(10)
        }
        .frame(width: 300)
        .onAppear { searchFocused = true }
        .onExitCommand { isPresented = false }
    }

    private func create() {
        let name = newBranchName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        vm.createBranch(name)
        newBranchName = ""
        isPresented = false
    }
}

private struct BranchPopoverRow: View {
    let branch: Branch
    var occupyingWorktreeName: String? = nil
    let action: () -> Void
    let onCompare: () -> Void
    let onMerge: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                // 已合并的分支在图标右下角带小对号
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(.secondary)
                    .overlay(alignment: .bottomTrailing) {
                        if branch.isMerged {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 7, weight: .bold))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .green)
                                .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).padding(-0.5))
                                .offset(x: 3, y: 3)
                        }
                    }
                Text(branch.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                // 被其他工作树占用：分支名后挂一个工作树标记
                if let occupyingWorktreeName {
                    Image(systemName: "folder")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .help(tr("已被工作树「\(occupyingWorktreeName)」检出，点击切换过去",
                                 "Checked out in worktree “\(occupyingWorktreeName)”; click to switch"))
                }
                Spacer()
                // 悬停浮现操作：对比 / 合并进当前分支 / 删除
                if hovering {
                    HStack(spacing: 2) {
                        RowActionIcon("arrow.left.arrow.right",
                                      help: tr("与当前分支对比", "Compare with current branch"),
                                      action: onCompare)
                        RowActionIcon("arrow.triangle.merge",
                                      help: tr("合并进当前分支", "Merge into current branch"),
                                      action: onMerge)
                        RowActionIcon("trash",
                                      help: tr("删除分支", "Delete branch"),
                                      action: onDelete)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(hovering ? Color.accentColor.opacity(0.14) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// 分支行悬停操作的小图标按钮。
private struct RowActionIcon: View {
    let systemName: String
    let help: String
    let action: () -> Void

    init(_ systemName: String, help: String, action: @escaping () -> Void) {
        self.systemName = systemName
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}
