import SwiftUI

/// 修改最近一次提交消息（git commit --amend）。预填原消息，多行可编辑。
struct RewordCommitSheet: View {
    @EnvironmentObject var vm: RepoViewModel
    @Environment(\.dismiss) private var dismiss

    private var canSave: Bool {
        !vm.rewordMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("修改提交消息", "Edit Commit Message"))
                .font(.headline)
            Text(tr("修改最近一次提交的消息（git commit --amend）。",
                    "Reword the most recent commit (git commit --amend)."))
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $vm.rewordMessage)
                .font(.system(size: 12.5))
                .frame(minHeight: 120)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor).opacity(0.55)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator.opacity(0.6)))

            // amend 会把已暂存的改动一并并入这次提交——有暂存改动时提醒一句
            if !vm.stagedChanges.isEmpty {
                Label(
                    tr("暂存区有 \(vm.stagedChanges.count) 处改动，将一并并入此提交。",
                       "\(vm.stagedChanges.count) staged change(s) will be folded into this commit."),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption2)
                .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button(tr("取消", "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(tr("保存", "Save")) {
                    vm.confirmRewordCommit()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
