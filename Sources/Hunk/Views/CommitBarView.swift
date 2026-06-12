import SwiftUI

/// 「文件变化」模块顶部的提交栏：
/// 默认一行高，回车换行、随内容自动增高（最多 8 行后内部滚动）；
/// 发送按钮悬浮在输入框内部右下角；⌘⏎ 提交。
///
/// 结构：隐形镜像 Text 决定盒子尺寸，TextEditor 作为它的 overlay——
/// overlay 总是被赋予基底的精确尺寸，编辑区随内容同步增高，无需高度状态。
struct CommitBarView: View {
    @EnvironmentObject var vm: RepoViewModel
    @FocusState private var messageFocused: Bool

    private var canCommit: Bool {
        !vm.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !vm.stagedChanges.isEmpty
    }

    /// 镜像文本：末尾换行补一个空格，让空行也计入高度。
    private var mirrorText: String {
        if vm.commitMessage.isEmpty { return " " }
        return vm.commitMessage.hasSuffix("\n") ? vm.commitMessage + " " : vm.commitMessage
    }

    var body: some View {
        Text(mirrorText)
            .font(.system(size: 12.5))
            .lineLimit(8)
            .padding(.horizontal, 9)
            .padding(.trailing, 22)  // 给悬浮发送按钮留位
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(0)
            .overlay(
                // 编辑器铺满整个输入框（滚动条贴盒子右缘），发送按钮浮在其上
                TextEditor(text: $vm.commitMessage)
                    .font(.system(size: 12.5))
                    .scrollContentBackground(.hidden)
                    .focused($messageFocused)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 6)
            )
            .overlay(alignment: .topLeading) {
                if vm.commitMessage.isEmpty {
                    Text(tr("提交信息（⌘⏎ 提交）", "Commit message (⌘⏎)"))
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
            // 发送按钮悬浮在输入框内部右下角
            .overlay(alignment: .bottomTrailing) {
                Button {
                    vm.commit()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(canCommit ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
                }
                .buttonStyle(.plain)
                .disabled(!canCommit)
                .padding(6)
                .help(vm.stagedChanges.isEmpty
                      ? tr("没有已暂存的更改", "No staged changes")
                      : tr("提交 \(vm.stagedChanges.count) 个已暂存的文件 (⌘⏎)", "Commit \(vm.stagedChanges.count) staged files (⌘⏎)"))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
    }
}
