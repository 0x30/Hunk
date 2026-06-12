import SwiftUI

/// 更改标签页底部的提交栏。
struct CommitBarView: View {
    @EnvironmentObject var vm: RepoViewModel
    @FocusState private var messageFocused: Bool

    private var canCommit: Bool {
        !vm.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !vm.stagedChanges.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $vm.commitMessage)
                    .font(.body)
                    .focused($messageFocused)
                    .frame(height: 58)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(
                                messageFocused ? AnyShapeStyle(Color.accentColor.opacity(0.7)) : AnyShapeStyle(.separator),
                                lineWidth: 1
                            )
                    )

                if vm.commitMessage.isEmpty {
                    Text(tr("提交信息（⌘⏎ 提交）", "Commit message (⌘⏎ to commit)"))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 9)
                        .padding(.leading, 10)
                        .allowsHitTesting(false)
                }
            }

            HStack {
                Button {
                    vm.commit()
                } label: {
                    // label 层级保持恒定，避免重建后丢失点击（同 SyncControls）
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.circle")
                        Text(tr("提交", "Commit"))
                        Text(vm.stagedChanges.isEmpty ? "" : "(\(vm.stagedChanges.count))")
                            .monospacedDigit()
                    }
                    .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .disabled(!canCommit)
                .help(vm.stagedChanges.isEmpty
                      ? tr("没有已暂存的更改", "No staged changes")
                      : tr("提交已暂存的更改", "Commit staged changes"))
            }
        }
        .padding(10)
    }
}
