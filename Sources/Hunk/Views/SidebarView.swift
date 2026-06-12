import SwiftUI

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
            ToolbarItemGroup {
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

/// 文件 / 源代码管理导航：胶囊分段样式（点击已选中的会收起侧边栏）。
struct SidebarNavButtons: View {
    @EnvironmentObject var vm: RepoViewModel

    var body: some View {
        HStack(spacing: 0) {
            segment(
                tab: .files,
                systemImage: "folder",
                help: tr("文件 (⌘1)", "Files (⌘1)")
            )
            // Xcode 式分段分隔线
            Rectangle()
                .fill(.separator.opacity(0.6))
                .frame(width: 1, height: 12)
            segment(
                tab: .changes,
                systemImage: "plus.forwardslash.minus",
                badge: vm.changes.count,
                help: tr("源代码管理 (⌘2)", "Source Control (⌘2)")
            )
        }
        .padding(3)
        // 与系统工具栏胶囊一致的实底悬浮感（侧边栏浅底上也清晰可辨）
        .background(
            Capsule()
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
        )
        .overlay(
            Capsule().strokeBorder(.separator.opacity(0.45), lineWidth: 0.5)
        )
    }

    private func segment(tab: SidebarTab, systemImage: String, badge: Int = 0, help: String) -> some View {
        let selected = vm.sidebarVisible && vm.sidebarTab == tab
        return Button {
            vm.toggleSidebarTab(tab)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .medium))
                Text(badge > 0 ? "\(min(badge, 99))" : "")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
            }
            // Xcode 式：选中段 = 实心强调色填充 + 白色图标
            .foregroundStyle(selected ? Color.white : Color.secondary)
            .padding(.horizontal, 10)
            .frame(height: 24)  // 与系统工具栏胶囊（分支 / 同步）等高
            .background(
                Capsule().fill(selected ? Color.accentColor : .clear)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - 工具栏：分支切换

struct BranchMenu: View {
    @EnvironmentObject var vm: RepoViewModel
    @State private var showNewBranch = false
    @State private var newBranchName = ""

    var body: some View {
        Menu {
            ForEach(vm.branches) { branch in
                Button {
                    vm.checkout(branch)
                } label: {
                    if branch.isCurrent {
                        Label(branch.name, systemImage: "checkmark")
                    } else {
                        Text(branch.name)
                    }
                }
            }
            Divider()
            Button(tr("新建分支…", "New Branch…")) {
                newBranchName = ""
                showNewBranch = true
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 11, weight: .medium))
                Text(vm.currentBranch)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
        }
        .menuIndicator(.visible)
        .fixedSize()
        .help(tr("切换分支", "Switch branch"))
        .sheet(isPresented: $showNewBranch) {
            VStack(spacing: 16) {
                Text(tr("从当前分支新建", "Create from current branch"))
                    .font(.headline)
                TextField(tr("分支名", "Branch name"), text: $newBranchName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                    .onSubmit { create() }
                HStack {
                    Button(tr("取消", "Cancel")) { showNewBranch = false }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(tr("创建并切换", "Create & Switch")) { create() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(newBranchName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .frame(width: 260)
            }
            .padding(20)
        }
    }

    private func create() {
        vm.createBranch(newBranchName)
        showNewBranch = false
    }
}

// MARK: - 工具栏：远端同步

struct SyncControls: View {
    @EnvironmentObject var vm: RepoViewModel

    var body: some View {
        // 计数文本始终在视图树中（空串），避免 NSToolbar 重建丢点击
        Button { vm.fetch() } label: {
            syncLabel("arrow.triangle.2.circlepath", count: 0)
        }
        .help(tr("抓取", "Fetch") + upstreamSuffix)
        .disabled(vm.isSyncing)

        Button { vm.pull() } label: {
            syncLabel("arrow.down", count: vm.sync.behind)
        }
        .help(tr("拉取", "Pull") + upstreamSuffix)
        .disabled(vm.isSyncing)

        Button { vm.push() } label: {
            syncLabel("arrow.up", count: vm.sync.ahead)
        }
        .help(vm.sync.upstream == nil
              ? tr("推送（将发布分支）", "Push (will publish branch)")
              : tr("推送", "Push") + upstreamSuffix)
        .disabled(vm.isSyncing)
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
