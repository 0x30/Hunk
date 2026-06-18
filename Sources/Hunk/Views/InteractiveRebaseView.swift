import SwiftUI
import HunkCore

/// 交互式变基编排中的一行：一个提交 + 它的处理动作（可变）。
struct RebaseStep: Identifiable {
    let commit: Repository.Commit
    var action: RebaseAction
    var id: String { commit.hash }
}

/// 交互式变基 tab：上部提交编排（拖拽重排 + 动作），下部选中提交的详情（卡片 + 树形文件 + diff）。
struct RebaseDetailView: View {
    @EnvironmentObject var vm: RepoViewModel
    @EnvironmentObject var settings: SettingsStore
    @State private var selectedID: String?
    @State private var collapsedDirs: Set<String> = []

    private var firstKeptIsSquash: Bool {
        vm.rebaseSteps.first(where: { $0.action != .drop })?.action == .squash
    }
    private var canStart: Bool {
        !firstKeptIsSquash && vm.rebaseSteps.contains { $0.action != .drop }
    }
    private var keptCount: Int {
        vm.rebaseSteps.filter { $0.action == .pick }.count
    }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                editorPane
                    .frame(height: max(180, geo.size.height * 0.42))
                Divider()
                detailPane
                    .frame(maxHeight: .infinity)
            }
        }
        .onChange(of: vm.rebaseBase) { _, _ in selectedID = nil }
        .onChange(of: vm.rebaseDetailCommit?.hash) { _, _ in collapsedDirs = [] }
    }

    // MARK: 上部：编排

    private var editorPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(tr("整理提交（自上而下＝旧→新，拖拽可重排）",
                        "Reorganize (top = old, drag to reorder)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if firstKeptIsSquash {
                    Label(tr("首个提交不能合并", "First can’t squash"),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Text(tr("→ \(keptCount) 个提交", "→ \(keptCount) commit(s)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(tr("取消", "Cancel")) { vm.closeViewTab(.rebase) }
                    .controlSize(.small)
                Button(tr("开始变基", "Start Rebase")) { vm.runInteractiveRebase() }
                    .controlSize(.small)
                    .disabled(!canStart)
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()

            List(selection: $selectedID) {
                ForEach(vm.rebaseSteps) { step in
                    RebaseStepRow(step: step).tag(step.id)
                }
                .onMove { vm.moveRebaseStep(from: $0, to: $1) }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 32)
            .onChange(of: selectedID) { _, id in
                if let id, let step = vm.rebaseSteps.first(where: { $0.id == id }) {
                    vm.selectRebaseStep(step)
                }
            }
        }
    }

    // MARK: 下部：选中提交详情（提交卡片 + 树形文件列表 + diff）

    @ViewBuilder
    private var detailPane: some View {
        if vm.rebaseDetailCommit != nil {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    fileListHeader
                    Divider()
                    fileList
                }
                .frame(width: 230)
                Divider()
                if let diff = vm.rebaseDetailDiff {
                    ReadOnlyDiffView(diff: diff)
                } else {
                    detailHint("doc.text.magnifyingglass",
                               tr("选择左侧文件查看差异", "Select a file to view its diff"))
                }
            }
        } else {
            detailHint("rectangle.and.text.magnifyingglass",
                       tr("点上方某个提交，查看它改了什么", "Select a commit above to see its changes"))
        }
    }

    private var fileListHeader: some View {
        HStack(spacing: 6) {
            Text(tr("\(vm.rebaseDetailFiles.count) 个文件", "\(vm.rebaseDetailFiles.count) file(s)"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
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
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(tr("文件列表风格", "File list style"))
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var fileList: some View {
        List {
            if settings.fileTreeStyle == .flat {
                ForEach(vm.rebaseDetailFiles) { file in
                    fileRow(file, showDirectory: true)
                }
            } else {
                let lookup = Dictionary(uniqueKeysWithValues: vm.rebaseDetailFiles.map { ($0.path, $0) })
                let tree = FileTreeBuilder.build(paths: vm.rebaseDetailFiles.map(\.path))
                let rows = settings.fileTreeStyle == .fullTree
                    ? FileTreeBuilder.flattenFullTree(tree, collapsed: collapsedDirs)
                    : FileTreeBuilder.flattenMergingChains(tree, collapsed: collapsedDirs)
                ForEach(rows) { item in
                    if item.node.isDirectory {
                        directoryRow(item)
                    } else if let file = lookup[item.node.path] {
                        fileRow(file, showDirectory: false)
                            .padding(.leading, CGFloat(item.depth) * 12)
                    }
                }
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 24)
    }

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
            if collapsed { collapsedDirs.remove(item.node.path) }
            else { collapsedDirs.insert(item.node.path) }
        }
    }

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
            vm.rebaseDetailDiffPath == file.path ? Color.accentColor.opacity(0.12) : Color.clear
        )
        .onTapGesture {
            vm.selectRebaseDetailFile(file)
        }
        .contextMenu {
            Button(tr("复制路径", "Copy Path")) { vm.copyPath(file.path) }
        }
    }

    private func detailHint(_ symbol: String, _ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.quaternary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// 编排列表的一行：动作菜单 + 短 hash + 标题。选中高亮由 List(selection:) 负责。
private struct RebaseStepRow: View {
    @EnvironmentObject var vm: RepoViewModel
    let step: RebaseStep
    @State private var showCard = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            RebaseActionPicker(action: step.action) { vm.setRebaseAction($0, for: step.id) }
            Text(step.commit.shortHash)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
            Text(step.commit.subject)
                .font(.callout)
                .lineLimit(1)
                .strikethrough(step.action == .drop)
                .foregroundStyle(step.action == .drop ? .secondary : .primary)
            Spacer(minLength: 4)
            // 提交后面:点 ⓘ 悬浮查看提交详情卡片(不常驻、不占详情区)
            Button { showCard.toggle() } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(showCard ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(tr("查看提交详情", "Commit details"))
            .popover(isPresented: $showCard, arrowEdge: .trailing) {
                CommitCard(
                    hash: step.commit.hash,
                    fetch: { await vm.commitDetail(hash: $0) },
                    onViewCommit: { _ in },
                    showViewButton: false,
                    fixedWidth: 360
                )
                .frame(width: 360)
                .padding(.vertical, 4)
            }
        }
        .padding(.vertical, 2)
    }
}

/// 动作下拉：固定宽度（各行对齐）+ 小字 + 当前项带色（圆点 + 文字）+ 下拉箭头；点开三个选项。
private struct RebaseActionPicker: View {
    let action: RebaseAction
    let onChange: (RebaseAction) -> Void

    private func label(_ a: RebaseAction) -> String {
        switch a {
        case .pick: return tr("保留", "Pick")
        case .squash: return tr("合并", "Squash")
        case .drop: return tr("删除", "Drop")
        }
    }
    private func tint(_ a: RebaseAction) -> Color {
        switch a {
        case .pick: return .secondary
        case .squash: return .blue
        case .drop: return .red
        }
    }

    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 3) {
                Text(label(action))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(tint(action))
                    .frame(minWidth: 22)
                Image(systemName: "chevron.down")
                    .font(.system(size: 6, weight: .bold))
                    .foregroundStyle(tint(action).opacity(0.7))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint(action).opacity(0.16)))
            .overlay(Capsule().strokeBorder(tint(action).opacity(0.6), lineWidth: 0.75))
            .contentShape(Capsule())
        }
        .buttonStyle(.borderless)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(spacing: 0) {
                ForEach(RebaseAction.allCases, id: \.self) { a in
                    Button { onChange(a); open = false } label: {
                        HStack(spacing: 8) {
                            Image(systemName: a == action ? "checkmark" : "circle")
                                .font(.system(size: 9))
                                .foregroundStyle(a == action ? AnyShapeStyle(tint(a)) : AnyShapeStyle(.tertiary))
                                .frame(width: 12)
                            Circle().fill(tint(a)).frame(width: 6, height: 6)
                            Text(label(a)).font(.system(size: 12))
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .frame(width: 132, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 5)
        }
    }
}

/// 变基进行中（冲突中断）时的状态条：解决冲突后继续，或中止。
struct RebaseBanner: View {
    @EnvironmentObject var vm: RepoViewModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.orange)
                .font(.system(size: 12, weight: .semibold))
            Text(tr("变基进行中，解决冲突并暂存后点继续", "Rebase in progress — resolve conflicts, stage, then continue"))
                .font(.system(size: 11))
                .lineLimit(2)
            Spacer(minLength: 4)
            Button(tr("继续", "Continue")) { vm.continueRebase() }
                .controlSize(.small)
            Button(tr("中止", "Abort")) { vm.abortRebase() }
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
    }
}
