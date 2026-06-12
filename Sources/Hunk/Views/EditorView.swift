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

/// 冲突解决操作条（VS Code 内联方案的工具条版）。
struct ConflictBar: View {
    @EnvironmentObject var vm: RepoViewModel

    var body: some View {
        HStack(spacing: 10) {
            if vm.conflictBlocks.isEmpty {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(tr("所有冲突已处理", "All conflicts handled"))
                    .font(.callout)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(tr("冲突 \(vm.conflictIndex + 1)/\(vm.conflictBlocks.count)", "Conflict \(vm.conflictIndex + 1)/\(vm.conflictBlocks.count)"))
                    .font(.callout.monospacedDigit())

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

                Divider().frame(height: 14)

                Group {
                    Button(currentLabel) { vm.resolveCurrentConflict(.current) }
                        .help(tr("采用当前更改（你的版本）", "Accept current change (yours)"))
                    Button(incomingLabel) { vm.resolveCurrentConflict(.incoming) }
                        .help(tr("采用传入更改（合并进来的版本）", "Accept incoming change (theirs)"))
                    Button(tr("保留两者", "Keep Both")) { vm.resolveCurrentConflict(.both) }
                }
                .controlSize(.small)
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
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var currentLabel: String {
        let label = vm.conflictBlocks.indices.contains(vm.conflictIndex)
            ? vm.conflictBlocks[vm.conflictIndex].currentLabel : ""
        let base = tr("采用当前", "Accept Current")
        return label.isEmpty ? base : "\(base) (\(label))"
    }

    private var incomingLabel: String {
        let label = vm.conflictBlocks.indices.contains(vm.conflictIndex)
            ? vm.conflictBlocks[vm.conflictIndex].incomingLabel : ""
        let base = tr("采用传入", "Accept Incoming")
        return label.isEmpty ? base : "\(base) (\(label))"
    }
}
