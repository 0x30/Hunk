import SwiftUI
import HunkCore

struct SidebarView: View {
    @EnvironmentObject var vm: RepoViewModel
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        Group {
            switch vm.sidebarTab {
            case .files:
                FilesView()
            case .changes:
                VStack(spacing: 0) {
                    // 「文件变化」模块：提交输入框 + 变更列表，一起折叠
                    PanelHeader(
                        title: tr("文件变化", "Changes"),
                        count: vm.changes.count,
                        collapsed: $vm.changesPanelCollapsed
                    )
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
        .toolbar(removing: .sidebarToggle)
        // 导航图标在侧边栏标题区，紧贴交通灯（Xcode 式）
        .toolbar {
            ToolbarItem {
                SidebarNavButtons()
            }
        }
    }
}

/// 可折叠模块的头部（chevron + 标题 + 计数）。
struct PanelHeader: View {
    let title: String
    var count: Int = 0
    @Binding var collapsed: Bool

    var body: some View {
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
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
            if vm.isGitRepo {
                navButton(
                    tab: .changes,
                    systemImage: "plus.forwardslash.minus",
                    badge: vm.changes.count,
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
            // 固定框 + 角标 overlay：计数变化不会让图标移位
            Image(systemName: systemImage)
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .frame(width: 22, height: 18)
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
        }
        .help(help)
    }
}

// MARK: - 工具栏：仓库 + 分支（Xcode 式）

struct BranchMenu: View {
    @EnvironmentObject var vm: RepoViewModel

    var body: some View {
        Button {
            vm.showBranchPanel.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text(vm.repoRoot?.lastPathComponent ?? "Hunk")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 2) {
                        Text(vm.currentBranch)
                            .font(.system(size: 10.5))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .semibold))
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
        .help(tr("分支：切换 / 新建", "Branches: switch / create"))
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
                            BranchPopoverRow(branch: branch) {
                                vm.checkout(branch)
                                isPresented = false
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

