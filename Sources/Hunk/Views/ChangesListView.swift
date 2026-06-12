import SwiftUI
import HunkCore

/// 「源代码管理」标签页：合并更改 / 已暂存 / 更改 三个分区，
/// 支持树状与扁平两种展示。
struct ChangesListView: View {
    @EnvironmentObject var vm: RepoViewModel
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        List(selection: $vm.selection) {
            if !vm.conflictedChanges.isEmpty {
                Section {
                    changeRows(vm.conflictedChanges, area: .conflicted)
                } header: {
                    sectionHeader(
                        tr("合并更改", "Merge Changes"),
                        count: vm.conflictedChanges.count,
                        systemImage: "exclamationmark.triangle"
                    ) { EmptyView() }
                }
            }

            Section {
                changeRows(vm.stagedChanges, area: .staged)
            } header: {
                sectionHeader(tr("已暂存的更改", "Staged Changes"), count: vm.stagedChanges.count) {
                    Button {
                        vm.unstageAll()
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .help(tr("全部取消暂存", "Unstage All"))
                    .disabled(vm.stagedChanges.isEmpty)
                }
            }

            Section {
                changeRows(vm.unstagedChanges, area: .unstaged)
            } header: {
                sectionHeader(tr("更改", "Changes"), count: vm.unstagedChanges.count) {
                    HStack(spacing: 6) {
                        Button {
                            vm.stashAll()
                        } label: {
                            Image(systemName: "archivebox")
                        }
                        .buttonStyle(.plain)
                        .help(tr("贮藏全部更改", "Stash All Changes"))
                        .disabled(vm.unstagedChanges.isEmpty && vm.stagedChanges.isEmpty)

                        Button {
                            vm.stageAll()
                        } label: {
                            Image(systemName: "plus.circle")
                        }
                        .buttonStyle(.plain)
                        .help(tr("全部暂存", "Stage All"))
                        .disabled(vm.unstagedChanges.isEmpty)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if vm.changes.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.quaternary)
                    Text(tr("没有更改", "No changes"))
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Spacer()
                Button {
                    settings.changesAsTree.toggle()
                } label: {
                    Image(systemName: settings.changesAsTree ? "list.bullet" : "list.bullet.indent")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(settings.changesAsTree
                      ? tr("切换为扁平列表", "Switch to flat list")
                      : tr("切换为树状视图", "Switch to tree view"))
                .padding(6)
            }
            .background(.bar)
        }
        .confirmationDialog(
            discardTitle,
            isPresented: Binding(
                get: { vm.pendingDiscard != nil },
                set: { if !$0 { vm.pendingDiscard = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(discardButtonTitle, role: .destructive) {
                vm.confirmDiscard()
            }
        } message: {
            Text(tr("此操作不可撤销。", "This action cannot be undone."))
        }
    }

    private var discardTitle: String {
        guard let change = vm.pendingDiscard else { return "" }
        return change.unstaged == .untracked
            ? tr("删除未跟踪文件「\(change.fileName)」？", "Delete untracked file “\(change.fileName)”?")
            : tr("丢弃「\(change.fileName)」的更改？", "Discard changes in “\(change.fileName)”?")
    }

    private var discardButtonTitle: String {
        vm.pendingDiscard?.unstaged == .untracked
            ? tr("删除文件", "Delete File")
            : tr("丢弃更改", "Discard Changes")
    }

    // MARK: - 分区内容

    @ViewBuilder
    private func changeRows(_ changes: [FileChange], area: ChangeArea) -> some View {
        if settings.changesAsTree {
            let lookup = Dictionary(uniqueKeysWithValues: changes.map { ($0.path, $0) })
            ForEach(Self.flattenTree(FileTreeBuilder.build(paths: changes.map(\.path)))) { item in
                if item.node.isDirectory {
                    HStack(spacing: 5) {
                        FileIconView(fileName: item.node.name, isDirectory: true, expanded: true)
                        Text(item.displayName)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, CGFloat(item.depth) * 14)
                } else if let change = lookup[item.node.path] {
                    ChangeRow(change: change, area: area, showDirectory: false)
                        .padding(.leading, CGFloat(item.depth) * 14)
                        .tag(SidebarSelection.change(path: change.path, area: area))
                }
            }
        } else {
            ForEach(changes) { change in
                ChangeRow(change: change, area: area, showDirectory: true)
                    .tag(SidebarSelection.change(path: change.path, area: area))
            }
        }
    }

    /// 变更树始终全展开（与 VS Code 一致），并把单子目录链合并为一行（a/b/c）。
    private struct TreeRowItem: Identifiable {
        let node: FileNode
        let depth: Int
        let displayName: String
        var id: String { node.id }
    }

    private static func flattenTree(_ nodes: [FileNode], depth: Int = 0) -> [TreeRowItem] {
        var result: [TreeRowItem] = []
        for node in nodes {
            if node.isDirectory {
                // 合并只有一个子目录的链
                var merged = node
                var name = node.name
                while let children = merged.children,
                      children.count == 1,
                      let only = children.first,
                      only.isDirectory {
                    merged = only
                    name += "/" + only.name
                }
                result.append(TreeRowItem(node: merged, depth: depth, displayName: name))
                result += flattenTree(merged.children ?? [], depth: depth + 1)
            } else {
                result.append(TreeRowItem(node: node, depth: depth, displayName: node.name))
            }
        }
        return result
    }

    private func sectionHeader<Actions: View>(
        _ title: String,
        count: Int,
        systemImage: String? = nil,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
            Text(title)
            Text("\(count)")
                .font(.caption2.monospacedDigit())
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(.quaternary))
            Spacer()
            actions()
        }
    }
}

/// 单个变更行：图标 + 文件名 + 路径 + 悬停操作 + 状态徽标。
struct ChangeRow: View {
    @EnvironmentObject var vm: RepoViewModel
    let change: FileChange
    let area: ChangeArea
    let showDirectory: Bool

    @State private var hovering = false

    private var kind: ChangeKind? {
        area == .staged ? change.staged : change.unstaged
    }

    var body: some View {
        HStack(spacing: 5) {
            FileIconView(fileName: change.fileName)

            Text(change.fileName)
                .lineLimit(1)
                .strikethrough(kind == .deleted)

            if showDirectory, !change.directory.isEmpty {
                Text(change.directory)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            if hovering {
                hoverActions
            }

            if let kind {
                Text(kind.badge)
                    .font(.caption.weight(.semibold).monospaced())
                    .foregroundStyle(kind.color)
                    .help(kind.localizedName)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { contextMenu }
        .help(change.oldPath.map { "\($0) → \(change.path)" } ?? change.path)
    }

    @ViewBuilder
    private var hoverActions: some View {
        HStack(spacing: 4) {
            switch area {
            case .unstaged:
                Button {
                    vm.requestDiscard(change)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.plain)
                .help(tr("丢弃更改", "Discard Changes"))

                Button {
                    vm.stageFile(change.path)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .help(tr("暂存", "Stage"))
            case .staged:
                Button {
                    vm.unstageFile(change.path)
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.plain)
                .help(tr("取消暂存", "Unstage"))
            case .conflicted:
                Button {
                    vm.stageFile(change.path)
                } label: {
                    Image(systemName: "checkmark")
                }
                .buttonStyle(.plain)
                .help(tr("标记为已解决", "Mark as Resolved"))
            }
        }
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var contextMenu: some View {
        switch area {
        case .unstaged:
            Button(tr("暂存", "Stage")) { vm.stageFile(change.path) }
            Button(tr("贮藏此文件", "Stash This File")) { vm.stashFile(change.path) }
            Divider()
            Button(change.unstaged == .untracked ? tr("删除文件…", "Delete File…") : tr("丢弃更改…", "Discard Changes…"),
                   role: .destructive) {
                vm.requestDiscard(change)
            }
        case .staged:
            Button(tr("取消暂存", "Unstage")) { vm.unstageFile(change.path) }
        case .conflicted:
            Button(tr("标记为已解决", "Mark as Resolved")) { vm.stageFile(change.path) }
        }
        Divider()
        Button(tr("在 Finder 中显示", "Reveal in Finder")) { vm.revealInFinder(change.path) }
        Button(tr("复制路径", "Copy Path")) { vm.copyPath(change.path) }
    }
}
