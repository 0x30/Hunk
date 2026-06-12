import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var vm: RepoViewModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $vm.sidebarTab) {
                Image(systemName: "plus.forwardslash.minus")
                    .help(tr("源代码管理", "Source Control"))
                    .tag(SidebarTab.changes)
                Image(systemName: "folder")
                    .help(tr("文件", "Files"))
                    .tag(SidebarTab.files)
                Image(systemName: "arrow.triangle.branch")
                    .help(tr("分支与贮藏", "Branches & Stashes"))
                    .tag(SidebarTab.branches)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            switch vm.sidebarTab {
            case .changes:
                ChangesListView()
                Divider()
                CommitBarView()
            case .files:
                FilesView()
            case .branches:
                BranchesView()
            }
        }
    }
}

/// 工具栏：分支切换菜单。
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
            Label(vm.currentBranch, systemImage: "arrow.triangle.branch")
                .labelStyle(.titleAndIcon)
        }
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

/// 工具栏：远端同步（抓取 / 拉取 / 推送 + ahead/behind 指示）。
struct SyncControls: View {
    @EnvironmentObject var vm: RepoViewModel

    var body: some View {
        HStack(spacing: 2) {
            Button {
                vm.fetch()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .help(tr("抓取", "Fetch") + upstreamSuffix)

            Button {
                vm.pull()
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.down")
                    if vm.sync.behind > 0 {
                        Text("\(vm.sync.behind)")
                            .font(.caption.monospacedDigit())
                    }
                }
            }
            .help(tr("拉取", "Pull") + upstreamSuffix)

            Button {
                vm.push()
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.up")
                    if vm.sync.ahead > 0 {
                        Text("\(vm.sync.ahead)")
                            .font(.caption.monospacedDigit())
                    }
                }
            }
            .help(vm.sync.upstream == nil
                  ? tr("推送（将发布分支）", "Push (will publish branch)")
                  : tr("推送", "Push") + upstreamSuffix)

            if vm.isSyncing {
                ProgressView()
                    .controlSize(.small)
                    .padding(.leading, 4)
            }
        }
        .disabled(vm.isSyncing)
    }

    private var upstreamSuffix: String {
        vm.sync.upstream.map { " (\($0))" } ?? ""
    }
}
