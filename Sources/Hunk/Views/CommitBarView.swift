import SwiftUI

/// 源代码管理顶部的提交栏：单行输入框随内容自动增高（最多 5 行），
/// 发送式提交按钮；无背景色，透出侧边栏磨砂材质。
struct CommitBarView: View {
    @EnvironmentObject var vm: RepoViewModel
    @FocusState private var messageFocused: Bool

    private var canCommit: Bool {
        !vm.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !vm.stagedChanges.isEmpty
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            TextField(
                tr("提交信息（⌘⏎ 提交）", "Commit message (⌘⏎)"),
                text: $vm.commitMessage,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .lineLimit(1...5)
            .font(.system(size: 12.5))
            .focused($messageFocused)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        messageFocused ? AnyShapeStyle(Color.accentColor.opacity(0.55)) : AnyShapeStyle(.separator.opacity(0.5)),
                        lineWidth: 1
                    )
            )
            .onSubmit {
                if canCommit { vm.commit() }
            }

            Button {
                vm.commit()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 21))
                    .foregroundStyle(canCommit ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
            }
            .buttonStyle(.plain)
            .disabled(!canCommit)
            .padding(.bottom, 2)
            .help(vm.stagedChanges.isEmpty
                  ? tr("没有已暂存的更改", "No staged changes")
                  : tr("提交 \(vm.stagedChanges.count) 个已暂存的文件 (⌘⏎)", "Commit \(vm.stagedChanges.count) staged files (⌘⏎)"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}
