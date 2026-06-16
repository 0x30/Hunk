import SwiftUI
import HunkCore

/// 源代码管理底部的提交历史：全分支 graph，或单文件历史（过滤模式）。
struct HistoryPanel: View {
    @EnvironmentObject var vm: RepoViewModel

    private var collapsed: Bool { vm.historyPanelCollapsed }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        vm.historyPanelCollapsed.toggle()
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(collapsed ? 0 : 90))
                        Text(tr("历史", "History"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if let path = vm.historyFilterPath {
                    HStack(spacing: 3) {
                        Image(systemName: "doc")
                            .font(.system(size: 8))
                        Text((path as NSString).lastPathComponent)
                            .font(.system(size: 10))
                            .lineLimit(1)
                        Button {
                            vm.setHistoryFilter(nil)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 7, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .help(tr("清除文件过滤，显示全部历史", "Clear filter, show full history"))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    .foregroundStyle(Color.accentColor)
                }

                Spacer()

                // 远端同步：刷新 / 拉取(落后数) / 推送(领先数)
                HStack(spacing: 10) {
                    if let upstream = vm.sync.upstream {
                        Button {
                            vm.openHistoryDetail(.compare(base: upstream, target: "HEAD"))
                        } label: {
                            Image(systemName: "arrow.left.arrow.right")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.borderless)
                        .help(tr("比较 \(upstream) ↔ 本地分支", "Compare \(upstream) ↔ local branch"))
                    }

                    Button { vm.fetch() } label: {
                        syncIcon("arrow.triangle.2.circlepath", count: 0, loading: vm.syncingAction == "fetch")
                    }
                    .buttonStyle(.borderless)
                    .help(tr("抓取", "Fetch") + upstreamSuffix)
                    .disabled(vm.isSyncing)

                    if vm.sync.behind > 0 || vm.syncingAction == "pull" {
                        Button { vm.pull() } label: {
                            syncIcon("arrow.down", count: vm.sync.behind, loading: vm.syncingAction == "pull")
                        }
                        .buttonStyle(.borderless)
                        .help(tr("拉取", "Pull") + upstreamSuffix)
                        .disabled(vm.isSyncing)
                    }

                    // 有待推送，或分支还没有上游（首推自动 push -u 发布分支）
                    if vm.sync.ahead > 0 || vm.sync.upstream == nil || vm.syncingAction == "push" {
                        Button { vm.push() } label: {
                            syncIcon("arrow.up", count: vm.sync.ahead, loading: vm.syncingAction == "push")
                        }
                        .buttonStyle(.borderless)
                        .help(vm.sync.upstream == nil
                              ? tr("推送并发布分支（push -u origin）", "Push & publish branch (push -u origin)")
                              : tr("推送", "Push") + upstreamSuffix)
                        .disabled(vm.isSyncing)
                    }
                }
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)

            if !collapsed {
                Divider()
                historyList
            }
        }
        // 「文件变化」折叠时历史占满剩余空间，否则固定高度
        .frame(height: (!collapsed && !vm.changesPanelCollapsed) ? 230 : nil)
        .frame(maxHeight: (!collapsed && vm.changesPanelCollapsed) ? .infinity : nil)
    }

    private func syncIcon(_ systemImage: String, count: Int, loading: Bool = false) -> some View {
        HStack(spacing: 2) {
            if loading {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .medium))
            }
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
            }
        }
    }

    private var upstreamSuffix: String {
        vm.sync.upstream.map { " (\($0))" } ?? ""
    }

    private var historyList: some View {
        ScrollView {
            // spacing 0 + 固定行高：泳道线在行间无缝衔接
            LazyVStack(spacing: 0) {
                ForEach(Array(vm.history.enumerated()), id: \.element.id) { index, row in
                    HistoryRow(row: row, maxColumns: vm.historyMaxColumns)
                        .onAppear {
                            // 接近底部时预加载下一批
                            if index >= vm.history.count - 8 { vm.loadMoreHistory() }
                        }
                }
                if vm.isLoadingMoreHistory {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                } else if !vm.hasMoreHistory, !vm.history.isEmpty {
                    Text(tr("已到最早的提交", "Beginning of history"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
            }
        }
    }
}

/// 泳道图单元：贯穿线 / 汇入曲线 / 分出曲线 / 提交圆点。
private struct GraphCanvas: View {
    let row: GraphRow
    let maxColumns: Int

    static let palette: [Color] = [.blue, .purple, .teal, .orange, .pink, .green, .indigo, .red]
    private static let laneWidth: CGFloat = 9

    static func width(for columns: Int) -> CGFloat {
        CGFloat(min(max(columns, 1), 10)) * laneWidth + 2
    }

    var body: some View {
        Canvas { context, size in
            let height = size.height
            let midY = height / 2
            func x(_ column: Int) -> CGFloat { Self.laneWidth / 2 + CGFloat(column) * Self.laneWidth + 1 }
            func color(_ column: Int) -> Color { Self.palette[column % Self.palette.count] }
            func stroke(_ path: Path, _ column: Int) {
                context.stroke(path, with: .color(color(column)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            }

            for column in row.throughColumns {
                var path = Path()
                path.move(to: CGPoint(x: x(column), y: 0))
                path.addLine(to: CGPoint(x: x(column), y: height))
                stroke(path, column)
            }

            let dotX = x(row.column)
            if row.hasTopStub {
                var path = Path()
                path.move(to: CGPoint(x: dotX, y: 0))
                path.addLine(to: CGPoint(x: dotX, y: midY))
                stroke(path, row.column)
            }
            if row.hasBottomStub {
                var path = Path()
                path.move(to: CGPoint(x: dotX, y: midY))
                path.addLine(to: CGPoint(x: dotX, y: height))
                stroke(path, row.column)
            }
            for column in row.joinColumns {
                var path = Path()
                path.move(to: CGPoint(x: x(column), y: 0))
                path.addCurve(
                    to: CGPoint(x: dotX, y: midY),
                    control1: CGPoint(x: x(column), y: midY * 0.65),
                    control2: CGPoint(x: dotX, y: midY * 0.35)
                )
                stroke(path, column)
            }
            for column in row.forkColumns {
                var path = Path()
                path.move(to: CGPoint(x: dotX, y: midY))
                path.addCurve(
                    to: CGPoint(x: x(column), y: height),
                    control1: CGPoint(x: dotX, y: midY + (height - midY) * 0.35),
                    control2: CGPoint(x: x(column), y: midY + (height - midY) * 0.65)
                )
                stroke(path, column)
            }

            // 提交圆点
            let radius: CGFloat = 3.4
            let dotRect = CGRect(x: dotX - radius, y: midY - radius, width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: dotRect), with: .color(color(row.column)))
        }
        .frame(width: Self.width(for: maxColumns))
    }
}

private struct HistoryRow: View {
    @EnvironmentObject var vm: RepoViewModel
    let row: GraphRow
    let maxColumns: Int

    private var commit: GraphCommit { row.commit }

    /// 供历史详情/比较使用的 Commit 形态
    private var legacyCommit: Repository.Commit {
        Repository.Commit(
            hash: commit.hash,
            shortHash: commit.shortHash,
            author: commit.author,
            subject: commit.subject,
            date: commit.date,
            refs: commit.refs
        )
    }

    private var isActive: Bool {
        if case .commit(let current) = vm.historyDetail { return current.hash == commit.hash }
        return false
    }

    var body: some View {
        HStack(spacing: 6) {
            GraphCanvas(row: row, maxColumns: maxColumns)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    ForEach(commit.refs.prefix(3), id: \.self) { ref in
                        Text(shortRef(ref))
                            .font(.system(size: 8.5, weight: .semibold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 0.5)
                            .background(Capsule().fill(refColor(ref).opacity(0.18)))
                            .foregroundStyle(refColor(ref))
                            .lineLimit(1)
                    }
                    Text(commit.subject)
                        .font(.system(size: 11.5))
                        .lineLimit(1)
                }
                Text("\(commit.shortHash) · \(commit.author) · \(relative(commit.date))")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 6)
        .padding(.trailing, 4)
        .frame(height: 32)  // 固定行高，保证泳道线连续
        .background(isActive ? Color.accentColor.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            vm.openHistoryDetail(.commit(legacyCommit))
        }
        .contextMenu {
            Button(tr("查看此提交的更改", "View Changes in This Commit")) {
                vm.openHistoryDetail(.commit(legacyCommit))
            }
            Divider()
            Button(tr("与 HEAD 比较", "Compare with HEAD")) {
                vm.openHistoryDetail(.compare(base: commit.hash, target: "HEAD"))
            }
            if let upstream = vm.sync.upstream {
                Button(tr("与 \(upstream) 比较", "Compare with \(upstream)")) {
                    vm.openHistoryDetail(.compare(base: commit.hash, target: upstream))
                }
            }
            Divider()
            Button(tr("复制提交哈希", "Copy Commit Hash")) {
                vm.copyPath(commit.hash)
            }
        }
        .help("\(commit.subject)\n\(commit.author) · \(commit.hash)")
    }

    private func shortRef(_ ref: String) -> String {
        ref.replacingOccurrences(of: "HEAD -> ", with: "→ ")
            .replacingOccurrences(of: "tag: ", with: "🏷 ")
    }

    private func refColor(_ ref: String) -> Color {
        if ref.contains("HEAD") { return .accentColor }
        if ref.hasPrefix("tag:") { return .orange }
        if ref.contains("/") { return .purple }  // 远程分支
        return .green                            // 本地分支
    }

    private func relative(_ date: Date) -> String {
        relativeTime(date)
    }
}

// MARK: - 历史详情（提交内容 / 引用比较）

struct HistoryDetailView: View {
    @EnvironmentObject var vm: RepoViewModel
    /// 文件列表树状/扁平（默认树状，跨会话记忆）
    @AppStorage("historyFilesAsTree") private var filesAsTree = true
    /// 已折叠的目录路径（每次打开新详情时重置）
    @State private var collapsedDirs: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                fileList
                    .frame(width: 250)
                Divider()
                if let diff = vm.historyDiff {
                    ReadOnlyDiffView(diff: diff)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 32, weight: .light))
                            .foregroundStyle(.quaternary)
                        Text(tr("选择左侧文件查看差异", "Select a file to view its diff"))
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor))
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                vm.closeHistoryDetail()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help(tr("关闭", "Close"))

            switch vm.historyDetail {
            case .commit(let commit):
                Image(systemName: "circle.dotted")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(commit.subject)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text("\(commit.shortHash) · \(commit.author) · \(commit.date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(appLocale)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .compare(let base, let target):
                Image(systemName: "arrow.left.arrow.right")
                    .foregroundStyle(.secondary)
                Text("\(shortRef(base)) ↔ \(shortRef(target))")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            case nil:
                EmptyView()
            }

            Spacer()

            Text(tr("\(vm.historyFiles.count) 个文件", "\(vm.historyFiles.count) file(s)"))
                .font(.caption)
                .foregroundStyle(.secondary)

            // 文件列表树状/扁平切换
            Button {
                filesAsTree.toggle()
            } label: {
                Image(systemName: filesAsTree ? "list.bullet" : "list.bullet.indent")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(filesAsTree ? tr("平铺显示", "Flat list") : tr("树状显示", "Tree view"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func shortRef(_ ref: String) -> String {
        ref.count > 12 && ref.allSatisfy(\.isHexDigit) ? String(ref.prefix(8)) : ref
    }

    private var fileList: some View {
        List {
            if filesAsTree {
                let lookup = Dictionary(uniqueKeysWithValues: vm.historyFiles.map { ($0.path, $0) })
                ForEach(FileTreeBuilder.flattenMergingChains(
                    FileTreeBuilder.build(paths: vm.historyFiles.map(\.path)),
                    collapsed: collapsedDirs
                )) { item in
                    if item.node.isDirectory {
                        directoryRow(item)
                    } else if let file = lookup[item.node.path] {
                        fileRow(file, showDirectory: false)
                            .padding(.leading, CGFloat(item.depth) * 12)
                    }
                }
            } else {
                ForEach(vm.historyFiles) { file in
                    fileRow(file, showDirectory: true)
                }
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 26)
        // 切换提交/比较对象时重置折叠状态
        .onChange(of: vm.historyDetail) { _, _ in
            collapsedDirs = []
        }
    }

    /// 目录行：点击折叠/展开整个子树。
    private func directoryRow(_ item: FlatTreeRow) -> some View {
        let collapsed = collapsedDirs.contains(item.node.path)
        return HStack(spacing: 4) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(collapsed ? .zero : .degrees(90))
            FileIconView(fileName: item.node.name, isDirectory: true, expanded: !collapsed)
            Text(item.displayName)
                .font(.system(size: 12))
                .lineLimit(1)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 1)
        .padding(.leading, CGFloat(item.depth) * 12)
        .contentShape(Rectangle())
        .onTapGesture {
            if collapsed {
                collapsedDirs.remove(item.node.path)
            } else {
                collapsedDirs.insert(item.node.path)
            }
        }
    }

    @ViewBuilder
    private func fileRow(_ file: Repository.CommitFileChange, showDirectory: Bool) -> some View {
        HStack(spacing: 6) {
            FileIconView(fileName: (file.path as NSString).lastPathComponent)
            VStack(alignment: .leading, spacing: 0) {
                Text((file.path as NSString).lastPathComponent)
                    .font(.system(size: 12))
                    .lineLimit(1)
                if showDirectory {
                    Text((file.path as NSString).deletingLastPathComponent)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            Text(file.kind.badge)
                .font(.caption.weight(.semibold).monospaced())
                .foregroundStyle(file.kind.color)
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .listRowBackground(
            vm.historyDiffPath == file.path ? Color.accentColor.opacity(0.12) : Color.clear
        )
        .onTapGesture {
            vm.selectHistoryFile(file)
        }
    }
}
