import SwiftUI
import HunkCore

/// 「源代码管理」标签页：合并更改 / 已暂存 / 更改 三个分区，
/// 文件列表风格(平铺 / 完全展开树 / 合并路径树)读全局 settings.fileTreeStyle。
struct ChangesListView: View {
    @EnvironmentObject var vm: RepoViewModel
    @EnvironmentObject var settings: SettingsStore
    /// 已折叠的目录（按分区记，键为 "区|路径"，同一目录在已暂存/更改里互不影响）
    @State private var collapsedDirs: Set<String> = []
    @State private var renderedRows: [ChangeArea: [ChangeListItem]] = [:]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                if !vm.conflictedChanges.isEmpty {
                    Section {
                        if !isCollapsed("conflicted") {
                            changeRows(area: .conflicted)
                        }
                    } header: {
                        sectionHeader(
                            tr("合并更改", "Merge Changes"),
                            count: vm.conflictedChanges.count,
                            collapseKey: "conflicted",
                            systemImage: "exclamationmark.triangle"
                        ) { EmptyView() }
                    }
                }

                Section {
                    if !isCollapsed("staged") {
                        changeRows(area: .staged)
                    }
                } header: {
                    sectionHeader(tr("已暂存的更改", "Staged Changes"), count: vm.stagedChanges.count, collapseKey: "staged") {
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
                    if !isCollapsed("unstaged") {
                        changeRows(area: .unstaged)
                    }
                } header: {
                    sectionHeader(tr("更改", "Changes"), count: vm.unstagedChanges.count, collapseKey: "unstaged") {
                        HStack(spacing: 6) {
                            Menu {
                                Picker(tr("文件列表风格", "File list style"), selection: $settings.fileTreeStyle) {
                                    ForEach(FileTreeStyle.allCases) { style in
                                        Text(style.displayName).tag(style)
                                    }
                                }
                                .pickerStyle(.inline)
                                .labelsHidden()
                            } label: {
                                Image(systemName: settings.fileTreeStyle == .flat ? "list.bullet" : "list.bullet.indent")
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .help(tr("文件列表风格", "File list style"))

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
                        if !isCollapsed("stash") {
                            ForEach(vm.stashes) { stash in
                                StashRow(stash: stash)
                                    .virtualizedSidebarRow()
                            }
                        }
                    } header: {
                        sectionHeader(tr("贮藏", "Stashes"), count: vm.stashes.count, collapseKey: "stash") { EmptyView() }
                    }
                }

                if !vm.worktrees.isEmpty {
                    Section {
                        if !isCollapsed("worktree") {
                            ForEach(vm.worktrees) { wt in
                                WorktreeRow(worktree: wt)
                                    .virtualizedSidebarRow()
                            }
                        }
                    } header: {
                        sectionHeader(tr("工作树", "Worktrees"), count: vm.worktrees.count, collapseKey: "worktree") {
                            Button {
                                vm.showCreateWorktree = true
                            } label: {
                                Image(systemName: "plus")
                            }
                            .buttonStyle(.plain)
                            .help(tr("新建工作树…", "New Worktree…"))
                        }
                    }
                }

                // 标签区块始终显示，保证「新建标签」入口在没有标签时也可达
                Section {
                    if !isCollapsed("tag") {
                        ForEach(vm.tags) { tag in
                            TagRow(tag: tag)
                                .virtualizedSidebarRow()
                        }
                    }
                } header: {
                    sectionHeader(tr("标签", "Tags"), count: vm.tags.count, collapseKey: "tag") {
                        Button {
                            vm.showCreateTag = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.plain)
                        .help(tr("新建标签…", "New Tag…"))
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { rebuildRenderedRows() }
        .onChange(of: vm.changes) { _, _ in rebuildRenderedRows() }
        .onChange(of: settings.fileTreeStyle) { _, _ in rebuildRenderedRows() }
        .onChange(of: collapsedDirs) { _, _ in rebuildRenderedRows() }
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
        .confirmationDialog(
            tr("丢弃目录「\(vm.pendingDiscardDir.map { ($0 as NSString).lastPathComponent } ?? "")」的全部更改？",
               "Discard all changes in “\(vm.pendingDiscardDir.map { ($0 as NSString).lastPathComponent } ?? "")”?"),
            isPresented: Binding(
                get: { vm.pendingDiscardDir != nil },
                set: { if !$0 { vm.pendingDiscardDir = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(tr("丢弃全部", "Discard All"), role: .destructive) {
                vm.confirmDiscardDirectory()
            }
        } message: {
            Text(tr("该目录下所有未暂存的更改将被丢弃，此操作不可撤销。",
                    "All unstaged changes in this folder will be discarded. This cannot be undone."))
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
    private func changeRows(area: ChangeArea) -> some View {
        ForEach(renderedRows[area] ?? []) { item in
            switch item {
            case .directory(let row):
                let dirKey = "\(area)|\(row.node.path)"
                DirectoryRow(item: row, area: area, collapsed: collapsedDirs.contains(dirKey)) {
                    if collapsedDirs.contains(dirKey) { collapsedDirs.remove(dirKey) }
                    else { collapsedDirs.insert(dirKey) }
                }
                .virtualizedSidebarRow()
            case .file(let change, let depth, let showDirectory):
                let selection = SidebarSelection.change(path: change.path, area: area)
                ChangeRow(change: change, area: area, showDirectory: showDirectory)
                    .padding(.leading, CGFloat(depth) * 14)
                    .virtualizedSidebarRow(selected: vm.selection == selection)
                    .onTapGesture {
                        vm.selection = selection
                    }
                    .id(item.id)
            }
        }
    }

    private func rebuildRenderedRows() {
        renderedRows[.conflicted] = buildChangeListItems(vm.conflictedChanges, area: .conflicted)
        renderedRows[.staged] = buildChangeListItems(vm.stagedChanges, area: .staged)
        renderedRows[.unstaged] = buildChangeListItems(vm.unstagedChanges, area: .unstaged)
    }

    private func buildChangeListItems(_ changes: [FileChange], area: ChangeArea) -> [ChangeListItem] {
        if settings.fileTreeStyle == .flat {
            return changes.map { .file($0, depth: 0, showDirectory: true) }
        }

        let lookup = Dictionary(changes.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let collapsedInArea = Set(collapsedDirs.compactMap { key -> String? in
            let prefix = "\(area)|"
            return key.hasPrefix(prefix) ? String(key.dropFirst(prefix.count)) : nil
        })
        let tree = FileTreeBuilder.build(paths: changes.map(\.path))
        let rows = settings.fileTreeStyle == .fullTree
            ? FileTreeBuilder.flattenFullTree(tree, collapsed: collapsedInArea)
            : FileTreeBuilder.flattenMergingChains(tree, collapsed: collapsedInArea)

        return rows.compactMap { item in
            if item.node.isDirectory {
                return .directory(item)
            }
            guard let change = lookup[item.node.path] else { return nil }
            return .file(change, depth: item.depth, showDirectory: false)
        }
    }

    private func isCollapsed(_ key: String) -> Bool {
        settings.collapsedChangeSections.contains(key)
    }

    private func toggleSection(_ key: String) {
        withAnimation(.easeOut(duration: 0.15)) {
            if settings.collapsedChangeSections.contains(key) {
                settings.collapsedChangeSections.remove(key)
            } else {
                settings.collapsedChangeSections.insert(key)
            }
        }
    }

    private func sectionHeader<Actions: View>(
        _ title: String,
        count: Int,
        collapseKey: String,
        systemImage: String? = nil,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        let collapsed = isCollapsed(collapseKey)
        return HStack(spacing: 5) {
            // 折叠箭头 + 图标 + 标题 + 计数：整块可点，点击收起/展开该分区
            Button {
                toggleSection(collapseKey)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
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
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            actions()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
        .padding(.trailing, 8)  // 操作按钮与侧边栏右缘留距
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private enum ChangeListItem: Identifiable {
    case directory(FlatTreeRow)
    case file(FileChange, depth: Int, showDirectory: Bool)

    var id: String {
        switch self {
        case .directory(let item):
            return "dir:\(item.node.path)"
        case .file(let change, _, _):
            return "file:\(change.path)"
        }
    }
}

/// 目录行：点击折叠/展开该分区子树；悬停时对整个目录批量操作。
/// 在带 selection 的 List 里必须用 .borderless 按钮，onTapGesture 会被选中机制吞掉。
private struct DirectoryRow: View {
    @EnvironmentObject var vm: RepoViewModel
    let item: FlatTreeRow
    let area: ChangeArea
    let collapsed: Bool
    let onToggle: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onToggle) {
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
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            Spacer(minLength: 4)
            if hovering { hoverActions }
        }
        .padding(.vertical, 1)
        .padding(.leading, CGFloat(item.depth) * 14)
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var hoverActions: some View {
        HStack(spacing: 4) {
            switch area {
            case .unstaged:
                Button { vm.requestDiscardDirectory(item.node.path) } label: {
                    Image(systemName: "arrow.uturn.backward").contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(tr("丢弃此目录的全部更改", "Discard all changes in folder"))
                Button { vm.stageDirectory(item.node.path) } label: {
                    Image(systemName: "plus").contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(tr("暂存此目录", "Stage folder"))
            case .staged:
                Button { vm.unstageDirectory(item.node.path) } label: {
                    Image(systemName: "minus").contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(tr("取消暂存此目录", "Unstage folder"))
            case .conflicted:
                EmptyView()
            case .head:
                EmptyView()  // 「文件」栏只读视角,不进源代码管理列表
            }
        }
        .foregroundStyle(.secondary)
        .padding(.trailing, 4)
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
            case .head:
                EmptyView()  // 「文件」栏只读视角,不进源代码管理列表
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
        case .head:
            EmptyView()  // 「文件」栏只读视角,不进源代码管理列表
        }
        Divider()
        Button(tr("在文件列表中显示", "Reveal in Files")) { vm.revealInFiles(change.path) }
        Button(tr("查看文件历史", "View File History")) { vm.showFileHistory(change.path) }
        Divider()
        Button(tr("在 Finder 中显示", "Reveal in Finder")) { vm.revealInFinder(change.path) }
        Button(tr("复制路径", "Copy Path")) { vm.copyPath(change.path) }
    }
}
