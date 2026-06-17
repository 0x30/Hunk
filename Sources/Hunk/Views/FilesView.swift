import SwiftUI
import HunkCore

/// 「文件」标签页：工作区文件树。
/// 键盘：↑↓ 移动选择，← 折叠目录/跳到父目录，→ 展开目录/进入第一个子项，⏎ 切换目录展开。
struct FilesView: View {
    @EnvironmentObject var vm: RepoViewModel
    @State private var localSelection: String?
    /// 启动宽限期：窗口状态恢复会触发 selection 变化，期间不自动打开文件
    @State private var suppressAutoOpen = true
    @FocusState private var focused: Bool

    private struct Row: Identifiable {
        let node: FileNode
        let depth: Int
        var id: String { node.path }
    }

    /// 诊断：body 每次求值都会重算 rows（重新 flatten 整棵展开的树）。
    /// 用节流计数确认暴涨期是否在被高频重算 + 当前行数规模。
    private static var rowsEvalCount = 0

    private var rows: [Row] {
        let r = flatten(vm.workspaceTree, depth: 0)
        Self.rowsEvalCount += 1
        if Self.rowsEvalCount % 100 == 0 {
            Diagnostics.log("FilesView.rows 第\(Self.rowsEvalCount)次求值 行数=\(r.count)")
        }
        return r
    }

    private func flatten(_ nodes: [FileNode], depth: Int) -> [Row] {
        var result: [Row] = []
        for node in nodes {
            result.append(Row(node: node, depth: depth))
            if node.isDirectory, vm.fileTreeExpanded.contains(node.path) {
                result += flatten(node.children ?? [], depth: depth + 1)
            }
        }
        return result
    }

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: $localSelection) {
                ForEach(rows) { row in
                    FileTreeRow(
                        node: row.node,
                        depth: row.depth,
                        isExpanded: vm.fileTreeExpanded.contains(row.node.path),
                        toggle: { toggle(row.node) },
                        select: {
                            // onTapGesture 会吞掉 List 的选中事件，手动同步选中态
                            localSelection = row.node.path
                            if !row.node.isDirectory {
                                vm.selection = .file(path: row.node.path)
                            }
                        }
                    )
                    .tag(row.node.path)
                    .id(row.node.path)
                }
            }
            .onChange(of: vm.revealFileRequest) { _, request in
                guard let request else { return }
                // 展开祖先目录并定位文件
                var ancestor = (request as NSString).deletingLastPathComponent
                while !ancestor.isEmpty {
                    vm.fileTreeExpanded.insert(ancestor)
                    ancestor = (ancestor as NSString).deletingLastPathComponent
                }
                localSelection = request
                DispatchQueue.main.async {
                    proxy.scrollTo(request, anchor: .center)
                    vm.revealFileRequest = nil
                }
            }
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, 24)
        // 空白区域右键：在仓库根目录新建
        .contextMenu {
            Button(tr("新建文件…", "New File…")) {
                vm.promptNewFile()
            }
        }
        .focused($focused)
        // 键盘 ↑↓ 移动选择后立即打开文件（无需再按 ⏎）
        .onChange(of: localSelection) { _, selected in
            guard !suppressAutoOpen,
                  let selected,
                  let row = rows.first(where: { $0.id == selected }),
                  !row.node.isDirectory
            else { return }
            vm.selection = .file(path: selected)
        }
        .onAppear {
            focused = true
            initialExpandIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                suppressAutoOpen = false
            }
            // 切回文件标签时若有待定位请求，立即处理
            if let request = vm.revealFileRequest {
                vm.revealFileRequest = nil
                DispatchQueue.main.async { vm.revealFileRequest = request }
            }
        }
        .onChange(of: vm.workspaceFiles) { _, _ in
            initialExpandIfNeeded()
        }
        .onKeyPress(.leftArrow) { handleLeft() }
        .onKeyPress(.rightArrow) { handleRight() }
        .onKeyPress(.return) { handleReturn() }
        .overlay {
            if vm.workspaceTree.isEmpty {
                Text(tr("空仓库", "Empty repository"))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 树数据首次就绪时展开第一层目录。
    private func initialExpandIfNeeded() {
        guard !vm.fileTreeDidInitialExpand, !vm.workspaceTree.isEmpty else { return }
        vm.fileTreeDidInitialExpand = true
        vm.fileTreeExpanded.formUnion(vm.workspaceTree.filter(\.isDirectory).map(\.path))
    }

    private func toggle(_ node: FileNode) {
        guard node.isDirectory else { return }
        if vm.fileTreeExpanded.contains(node.path) {
            vm.fileTreeExpanded.remove(node.path)
        } else {
            vm.fileTreeExpanded.insert(node.path)
        }
    }

    private var selectedRow: Row? {
        guard let selected = localSelection else { return nil }
        return rows.first { $0.id == selected }
    }

    private func handleLeft() -> KeyPress.Result {
        guard let row = selectedRow else { return .ignored }
        if row.node.isDirectory, vm.fileTreeExpanded.contains(row.node.path) {
            vm.fileTreeExpanded.remove(row.node.path)
            return .handled
        }
        // 跳到父目录
        let parent = (row.node.path as NSString).deletingLastPathComponent
        if !parent.isEmpty, rows.contains(where: { $0.id == parent }) {
            localSelection = parent
            return .handled
        }
        return .ignored
    }

    private func handleRight() -> KeyPress.Result {
        guard let row = selectedRow, row.node.isDirectory else { return .ignored }
        if !vm.fileTreeExpanded.contains(row.node.path) {
            vm.fileTreeExpanded.insert(row.node.path)
        } else if let firstChild = row.node.children?.first {
            localSelection = firstChild.path
        }
        return .handled
    }

    private func handleReturn() -> KeyPress.Result {
        guard let row = selectedRow else { return .ignored }
        if row.node.isDirectory {
            toggle(row.node)
        } else {
            vm.selection = .file(path: row.node.path)
        }
        return .handled
    }
}

private struct FileTreeRow: View {
    @EnvironmentObject var vm: RepoViewModel
    let node: FileNode
    let depth: Int
    let isExpanded: Bool
    let toggle: () -> Void
    let select: () -> Void

    private var change: FileChange? {
        vm.changes.first { $0.path == node.path }
    }

    /// 总览模式下：该目录若是扫描到的子仓库，返回其绝对 URL（用于角标 + 右键「作为仓库打开」）。
    private var repoURL: URL? {
        node.isDirectory ? vm.discoveredRepoURL(forTreePath: node.path) : nil
    }

    var body: some View {
        HStack(spacing: 4) {
            // 展开箭头（目录）/ 占位（文件）
            Group {
                if node.isDirectory {
                    Button(action: toggle) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear
                }
            }
            .frame(width: 12)

            FileIconView(fileName: node.name, isDirectory: node.isDirectory, expanded: isExpanded)

            Text(node.name)
                .lineLimit(1)

            // 子仓库角标：总览模式下标出这个目录是个 git 仓库
            if repoURL != nil {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .help(tr("git 仓库 · 右键作为仓库打开", "git repository · right-click to open as repo"))
            }

            Spacer(minLength: 4)

            if let kind = change?.unstaged ?? change?.staged {
                Text(kind.badge)
                    .font(.caption.weight(.semibold).monospaced())
                    .foregroundStyle(kind.color)
                    .help(kind.localizedName)
            }
        }
        .padding(.vertical, 1)
        .padding(.leading, CGFloat(depth) * 14)
        .contentShape(Rectangle())
        .onTapGesture {
            // 单击：选中 + 目录切换展开 / 文件打开
            select()
            if node.isDirectory {
                toggle()
            }
        }
        .contextMenu {
            // 总览模式下，子仓库目录可一键作为仓库打开（切换激活仓库）
            if let repoURL {
                Button(tr("作为仓库打开", "Open as Repository")) {
                    Task { await vm.selectRepo(repoURL) }
                }
                Divider()
            }
            Button(tr("新建文件…", "New File…")) {
                vm.promptNewFile(in: node.isDirectory
                                 ? node.path
                                 : (node.path as NSString).deletingLastPathComponent)
            }
            Divider()
            if let change {
                Button(tr("查看更改", "View Changes")) {
                    vm.sidebarTab = .changes
                    let area: ChangeArea = change.isConflicted
                        ? .conflicted
                        : (change.unstaged != nil ? .unstaged : .staged)
                    vm.selection = .change(path: change.path, area: area)
                }
                Divider()
            }
            if !node.isDirectory {
                Button(tr("查看文件历史", "View File History")) { vm.showFileHistory(node.path) }
                Divider()
            }
            Button(tr("在 Finder 中显示", "Reveal in Finder")) { vm.revealInFinder(node.path) }
            Button(tr("复制路径", "Copy Path")) { vm.copyPath(node.path) }
        }
    }
}
