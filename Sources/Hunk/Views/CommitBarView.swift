import SwiftUI

/// 源代码管理底部的提交栏。
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
                    .font(.system(size: 12.5))
                    .focused($messageFocused)
                    .frame(height: 52)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(
                                messageFocused ? AnyShapeStyle(Color.accentColor.opacity(0.6)) : AnyShapeStyle(.separator.opacity(0.6)),
                                lineWidth: 1
                            )
                    )

                if vm.commitMessage.isEmpty {
                    Text(tr("提交信息（⌘⏎ 提交）", "Commit message (⌘⏎ to commit)"))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 7)
                        .padding(.leading, 9)
                        .allowsHitTesting(false)
                }
            }

            Button {
                vm.commit()
            } label: {
                // label 层级保持恒定，避免重建后丢失点击
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                    Text(tr("提交", "Commit"))
                        .font(.system(size: 12.5, weight: .medium))
                    Text(vm.stagedChanges.isEmpty ? "" : "\(vm.stagedChanges.count)")
                        .font(.system(size: 11).monospacedDigit())
                        .opacity(0.75)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 24)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canCommit)
            .help(vm.stagedChanges.isEmpty
                  ? tr("没有已暂存的更改", "No staged changes")
                  : tr("提交已暂存的更改", "Commit staged changes"))
        }
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
