import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var vm: RepoViewModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $vm.sidebarTab) {
                Label(tr("文件", "Files"), systemImage: "folder")
                    .tag(SidebarTab.files)
                    .help(tr("文件 (⌘1)", "Files (⌘1)"))
                Label(tr("源代码管理", "Source Control"), systemImage: "plus.forwardslash.minus")
                    .tag(SidebarTab.changes)
                    .help(tr("源代码管理 (⌘2)", "Source Control (⌘2)"))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            switch vm.sidebarTab {
            case .files:
                FilesView()
            case .changes:
                ChangesListView()
                Divider()
                CommitBarView()
            }
        }
    }
}

// MARK: - 工具栏：分支切换（胶囊样式）

struct BranchMenu: View {
    @EnvironmentObject var vm: RepoViewModel
    @State private var showNewBranch = false
    @State private var newBranchName = ""
    @State private var hovering = false

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
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 11, weight: .medium))
                Text(vm.currentBranch)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(Color.primary.opacity(hovering ? 0.1 : 0.06))
            )
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .onHover { hovering = $0 }
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

// MARK: - 工具栏：远端同步（胶囊分组）

struct SyncControls: View {
    @EnvironmentObject var vm: RepoViewModel

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 0) {
                PillIconButton(
                    systemImage: "arrow.triangle.2.circlepath",
                    help: tr("抓取", "Fetch") + upstreamSuffix
                ) { vm.fetch() }

                separator

                PillIconButton(
                    systemImage: "arrow.down",
                    count: vm.sync.behind,
                    help: tr("拉取", "Pull") + upstreamSuffix
                ) { vm.pull() }

                separator

                PillIconButton(
                    systemImage: "arrow.up",
                    count: vm.sync.ahead,
                    help: vm.sync.upstream == nil
                        ? tr("推送（将发布分支）", "Push (will publish branch)")
                        : tr("推送", "Push") + upstreamSuffix
                ) { vm.push() }
            }
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .disabled(vm.isSyncing)

            ProgressView()
                .controlSize(.small)
                .opacity(vm.isSyncing ? 1 : 0)
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1, height: 12)
    }

    private var upstreamSuffix: String {
        vm.sync.upstream.map { " (\($0))" } ?? ""
    }
}

/// 胶囊组里的单个图标按钮：计数文本始终在视图树中（空串），避免重建丢点击。
private struct PillIconButton: View {
    let systemImage: String
    var count: Int = 0
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
                Text(count > 0 ? "\(count)" : "")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(hovering ? Color.primary.opacity(0.08) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}
