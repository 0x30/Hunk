import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var vm: RepoViewModel

    var body: some View {
        Group {
            switch vm.sidebarTab {
            case .files:
                FilesView()
            case .changes:
                VStack(spacing: 0) {
                    ChangesListView()
                    Divider()
                    CommitBarView()
                }
            }
        }
        // Xcode 导航器风格：标签图标放在窗口标题栏（交通灯右侧）
        .toolbar {
            ToolbarItemGroup {
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
    }

    private func navButton(tab: SidebarTab, systemImage: String, badge: Int = 0, help: String) -> some View {
        let selected = vm.sidebarTab == tab
        return Button {
            vm.sidebarTab = tab
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .overlay(alignment: .topTrailing) {
                    Text(badge > 0 ? "\(min(badge, 99))" : "")
                        .font(.system(size: 8, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, badge > 0 ? 3 : 0)
                        .padding(.vertical, badge > 0 ? 0.5 : 0)
                        .background(Capsule().fill(badge > 0 ? Color.accentColor : .clear))
                        .offset(x: 9, y: -5)
                }
        }
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
