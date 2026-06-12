import SwiftUI
import HunkCore

/// 「分支与贮藏」标签页。
struct BranchesView: View {
    @EnvironmentObject var vm: RepoViewModel
    @State private var newBranchName = ""

    var body: some View {
        List {
            Section(tr("分支", "Branches")) {
                ForEach(vm.branches) { branch in
                    BranchRow(branch: branch)
                }

                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    TextField(tr("新分支名", "New branch name"), text: $newBranchName)
                        .textFieldStyle(.plain)
                        .onSubmit {
                            vm.createBranch(newBranchName)
                            newBranchName = ""
                        }
                }
            }

            Section(tr("贮藏", "Stashes")) {
                if vm.stashes.isEmpty {
                    Text(tr("没有贮藏", "No stashes"))
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                ForEach(vm.stashes) { stash in
                    StashRow(stash: stash)
                }
            }
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, 24)
    }
}

private struct BranchRow: View {
    @EnvironmentObject var vm: RepoViewModel
    let branch: Branch
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: branch.isCurrent ? "checkmark.circle.fill" : "arrow.triangle.branch")
                .foregroundStyle(branch.isCurrent ? Color.accentColor : Color.secondary)
                .font(.caption)
            Text(branch.name)
                .fontWeight(branch.isCurrent ? .semibold : .regular)
                .lineLimit(1)
            Spacer()
            if hovering, !branch.isCurrent {
                Button(tr("切换", "Switch")) {
                    vm.checkout(branch)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.tint)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            if !branch.isCurrent {
                Button(tr("切换到此分支", "Switch to This Branch")) { vm.checkout(branch) }
            }
            Button(tr("复制分支名", "Copy Branch Name")) { vm.copyPath(branch.name) }
        }
    }
}

private struct StashRow: View {
    @EnvironmentObject var vm: RepoViewModel
    let stash: Stash

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "archivebox")
                .foregroundStyle(.secondary)
                .font(.caption)
            VStack(alignment: .leading, spacing: 1) {
                Text(stash.message)
                    .lineLimit(1)
                    .font(.callout)
                Text(stash.ref)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button(tr("应用", "Apply")) { vm.applyStash(stash, pop: false) }
            Button(tr("弹出（应用并删除）", "Pop (Apply & Drop)")) { vm.applyStash(stash, pop: true) }
            Divider()
            Button(tr("删除", "Drop"), role: .destructive) { vm.dropStash(stash) }
        }
    }
}
