import SwiftUI
import HunkCore

/// 「源代码管理」标签页：合并更改 / 已暂存 / 更改 三个分区，
/// 支持树状与扁平两种展示。
struct ChangesListView: View {
    @EnvironmentObject var vm: RepoViewModel
    @EnvironmentObject var settings: SettingsStore
    /// 已折叠的目录（按分区记，键为 "区|路径"，同一目录在已暂存/更改里互不影响）
    @State private var collapsedDirs: Set<String> = []

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
                            settings.changesAsTree.toggle()
                        } label: {
                            Image(systemName: settings.changesAsTree ? "list.bullet" : "list.bullet.indent")
                        }
                        .buttonStyle(.plain)
                        .help(settings.changesAsTree
                              ? tr("切换为扁平列表", "Switch to flat list")
                              : tr("切换为树状视图", "Switch to tree view"))

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

            if !vm.stashes.isEmpty {
                Section {
                    ForEach(vm.stashes) { stash in
                        StashRow(stash: stash)
                    }
                } header: {
                    sectionHeader(tr("贮藏", "Stashes"), count: vm.stashes.count) { EmptyView() }
                }
            }
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, 24)
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
            let collapsedInArea = Set(collapsedDirs.compactMap { key -> String? in
                let prefix = "\(area)|"
                return key.hasPrefix(prefix) ? String(key.dropFirst(prefix.count)) : nil
            })
            ForEach(FileTreeBuilder.flattenMergingChains(
                FileTreeBuilder.build(paths: changes.map(\.path)),
                collapsed: collapsedInArea
            )) { item in
                if item.node.isDirectory {
                    directoryRow(item, area: area)
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

    /// 目录行：点击折叠/展开该分区下的整个子树。
    /// 注意：在带 selection 的 List 里 onTapGesture 会被选中机制吞掉，必须用 .borderless 按钮。
    private func directoryRow(_ item: FlatTreeRow, area: ChangeArea) -> some View {
        let key = "\(area)|\(item.node.path)"
        let collapsed = collapsedDirs.contains(key)
        return Button {
            if collapsed {
                collapsedDirs.remove(key)
            } else {
                collapsedDirs.insert(key)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(collapsed ? .zero : .degrees(90))
                FileIconView(fileName: item.node.name, isDirectory: true, expanded: !collapsed)
                Text(item.displayName)
                    .font(.callout)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.vertical, 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .padding(.leading, CGFloat(item.depth) * 14)
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
                    .font(.system(size: 10))
            }
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4.5)
                .padding(.vertical, 1)
                .background(Capsule().fill(.quaternary.opacity(0.6)))
            Spacer()
            actions()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
        .padding(.trailing, 8)  // 操作按钮与侧边栏右缘留距
    }
}

/// 贮藏行（应用 / 弹出 / 删除 via 右键菜单）。
private struct StashRow: View {
    @EnvironmentObject var vm: RepoViewModel
    let stash: Stash

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "archivebox")
                .foregroundStyle(.secondary)
                .font(.caption)
            VStack(alignment: .leading, spacing: 1) {
                Text(stash.message)
                    .lineLimit(1)
                    .font(.callout)
                Text(stash.ref)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .contextMenu {
            Button(tr("应用", "Apply")) { vm.applyStash(stash, pop: false) }
            Button(tr("弹出（应用并删除）", "Pop (Apply & Drop)")) { vm.applyStash(stash, pop: true) }
            Divider()
            Button(tr("删除", "Drop"), role: .destructive) { vm.dropStash(stash) }
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
        HStack(spacing: 6) {
            FileIconView(fileName: change.fileName)

            Text(change.fileName)
                .lineLimit(1)
                .strikethrough(kind == .deleted)
                .foregroundStyle(kind == .deleted ? .secondary : .primary)

            if showDirectory, !change.directory.isEmpty {
                Text(change.directory)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            // 徽标与悬停操作共用同一块区域，避免悬停时布局跳动
            ZStack(alignment: .trailing) {
                if let kind {
                    Text(kind.badge)
                        .font(.caption.weight(.semibold).monospaced())
                        .foregroundStyle(kind.color)
                        .help(kind.localizedName)
                        .opacity(hovering ? 0 : 1)
                }
                hoverActions
                    .opacity(hovering ? 1 : 0)
            }
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { contextMenu }
        .help(change.oldPath.map { "\($0) → \(change.path)" } ?? change.path)
    }

    @ViewBuilder
    private var hoverActions: some View {
        // 注意：可选中 List 行内的按钮必须用 .borderless，
        // .plain 的点击会被行选中吞掉
        HStack(spacing: 4) {
            switch area {
            case .unstaged:
                Button {
                    vm.requestDiscard(change)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(tr("丢弃更改", "Discard Changes"))

                Button {
                    vm.stageFile(change.path)
                } label: {
                    Image(systemName: "plus")
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(tr("暂存", "Stage"))
            case .staged:
                Button {
                    vm.unstageFile(change.path)
                } label: {
                    Image(systemName: "minus")
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(tr("取消暂存", "Unstage"))
            case .conflicted:
                Button {
                    vm.stageFile(change.path)
                } label: {
                    Image(systemName: "checkmark")
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
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
        Button(tr("在文件列表中显示", "Reveal in Files")) { vm.revealInFiles(change.path) }
        Button(tr("查看文件历史", "View File History")) { vm.showFileHistory(change.path) }
        Divider()
        Button(tr("在 Finder 中显示", "Reveal in Finder")) { vm.revealInFinder(change.path) }
        Button(tr("复制路径", "Copy Path")) { vm.copyPath(change.path) }
    }
}
