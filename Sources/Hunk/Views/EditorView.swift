import SwiftUI
import HunkCore

/// 极简编辑器页：文件头 + （可选）冲突操作条 + 纯文本编辑区。
struct EditorView: View {
    @EnvironmentObject var vm: RepoViewModel
    @EnvironmentObject var settings: SettingsStore
    let path: String
    let showConflictBar: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if showConflictBar {
                ConflictBar()
                Divider()
            }
            PlainTextEditor(
                text: $vm.editorText,
                fileName: (path as NSString).lastPathComponent,
                conflicts: vm.conflictBlocks,
                scrollToLine: $vm.scrollToLine,
                onEdit: {
                    vm.editorDirty = true
                    vm.reparseConflicts()
                }
            )
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear {
            if vm.editorPath != path {
                vm.openEditor(path: path)
            }
        }
        .onChange(of: path) { _, newPath in
            if vm.editorPath != newPath {
                vm.openEditor(path: newPath)
            }
        }
    }

    private var hasChanges: Bool {
        vm.changes.contains { $0.path == path }
    }

    private var header: some View {
        HStack(spacing: 8) {
            FileIconView(fileName: (path as NSString).lastPathComponent)
            Text(path)
                .lineLimit(1)
                .truncationMode(.middle)

            if vm.editorDirty {
                Circle()
                    .fill(.orange)
                    .frame(width: 7, height: 7)
                    .help(tr("未保存的修改", "Unsaved changes"))
            }

            Spacer()

            if vm.editingChangedFile {
                Button {
                    vm.editingChangedFile = false
                    Task { await vm.loadDetail() }
                } label: {
                    Label(tr("查看差异", "View Diff"), systemImage: "plus.forwardslash.minus")
                }
                .controlSize(.small)
            } else if hasChanges, case .file = vm.selection {
                Button {
                    vm.sidebarTab = .changes
                    if let change = vm.changes.first(where: { $0.path == path }) {
                        let area: ChangeArea = change.isConflicted
                            ? .conflicted
                            : (change.unstaged != nil ? .unstaged : .staged)
                        vm.selection = .change(path: path, area: area)
                    }
                } label: {
                    Label(tr("查看差异", "View Diff"), systemImage: "plus.forwardslash.minus")
                }
                .controlSize(.small)
            }

            Button {
                Task { await vm.saveEditor() }
            } label: {
                Label(tr("保存", "Save"), systemImage: "square.and.arrow.down")
            }
            .controlSize(.small)
            .disabled(!vm.editorDirty)
            .help("⌘S")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// 冲突解决面板：双卡片直观展示两个版本的内容，
/// 颜色与编辑器内的冲突块底色一一对应（绿 = 你的，蓝 = 对方的）。
struct ConflictBar: View {
    @EnvironmentObject var vm: RepoViewModel

    private var block: ConflictBlock? {
        vm.conflictBlocks.indices.contains(vm.conflictIndex)
            ? vm.conflictBlocks[vm.conflictIndex] : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if vm.conflictBlocks.isEmpty {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(tr("所有冲突已处理，可以标记为已解决", "All conflicts handled — ready to mark as resolved"))
                        .font(.callout)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(tr("冲突 \(vm.conflictIndex + 1) / \(vm.conflictBlocks.count)", "Conflict \(vm.conflictIndex + 1) / \(vm.conflictBlocks.count)"))
                        .font(.callout.monospacedDigit().weight(.medium))

                    HStack(spacing: 2) {
                        Button {
                            vm.gotoConflict(offset: -1)
                        } label: {
                            Image(systemName: "chevron.up")
                        }
                        .help(tr("上一个冲突", "Previous conflict"))
                        Button {
                            vm.gotoConflict(offset: 1)
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .help(tr("下一个冲突", "Next conflict"))
                    }
                    .controlSize(.small)

                    Button(tr("保留两者", "Keep Both")) {
                        vm.resolveCurrentConflict(.both)
                    }
                    .controlSize(.small)
                    .help(tr("两个版本都保留：先你的，后对方的", "Keep both: yours first, then theirs"))
                }

                Spacer()

                Button {
                    vm.markConflictResolved()
                } label: {
                    Label(tr("标记为已解决", "Mark as Resolved"), systemImage: "checkmark")
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(vm.conflictBlocks.isEmpty ? .green : .orange)
                .help(vm.conflictBlocks.isEmpty
                      ? tr("保存并暂存此文件", "Save and stage this file")
                      : tr("仍有未处理的冲突，确认要标记吗？", "Conflicts remain — mark anyway?"))
            }

            if let block {
                HStack(alignment: .top, spacing: 8) {
                    versionCard(
                        color: .green,
                        title: tr("当前更改", "Current Change"),
                        subtitle: tr("你本地的版本", "Your local version")
                            + (block.currentLabel.isEmpty ? "" : " · \(shortLabel(block.currentLabel))"),
                        lines: block.currentLines,
                        actionTitle: tr("采用这个", "Take This"),
                        resolution: .current
                    )
                    versionCard(
                        color: .blue,
                        title: tr("传入更改", "Incoming Change"),
                        subtitle: tr("合并进来的版本", "The merged-in version")
                            + (block.incomingLabel.isEmpty ? "" : " · \(shortLabel(block.incomingLabel))"),
                        lines: block.incomingLines,
                        actionTitle: tr("采用这个", "Take This"),
                        resolution: .incoming
                    )
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// 长 hash 标签截短，分支名原样保留。
    private func shortLabel(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        if trimmed.count > 12, trimmed.allSatisfy(\.isHexDigit) {
            return String(trimmed.prefix(8))
        }
        return trimmed
    }

    private func versionCard(
        color: Color,
        title: String,
        subtitle: String,
        lines: [String],
        actionTitle: String,
        resolution: ConflictBlock.Resolution
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button(actionTitle) {
                    vm.resolveCurrentConflict(resolution)
                }
                .controlSize(.small)
                .tint(color)
            }
            Text(lines.isEmpty
                 ? tr("（此侧为空 — 该版本删除了这些行）", "(empty — this version deleted these lines)")
                 : lines.prefix(4).joined(separator: "\n") + (lines.count > 4 ? "\n…" : ""))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(lines.isEmpty ? .secondary : .primary)
                .lineLimit(5)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7).fill(color.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(color.opacity(0.35), lineWidth: 1))
    }
}
