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
                blameText: vm.blameText,
                onEdit: {
                    vm.editorDirty = true
                    vm.reparseConflicts()
                },
                onCursorLineChange: { line in
                    vm.requestBlame(line: line)
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

/// 冲突解决条：极简单行。颜色与编辑器内的冲突块底色对应——
/// 绿点 = 当前更改（你本地的，上半块），蓝点 = 传入更改（对方的，下半块）。
struct ConflictBar: View {
    @EnvironmentObject var vm: RepoViewModel

    private var block: ConflictBlock? {
        vm.conflictBlocks.indices.contains(vm.conflictIndex)
            ? vm.conflictBlocks[vm.conflictIndex] : nil
    }

    var body: some View {
        HStack(spacing: 12) {
            if vm.conflictBlocks.isEmpty {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 12))
                Text(tr("冲突已全部处理", "All conflicts handled"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 12))
                Text("\(vm.conflictIndex + 1)/\(vm.conflictBlocks.count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)

                HStack(spacing: 0) {
                    Button { vm.gotoConflict(offset: -1) } label: {
                        Image(systemName: "chevron.up")
                    }
                    .help(tr("上一个冲突", "Previous conflict"))
                    Button { vm.gotoConflict(offset: 1) } label: {
                        Image(systemName: "chevron.down")
                    }
                    .help(tr("下一个冲突", "Next conflict"))
                }
                .buttonStyle(.borderless)
                .controlSize(.small)

                Divider().frame(height: 12)

                dotButton(.green, tr("采用当前", "Take Current"),
                          help: tr("保留你本地的版本（绿色块）", "Keep your local version (green block)")
                              + labelSuffix(block?.currentLabel)) {
                    vm.resolveCurrentConflict(.current)
                }
                dotButton(.blue, tr("采用传入", "Take Incoming"),
                          help: tr("保留合并进来的版本（蓝色块）", "Keep the merged-in version (blue block)")
                              + labelSuffix(block?.incomingLabel)) {
                    vm.resolveCurrentConflict(.incoming)
                }
                Button(tr("保留两者", "Keep Both")) {
                    vm.resolveCurrentConflict(.both)
                }
                .buttonStyle(.borderless)
                .font(.callout)
                .help(tr("两个版本都保留：先你的，后对方的", "Keep both: yours first, then theirs"))
            }

            Spacer()

            Button {
                vm.markConflictResolved()
            } label: {
                Label(tr("标记为已解决", "Mark as Resolved"), systemImage: "checkmark")
                    .font(.callout)
            }
            .controlSize(.small)
            .tint(.green)
            .help(vm.conflictBlocks.isEmpty
                  ? tr("保存并暂存此文件", "Save and stage this file")
                  : tr("仍有未处理的冲突", "Conflicts remain"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private func labelSuffix(_ label: String?) -> String {
        guard var label, !label.isEmpty else { return "" }
        if label.count > 12, label.allSatisfy(\.isHexDigit) {
            label = String(label.prefix(8))
        }
        return " · \(label)"
    }

    private func dotButton(_ color: Color, _ title: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(title).font(.callout)
            }
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}
