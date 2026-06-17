import SwiftUI
import HunkCore

/// 更改详情：文件头 + diff 内容（统一 / 分栏），支持行级暂存。
/// 行选择方式：点击行选中（⌘+点击切换单行）；⇧+点击或 ⇧↑↓ 做范围扩选；⌘A 全选。
struct DiffDetailView: View {
    @EnvironmentObject var vm: RepoViewModel
    @EnvironmentObject var settings: SettingsStore
    let path: String

    private var change: FileChange? {
        vm.changes.first { $0.path == path }
    }

    private var isUntracked: Bool {
        vm.diffArea == .unstaged && change?.unstaged == .untracked
    }

    /// 行级暂存对未跟踪文件不可用（git 语义如此）
    private var supportsLineStaging: Bool {
        !isUntracked && !(vm.diff?.isBinary ?? true)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if supportsLineStaging {
                selectionBar
            }
            Divider()
            content
        }
        .background(Color(nsColor: .textBackgroundColor))
        .confirmationDialog(
            tr("撤销此块的更改？", "Discard this hunk?"),
            isPresented: Binding(
                get: { vm.pendingDiscardHunk != nil },
                set: { if !$0 { vm.pendingDiscardHunk = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(tr("撤销更改", "Discard Changes"), role: .destructive) {
                vm.confirmDiscardHunk()
            }
        } message: {
            Text(tr("该块的工作区修改将被恢复，此操作不可撤销。", "Worktree changes in this hunk will be reverted. This cannot be undone."))
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 10) {
            FileIconView(fileName: (path as NSString).lastPathComponent)
            VStack(alignment: .leading, spacing: 1) {
                Text((path as NSString).lastPathComponent)
                    .font(.system(size: 13, weight: .medium))
                HStack(spacing: 6) {
                    if let old = vm.diff?.oldPath, vm.diff?.isRename == true {
                        Text("\(old) →")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(path)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if let diff = vm.diff, !diff.isBinary {
                HStack(spacing: 4) {
                    statChip("+\(diff.additions)", color: .green)
                    statChip("-\(diff.deletions)", color: .red)
                }
            }

            Spacer()

            HStack(spacing: 2) {
                if vm.diffArea == .staged {
                    headerIconButton("minus.circle", help: tr("取消暂存文件", "Unstage File")) {
                        vm.unstageFile(path)
                    }
                } else {
                    headerIconButton("plus.circle", help: tr("暂存文件", "Stage File")) {
                        vm.stageFile(path)
                    }
                    if change?.unstaged != .deleted {
                        headerIconButton("pencil", help: tr("编辑文件", "Edit File")) {
                            // 统一标签系统:编辑 = 打开并激活该文件的编辑器标签(与 diff 标签并存)
                            vm.openEditor(path: path)
                            vm.selectTab(path)
                        }
                    }
                }

                Divider()
                    .frame(height: 14)
                    .padding(.horizontal, 5)

                Picker("", selection: $settings.splitDiff) {
                    Image(systemName: "square.fill.text.grid.1x2")
                        .tag(false)
                        .help(tr("统一视图", "Unified view"))
                    Image(systemName: "rectangle.split.2x1")
                        .tag(true)
                        .help(tr("左右分栏", "Side-by-side"))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
    }

    private func statChip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.monospacedDigit().weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.12)))
    }

    private func headerIconButton(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    /// 行级暂存操作条：一直显示，未选行时置灰禁用（不再随选择突然出现/消失）。
    private var selectionBar: some View {
        let hasSelection = !vm.selectedLineIDs.isEmpty
        return HStack(spacing: 12) {
            Label(
                hasSelection
                    ? tr("已选 \(vm.selectedLineIDs.count) 行", "\(vm.selectedLineIDs.count) line(s) selected")
                    : tr("未选择行", "No lines selected"),
                systemImage: hasSelection ? "checkmark.square.fill" : "square.dashed"
            )
            .font(.callout)
            .foregroundStyle(hasSelection ? Color.accentColor : Color.secondary)

            Button {
                if vm.diffArea == .staged {
                    vm.unstageSelectedLines()
                } else {
                    vm.stageSelectedLines()
                }
            } label: {
                Text(vm.diffArea == .staged ? tr("取消暂存这些行", "Unstage These Lines") : tr("暂存这些行", "Stage These Lines"))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!hasSelection)

            Button(tr("清除选择", "Clear Selection")) {
                vm.selectedLineIDs = []
            }
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(.secondary)
            .disabled(!hasSelection)

            Spacer()

            Text(settings.splitDiff
                 ? tr("⇧点击/⇧↑↓ 扩选 · ⌘点击多选 · ⌘A 全选 · ⎋ 清除", "⇧-click/⇧↑↓ extend · ⌘-click multi · ⌘A all · ⎋ clear")
                 : tr("拖选行 · 双击选词 · ⌘C 复制 · ⌘A 全选", "Drag to select · double-click a word · ⌘C copy · ⌘A all"))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(hasSelection ? Color.accentColor.opacity(0.08) : Color(nsColor: .windowBackgroundColor).opacity(0.5))
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if let diff = vm.diff {
            if diff.isBinary {
                placeholder(symbol: "doc.zipper", text: tr("二进制文件，无法显示差异", "Binary file — diff not shown"))
            } else if diff.hunks.isEmpty {
                placeholder(symbol: "equal.circle", text: tr("没有内容差异（可能是权限或模式变更）", "No content changes (possibly mode change)"))
            } else if settings.splitDiff {
                // 分栏视图：两列只读 NSTextView，各自可选可复制，选区驱动行级暂存
                SplitDiffTextView(
                    diff: diff,
                    filePath: path,
                    fontSize: settings.editorFontSize - 1,
                    themeID: settings.themeID,
                    selectable: supportsLineStaging,
                    settings: settings,
                    onSelectChangedLines: { ids in
                        if supportsLineStaging { vm.selectedLineIDs = ids }
                    }
                )
            } else {
                // 统一视图：只读 NSTextView 编辑器——原生选择/复制/双击/拖选，选区驱动行级暂存
                DiffTextView(
                    diff: diff,
                    filePath: path,
                    fontSize: settings.editorFontSize - 1,
                    themeID: settings.themeID,
                    selectable: supportsLineStaging,
                    settings: settings,
                    onSelectChangedLines: { ids in
                        if supportsLineStaging { vm.selectedLineIDs = ids }
                    }
                )
            }
        } else {
            placeholder(symbol: "equal.circle", text: tr("没有差异", "No differences"))
        }
    }

    private func placeholder(symbol: String, text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.quaternary)
            Text(text)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 只读 diff（历史详情 / 比较）

struct ReadOnlyDiffView: View {
    @EnvironmentObject var settings: SettingsStore
    let diff: FileDiff

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                FileIconView(fileName: ((diff.path) as NSString).lastPathComponent)
                Text(diff.path)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 4) {
                    Text("+\(diff.additions)").foregroundStyle(.green)
                    Text("-\(diff.deletions)").foregroundStyle(.red)
                }
                .font(.caption.monospacedDigit().weight(.medium))
                Spacer()
                Picker("", selection: $settings.splitDiff) {
                    Image(systemName: "square.fill.text.grid.1x2").tag(false)
                    Image(systemName: "rectangle.split.2x1").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()

            if diff.isBinary {
                VStack(spacing: 10) {
                    Image(systemName: "doc.zipper")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(.quaternary)
                    Text(tr("二进制文件", "Binary file"))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if settings.splitDiff {
                SplitDiffTextView(
                    diff: diff, filePath: diff.path,
                    fontSize: settings.editorFontSize - 1,
                    themeID: settings.themeID,
                    selectable: false, settings: settings,
                    onSelectChangedLines: { _ in }
                )
            } else {
                DiffTextView(
                    diff: diff, filePath: diff.path,
                    fontSize: settings.editorFontSize - 1,
                    themeID: settings.themeID,
                    selectable: false, settings: settings,
                    onSelectChangedLines: { _ in }
                )
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}
