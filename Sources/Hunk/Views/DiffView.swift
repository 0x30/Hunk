import SwiftUI
import HunkCore

/// 更改详情：文件头 + diff 内容（统一 / 分栏），支持行级暂存。
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
            Divider()
            content
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 8) {
            FileIconView(fileName: (path as NSString).lastPathComponent)
            VStack(alignment: .leading, spacing: 1) {
                Text((path as NSString).lastPathComponent)
                    .fontWeight(.medium)
                HStack(spacing: 6) {
                    if let old = vm.diff?.oldPath, vm.diff?.isRename == true {
                        Text("\(old) →")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if let diff = vm.diff, !diff.isBinary {
                HStack(spacing: 4) {
                    Text("+\(diff.additions)")
                        .foregroundStyle(.green)
                    Text("-\(diff.deletions)")
                        .foregroundStyle(.red)
                }
                .font(.caption.monospacedDigit().weight(.medium))
            }

            Spacer()

            if supportsLineStaging, !vm.selectedLineIDs.isEmpty {
                Button {
                    if vm.diffArea == .staged {
                        vm.unstageSelectedLines()
                    } else {
                        vm.stageSelectedLines()
                    }
                } label: {
                    Label(
                        vm.diffArea == .staged
                            ? tr("取消暂存选中行 (\(vm.selectedLineIDs.count))", "Unstage Selected Lines (\(vm.selectedLineIDs.count))")
                            : tr("暂存选中行 (\(vm.selectedLineIDs.count))", "Stage Selected Lines (\(vm.selectedLineIDs.count))"),
                        systemImage: vm.diffArea == .staged ? "minus.square" : "plus.square"
                    )
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            if vm.diffArea == .staged {
                Button {
                    vm.unstageFile(path)
                } label: {
                    Label(tr("取消暂存文件", "Unstage File"), systemImage: "minus.circle")
                }
                .controlSize(.small)
            } else {
                Button {
                    vm.stageFile(path)
                } label: {
                    Label(tr("暂存文件", "Stage File"), systemImage: "plus.circle")
                }
                .controlSize(.small)

                if change?.unstaged != .deleted {
                    Button {
                        vm.editingChangedFile = true
                        vm.openEditor(path: path)
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .controlSize(.small)
                    .help(tr("编辑文件", "Edit File"))
                }
            }

            Button {
                settings.splitDiff.toggle()
            } label: {
                Image(systemName: settings.splitDiff ? "rectangle" : "rectangle.split.2x1")
            }
            .controlSize(.small)
            .help(settings.splitDiff
                  ? tr("切换为统一视图", "Switch to unified view")
                  : tr("切换为分栏视图", "Switch to split view"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
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
                ScrollView([.vertical]) {
                    LazyVStack(spacing: 0, pinnedViews: []) {
                        ForEach(diff.hunks) { hunk in
                            HunkHeaderRow(hunk: hunk, supportsStaging: supportsLineStaging)
                            if settings.splitDiff {
                                ForEach(hunk.splitRows) { row in
                                    SplitDiffRow(row: row, filePath: path, selectable: supportsLineStaging)
                                }
                            } else {
                                ForEach(hunk.lines) { line in
                                    UnifiedDiffRow(line: line, filePath: path, selectable: supportsLineStaging)
                                }
                            }
                        }
                    }
                    .padding(.bottom, 20)
                }
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

// MARK: - Hunk 头

private struct HunkHeaderRow: View {
    @EnvironmentObject var vm: RepoViewModel
    let hunk: DiffHunk
    let supportsStaging: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text("@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@ \(hunk.sectionHeading)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if supportsStaging {
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

// MARK: - 统一视图行

private struct UnifiedDiffRow: View {
    @EnvironmentObject var vm: RepoViewModel
    @EnvironmentObject var settings: SettingsStore
    let line: DiffLine
    let filePath: String
    let selectable: Bool

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
        .background(background)
        .overlay(alignment: .leading) {
            if isSelected {
                Rectangle().fill(Color.accentColor).frame(width: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard selectable, isChanged else { return }
            vm.toggleLine(line.id)
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

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            cell(for: row.left, side: .left)
            Divider()
            cell(for: row.right, side: .right)
        }
        .font(.system(size: settings.editorFontSize - 1, design: .monospaced))
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
            vm.toggleLine(line.id)
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

// MARK: - 带语法高亮的行文本

/// 对单行 diff 文本做逐行词法高亮（无跨行状态，速度优先）。
struct DiffLineText: View {
    @EnvironmentObject var settings: SettingsStore
    let text: String
    let filePath: String

    var body: some View {
        Text(highlighted)
    }

    private var highlighted: AttributedString {
        let display = text.isEmpty ? " " : text
        var attributed = AttributedString(display)
        guard let language = Lexer.language(forFileName: (filePath as NSString).lastPathComponent) else {
            return attributed
        }
        for token in Lexer.tokenize(display, language: language) {
            guard let stringRange = Range(token.range, in: display),
                  let lower = AttributedString.Index(stringRange.lowerBound, within: attributed),
                  let upper = AttributedString.Index(stringRange.upperBound, within: attributed)
            else { continue }
            attributed[lower..<upper].foregroundColor = settings.tokenColor(for: token.type)
        }
        return attributed
    }
}
