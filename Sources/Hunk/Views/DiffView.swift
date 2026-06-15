import SwiftUI
import HunkCore

/// 更改详情：文件头 + diff 内容（统一 / 分栏），支持行级暂存。
/// 行选择方式：点击行选中（⌘+点击切换单行）；⇧+点击或 ⇧↑↓ 做范围扩选；⌘A 全选。
struct DiffDetailView: View {
    @EnvironmentObject var vm: RepoViewModel
    @EnvironmentObject var settings: SettingsStore
    let path: String

    // 编辑器式行选择状态：锚点 + 光标（行序号），选区 = 两者之间
    @State private var anchorRow: Int?
    @State private var cursorRow: Int?
    @FocusState private var diffFocused: Bool
    // GitHub 式「展开未更改区域」
    @State private var expandedGaps: Set<Int> = []

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
            if supportsLineStaging, !vm.selectedLineIDs.isEmpty {
                selectionBar
            }
            Divider()
            content
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onChange(of: vm.diff) { _, _ in
            expandedGaps = []
            anchorRow = nil
            cursorRow = nil
        }
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
                            vm.editingChangedFile = true
                            vm.openEditor(path: path)
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

    /// 选中行后出现的操作条。
    private var selectionBar: some View {
        HStack(spacing: 12) {
            Label(
                tr("已选 \(vm.selectedLineIDs.count) 行", "\(vm.selectedLineIDs.count) line(s) selected"),
                systemImage: "checkmark.square.fill"
            )
            .font(.callout)
            .foregroundStyle(Color.accentColor)

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

            Button(tr("清除选择", "Clear Selection")) {
                vm.selectedLineIDs = []
            }
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(.secondary)

            Spacer()

            Text(tr("⇧点击/⇧↑↓ 扩选 · ⌘点击多选 · ⌘A 全选 · ⎋ 清除", "⇧-click/⇧↑↓ extend · ⌘-click multi · ⌘A all · ⎋ clear"))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.08))
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if let diff = vm.diff {
            if diff.isBinary {
                placeholder(symbol: "doc.zipper", text: tr("二进制文件，无法显示差异", "Binary file — diff not shown"))
            } else if diff.hunks.isEmpty {
                placeholder(symbol: "equal.circle", text: tr("没有内容差异（可能是权限或模式变更）", "No content changes (possibly mode change)"))
            } else {
                let gapTable = gaps(for: diff)
                let order = rowOrder
                let indexByKey = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element.key, $0.offset) })
                let range = visualRange
                ScrollViewReader { proxy in
                    ScrollView([.vertical]) {
                        LazyVStack(spacing: 0, pinnedViews: []) {
                            ForEach(Array(diff.hunks.enumerated()), id: \.element.id) { hunkIndex, hunk in
                                if let gap = gapTable[hunkIndex] {
                                    gapView(gap)
                                }
                                HunkHeaderRow(hunk: hunk, supportsStaging: supportsLineStaging, isUntracked: isUntracked)
                                if settings.splitDiff {
                                    ForEach(hunk.splitRows) { row in
                                        let key = "s-\(hunkIndex)-\(row.id)"
                                        SplitDiffRow(
                                            row: row, filePath: path, selectable: supportsLineStaging,
                                            inSelectionRange: indexByKey[key].map { range?.contains($0) ?? false } ?? false,
                                            onLineTap: handleLineTap
                                        )
                                        .id(key)
                                    }
                                } else {
                                    ForEach(hunk.lines) { line in
                                        let key = "u-\(line.id)"
                                        UnifiedDiffRow(
                                            line: line, filePath: path, selectable: supportsLineStaging,
                                            inSelectionRange: indexByKey[key].map { range?.contains($0) ?? false } ?? false,
                                            onLineTap: handleLineTap
                                        )
                                        .id(key)
                                    }
                                }
                            }
                            if let trailing = gapTable[diff.hunks.count] {
                                gapView(trailing)
                            }
                        }
                        // 文件或布局切换时整体重建，避免 LazyVStack 按旧 id 复用缓存行
                        .id("\(path)|\(settings.splitDiff ? "split" : "unified")")
                        .padding(.bottom, 20)
                    }
                    .focusable()
                    .focusEffectDisabled()
                    .focused($diffFocused)
                    .onKeyPress(keys: [.upArrow, .downArrow], phases: .down) { press in
                        moveCursor(press.key == .downArrow ? 1 : -1,
                                   extend: press.modifiers.contains(.shift),
                                   proxy: proxy)
                        return .handled
                    }
                    .onKeyPress(keys: [KeyEquivalent("a")], phases: .down) { press in
                        guard press.modifiers.contains(.command), supportsLineStaging else { return .ignored }
                        vm.selectedLineIDs = Set(diff.changedLineIDs)
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        guard !vm.selectedLineIDs.isEmpty else { return .ignored }
                        vm.selectedLineIDs = []
                        anchorRow = nil
                        cursorRow = nil
                        return .handled
                    }
                }
            }
        } else {
            placeholder(symbol: "equal.circle", text: tr("没有差异", "No differences"))
        }
    }

    // MARK: - 展开未更改区域（GitHub 式）

    /// 两个 hunk 之间（以及文件首尾）被 diff 省略的未更改区域。
    private struct Gap: Identifiable {
        let id: Int
        /// 新侧被隐藏的行号范围（1 基）。
        let newRange: ClosedRange<Int>
        /// 旧行号 = 新行号 + oldOffset。
        let oldOffset: Int
    }

    /// key：hunk 下标（该 hunk 之前的间隙）；`hunks.count` 表示文件末尾的间隙。
    private func gaps(for diff: FileDiff) -> [Int: Gap] {
        guard let lines = vm.diffNewSideLines, !diff.isNew else { return [:] }
        var result: [Int: Gap] = [:]
        var previousEndNew = 0
        var trailingOffset = 0
        for (index, hunk) in diff.hunks.enumerated() {
            let start = previousEndNew + 1
            let end = hunk.newStart - 1
            if start <= end {
                result[index] = Gap(id: index, newRange: start...end, oldOffset: hunk.oldStart - hunk.newStart)
            }
            previousEndNew = hunk.newStart + hunk.newCount - 1
            trailingOffset = (hunk.oldStart + hunk.oldCount) - (hunk.newStart + hunk.newCount)
        }
        if previousEndNew + 1 <= lines.count {
            result[diff.hunks.count] = Gap(
                id: diff.hunks.count,
                newRange: (previousEndNew + 1)...lines.count,
                oldOffset: trailingOffset
            )
        }
        return result
    }

    @ViewBuilder
    private func gapView(_ gap: Gap) -> some View {
        if expandedGaps.contains(gap.id) {
            let lines = vm.diffNewSideLines ?? []
            ForEach(Array(gap.newRange), id: \.self) { number in
                let line = DiffLine(
                    id: -(gap.id * 1_000_000 + number),  // 负数，与真实行 id 隔离
                    kind: .context,
                    text: number - 1 < lines.count ? lines[number - 1] : "",
                    oldNumber: number + gap.oldOffset,
                    newNumber: number
                )
                if settings.splitDiff {
                    SplitDiffRow(row: SplitRow(id: line.id, left: line, right: line), filePath: path, selectable: false)
                } else {
                    UnifiedDiffRow(line: line, filePath: path, selectable: supportsLineStaging)
                }
            }
        } else {
            ExpanderRow(count: gap.newRange.count) {
                Diagnostics.log("展开未更改区 gap=\(gap.id) 行数=\(gap.newRange.count)")
                expandedGaps.insert(gap.id)
            }
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

    // MARK: - 范围选择

    /// 行序表（按显示顺序），用于范围扩选与键盘移动。
    private struct SelectableRow {
        let key: String
        let lineIDs: [Int]
    }

    private var rowOrder: [SelectableRow] {
        guard let diff = vm.diff else { return [] }
        var rows: [SelectableRow] = []
        for (hunkIndex, hunk) in diff.hunks.enumerated() {
            if settings.splitDiff {
                for row in hunk.splitRows {
                    var ids: [Int] = []
                    if let left = row.left, left.kind == .deletion { ids.append(left.id) }
                    if let right = row.right, right.kind == .addition { ids.append(right.id) }
                    rows.append(SelectableRow(key: "s-\(hunkIndex)-\(row.id)", lineIDs: ids))
                }
            } else {
                for line in hunk.lines {
                    rows.append(SelectableRow(
                        key: "u-\(line.id)",
                        lineIDs: line.kind == .context ? [] : [line.id]
                    ))
                }
            }
        }
        return rows
    }

    /// 当前可视选区（锚点行…光标行）。
    private var visualRange: ClosedRange<Int>? {
        guard let anchor = anchorRow, let cursor = cursorRow else { return nil }
        return min(anchor, cursor)...max(anchor, cursor)
    }

    /// 选区 = 锚点到光标之间所有行的变更行。
    private func applyRangeSelection() {
        guard let range = visualRange else { return }
        let order = rowOrder
        guard range.lowerBound >= 0, range.upperBound < order.count else { return }
        vm.selectedLineIDs = Set(order[range].flatMap(\.lineIDs))
    }

    /// 键盘 ↑↓ 移动光标行；⇧ 扩选（编辑器语义）。
    private func moveCursor(_ delta: Int, extend: Bool, proxy: ScrollViewProxy) {
        let order = rowOrder
        guard !order.isEmpty else { return }
        let current = cursorRow ?? anchorRow ?? 0
        let next = max(0, min(order.count - 1, current + delta))
        cursorRow = next
        if !extend || anchorRow == nil {
            anchorRow = next
        }
        applyRangeSelection()
        proxy.scrollTo(order[next].key, anchor: nil)
    }

    /// 行点击（编辑器语义）：
    /// 普通点击 = 选中该行（替换选区）；⇧+点击 = 锚点扩选；⌘+点击 = 切换该行。
    private func handleLineTap(_ id: Int) {
        diffFocused = true
        guard let key = rowKeyContaining(id),
              let index = rowOrder.firstIndex(where: { $0.key == key })
        else { return }

        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.shift) {
            cursorRow = index
            if anchorRow == nil { anchorRow = index }
            applyRangeSelection()
        } else if modifiers.contains(.command) {
            vm.toggleLine(id)
            anchorRow = index
            cursorRow = index
        } else {
            anchorRow = index
            cursorRow = index
            vm.selectedLineIDs = Set(rowOrder[index].lineIDs)
        }
    }

    private func rowKeyContaining(_ lineID: Int) -> String? {
        rowOrder.first { $0.lineIDs.contains(lineID) }?.key
    }
}

// MARK: - Hunk 头

private struct HunkHeaderRow: View {
    @EnvironmentObject var vm: RepoViewModel
    let hunk: DiffHunk
    let supportsStaging: Bool
    var isUntracked = false

    var body: some View {
        HStack(spacing: 10) {
            Text("@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@ \(hunk.sectionHeading)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if supportsStaging {
                if vm.diffArea == .unstaged, !isUntracked {
                    Button {
                        vm.requestDiscardHunk(hunk)
                    } label: {
                        Text(tr("撤销此块", "Discard Hunk"))
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red.opacity(0.85))
                    .help(tr("把这一块的工作区修改恢复成暂存区内容", "Revert this hunk's worktree changes"))
                }
                Button {
                    vm.stageHunk(hunk)
                } label: {
                    Text(vm.diffArea == .staged ? tr("取消暂存此块", "Unstage Hunk") : tr("暂存此块", "Stage Hunk"))
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// 折叠的未更改区域占位行，点击展开。
private struct ExpanderRow: View {
    let count: Int
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.and.down.text.horizontal")
                    .font(.system(size: 9))
                Text(tr("展开 \(count) 行未更改的内容", "Expand \(count) unchanged line(s)"))
                    .font(.caption)
            }
            .foregroundStyle(hovering ? Color.accentColor : Color.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(Color(nsColor: .windowBackgroundColor).opacity(hovering ? 1 : 0.55))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - 统一视图行

private struct UnifiedDiffRow: View {
    @EnvironmentObject var vm: RepoViewModel
    @EnvironmentObject var settings: SettingsStore
    let line: DiffLine
    let filePath: String
    let selectable: Bool
    var inSelectionRange = false
    var onLineTap: ((Int) -> Void)?

    private var isSelected: Bool { vm.selectedLineIDs.contains(line.id) }
    private var isChanged: Bool { line.kind != .context }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if selectable {
                Group {
                    if isChanged {
                        Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                            .font(.system(size: 11))
                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.5))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                // 勾选框保留切换语义（不改变锚点选区）
                                vm.toggleLine(line.id)
                            }
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 22)
            }

            Text(line.oldNumber.map(String.init) ?? "")
                .frame(width: 42, alignment: .trailing)
                .foregroundStyle(.tertiary)
            Text(line.newNumber.map(String.init) ?? "")
                .frame(width: 42, alignment: .trailing)
                .foregroundStyle(.tertiary)

            Text(marker)
                .frame(width: 18)
                .foregroundStyle(markerColor)

            DiffLineText(text: line.text, filePath: filePath)

            Spacer(minLength: 0)
        }
        .font(.system(size: settings.editorFontSize - 1, design: .monospaced))
        .padding(.vertical, 1)
        .background(inSelectionRange ? Color.accentColor.opacity(0.08) : .clear)
        .background(background)
        .overlay(alignment: .leading) {
            if isSelected {
                Rectangle().fill(Color.accentColor).frame(width: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard selectable, isChanged else { return }
            (onLineTap ?? vm.toggleLine)(line.id)
        }
    }

    private var marker: String {
        switch line.kind {
        case .addition: return "+"
        case .deletion: return "-"
        case .context: return ""
        }
    }

    private var markerColor: Color {
        switch line.kind {
        case .addition: return .green
        case .deletion: return .red
        case .context: return .secondary
        }
    }

    private var background: Color {
        let base: Color
        switch line.kind {
        case .addition: base = .green
        case .deletion: base = .red
        case .context: return .clear
        }
        return base.opacity(isSelected ? 0.22 : 0.12)
    }
}

// MARK: - 分栏视图行

private struct SplitDiffRow: View {
    @EnvironmentObject var vm: RepoViewModel
    @EnvironmentObject var settings: SettingsStore
    let row: SplitRow
    let filePath: String
    let selectable: Bool
    var inSelectionRange = false
    var onLineTap: ((Int) -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            cell(for: row.left, side: .left)
            Divider()
            cell(for: row.right, side: .right)
        }
        .font(.system(size: settings.editorFontSize - 1, design: .monospaced))
        .background(inSelectionRange ? Color.accentColor.opacity(0.08) : .clear)
    }

    private enum Side { case left, right }

    @ViewBuilder
    private func cell(for line: DiffLine?, side: Side) -> some View {
        let showsLine = cellLine(line, side: side)
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(showsLine.flatMap { side == .left ? $0.oldNumber : $0.newNumber }.map(String.init) ?? "")
                .frame(width: 42, alignment: .trailing)
                .foregroundStyle(.tertiary)
            if let line = showsLine {
                DiffLineText(text: line.text, filePath: filePath)
                    .padding(.leading, 8)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cellBackground(showsLine, side: side))
        .overlay(alignment: .leading) {
            if let line = showsLine, line.kind != .context, vm.selectedLineIDs.contains(line.id) {
                Rectangle().fill(Color.accentColor).frame(width: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard selectable, let line = showsLine, line.kind != .context else { return }
            (onLineTap ?? vm.toggleLine)(line.id)
        }
    }

    /// 该侧应展示的行：上下文两侧都展示；左侧只展示删除，右侧只展示新增。
    private func cellLine(_ line: DiffLine?, side: Side) -> DiffLine? {
        guard let line else { return nil }
        if line.kind == .context { return line }
        if side == .left, line.kind == .deletion { return line }
        if side == .right, line.kind == .addition { return line }
        return nil
    }

    private func cellBackground(_ line: DiffLine?, side: Side) -> Color {
        guard let line else { return Color(nsColor: .windowBackgroundColor).opacity(0.5) }
        switch line.kind {
        case .context: return .clear
        case .deletion:
            return Color.red.opacity(vm.selectedLineIDs.contains(line.id) ? 0.22 : 0.12)
        case .addition:
            return Color.green.opacity(vm.selectedLineIDs.contains(line.id) ? 0.22 : 0.12)
        }
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
            } else {
                ScrollView([.vertical]) {
                    LazyVStack(spacing: 0) {
                        ForEach(diff.hunks) { hunk in
                            HStack {
                                Text("@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@ \(hunk.sectionHeading)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .background(Color(nsColor: .windowBackgroundColor))

                            if settings.splitDiff {
                                ForEach(hunk.splitRows) { row in
                                    SplitDiffRow(row: row, filePath: diff.path, selectable: false)
                                }
                            } else {
                                ForEach(hunk.lines) { line in
                                    UnifiedDiffRow(line: line, filePath: diff.path, selectable: false)
                                }
                            }
                        }
                    }
                    .id("\(diff.path)|\(settings.splitDiff)")
                    .padding(.bottom, 20)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

// MARK: - 带语法高亮的行文本

/// 对单行 diff 文本做逐行词法高亮（无跨行状态，速度优先）。
struct DiffLineText: View {
    @EnvironmentObject var settings: SettingsStore
    let text: String
    let filePath: String
    /// 后台算好的高亮；nil 时先显示纯文本（measure 阶段不 tokenize，不卡）
    @State private var highlighted: AttributedString?

    /// 单行显示上限：超过则截断，避免 TextKit 测量超长行（minified）时卡顿。
    /// 只影响显示，diff/暂存仍用完整 text。
    private static let maxDisplayLength = 5000

    private var display: String {
        let raw = text.isEmpty ? " " : text
        guard raw.count > Self.maxDisplayLength else { return raw }
        return String(raw.prefix(Self.maxDisplayLength))
            + tr(" …（本行共 \(raw.count) 字符，已截断显示）",
                 " …(line is \(raw.count) chars, truncated)")
    }

    var body: some View {
        Group {
            if let highlighted {
                Text(highlighted)
            } else {
                // 纯文本用 String 重载，不构造巨型 AttributedString
                Text(verbatim: display)
            }
        }
        // 只有可见行才会出现并触发；滚出视图自动取消。text/主题变则重算
        .task(id: "\(text)\u{1}\(settings.themeID)") {
            highlighted = await DiffHighlighter.highlight(
                text: text, filePath: filePath, settings: settings)
        }
    }
}
