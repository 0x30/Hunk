import SwiftUI

/// 「文件变化」模块顶部的提交栏：
/// 回车换行，高度随内容自动增长（1–8 行），超过 8 行后内部滚动；
/// ⌘⏎ 或右侧发送按钮提交。无背景色，透出侧边栏磨砂材质。
struct CommitBarView: View {
    @EnvironmentObject var vm: RepoViewModel
    @FocusState private var messageFocused: Bool

    private var canCommit: Bool {
        !vm.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !vm.stagedChanges.isEmpty
    }

    /// 隐形镜像文本：撑出与内容一致的高度（lineLimit(8) 封顶）。
    /// 末尾换行补一个空格，让空行也计入高度。
    private var mirrorText: String {
        if vm.commitMessage.isEmpty { return " " }
        return vm.commitMessage.hasSuffix("\n") ? vm.commitMessage + " " : vm.commitMessage
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ZStack(alignment: .topLeading) {
                Text(mirrorText)
                    .font(.system(size: 12.5))
                    .lineLimit(8)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(0)

                TextEditor(text: $vm.commitMessage)
                    .font(.system(size: 12.5))
                    .scrollContentBackground(.hidden)
                    .focused($messageFocused)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)

                if vm.commitMessage.isEmpty {
                    Text(tr("提交信息（⏎ 换行 · ⌘⏎ 提交）", "Commit message (⏎ newline · ⌘⏎ commit)"))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 7)
                        .padding(.leading, 9)
                        .allowsHitTesting(false)
                }
            }
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
