import SwiftUI
import HunkCore

/// 「文件」标签页：整个工作区的文件树（git ls-files，跟踪 + 未跟踪未忽略）。
struct FilesView: View {
    @EnvironmentObject var vm: RepoViewModel

    var body: some View {
        List(selection: $vm.selection) {
            OutlineGroup(vm.workspaceTree, children: \.children) { node in
                if node.isDirectory {
                    HStack(spacing: 5) {
                        FileIconView(fileName: node.name, isDirectory: true)
                        Text(node.name)
                            .lineLimit(1)
                    }
                } else {
                    FileRow(node: node)
                        .tag(SidebarSelection.file(path: node.path))
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if vm.workspaceTree.isEmpty {
                Text(tr("空仓库", "Empty repository"))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct FileRow: View {
    @EnvironmentObject var vm: RepoViewModel
    let node: FileNode

    /// 该文件当前的变更状态（如有），行尾显示徽标。
    private var change: FileChange? {
        vm.changes.first { $0.path == node.path }
    }

    var body: some View {
        HStack(spacing: 5) {
            FileIconView(fileName: node.name)
            Text(node.name)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let kind = change?.unstaged ?? change?.staged {
                Text(kind.badge)
                    .font(.caption.weight(.semibold).monospaced())
                    .foregroundStyle(kind.color)
                    .help(kind.localizedName)
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            if change != nil {
                Button(tr("查看更改", "View Changes")) {
                    vm.sidebarTab = .changes
                    if let change {
                        let area: ChangeArea = change.isConflicted
                            ? .conflicted
                            : (change.unstaged != nil ? .unstaged : .staged)
                        vm.selection = .change(path: change.path, area: area)
                    }
                }
                Divider()
            }
            Button(tr("在 Finder 中显示", "Reveal in Finder")) { vm.revealInFinder(node.path) }
            Button(tr("复制路径", "Copy Path")) { vm.copyPath(node.path) }
        }
    }
}
