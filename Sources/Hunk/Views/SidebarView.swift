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
        HStack(spacing: 14) {
            navButton(
                tab: .files,
                systemImage: "folder",
                help: tr("文件 (⌘1)", "Files (⌘1)")
            )
            navButton(
                tab: .changes,
                systemImage: "plus.forwardslash.minus",
                badge: vm.changes.count,
                help: tr("源代码管理 (⌘2)", "Source Control (⌘2)")
            )
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
                        Text(tr("切换到", "Switch To"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 2)

                        ForEach(filtered) { branch in
                            BranchPopoverRow(branch: branch) {
                                vm.checkout(branch)
                                isPresented = false
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
                if !newBranchName.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button(tr("创建", "Create")) { create() }
                        .controlSize(.small)
                }
            }
            .padding(10)
        }
        .frame(width: 300)
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
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(.secondary)
                Text(branch.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Spacer()
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

// MARK: - 工具栏：远端同步

struct SyncControls: View {
    @EnvironmentObject var vm: RepoViewModel

    var body: some View {
        // 简洁模式：抓取常驻；有落后才显示拉取，有领先才显示推送
        Button { vm.fetch() } label: {
            syncLabel("arrow.triangle.2.circlepath", count: 0)
        }
        .help(tr("抓取", "Fetch") + upstreamSuffix)
        .disabled(vm.isSyncing)

        if vm.sync.behind > 0 {
            Button { vm.pull() } label: {
                syncLabel("arrow.down", count: vm.sync.behind)
            }
            .help(tr("拉取", "Pull") + upstreamSuffix)
            .disabled(vm.isSyncing)
        }

        if vm.sync.ahead > 0 {
            Button { vm.push() } label: {
                syncLabel("arrow.up", count: vm.sync.ahead)
            }
            .help(vm.sync.upstream == nil
                  ? tr("推送（将发布分支）", "Push (will publish branch)")
                  : tr("推送", "Push") + upstreamSuffix)
            .disabled(vm.isSyncing)
        }
    }

    private func syncLabel(_ systemImage: String, count: Int) -> some View {
        HStack(spacing: 2) {
            Image(systemName: systemImage)
            Text(count > 0 ? "\(count)" : "")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
        }
    }

    private var upstreamSuffix: String {
        vm.sync.upstream.map { " (\($0))" } ?? ""
    }
}
