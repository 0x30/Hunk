import SwiftUI
import AppKit
import HunkCore

/// 侧边栏「标签」区块的一行：图标 + 名 + 目标/说明 + 悬停操作 + 右键菜单。
/// 不参与 List 选中（无 tag），交互走悬停按钮与右键菜单——与贮藏/工作树行一致。
struct TagRow: View {
    @EnvironmentObject var vm: RepoViewModel
    let tag: Tag
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "tag")
                .foregroundStyle(.secondary)
                .font(.system(size: 11))
            VStack(alignment: .leading, spacing: 1) {
                Text(tag.name)
                    .lineLimit(1)
                    .font(.callout)
                HStack(spacing: 4) {
                    Text(tag.target)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                    if !tag.subject.isEmpty {
                        Text(tag.subject)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 4)
            if hovering {
                HStack(spacing: 2) {
                    TagRowIcon("arrow.left.arrow.right",
                               help: tr("与当前对比", "Compare with current")) {
                        vm.compareTag(tag)
                    }
                    TagRowIcon("arrow.up.circle",
                               help: tr("推送到 origin", "Push to origin")) {
                        vm.pushTag(tag)
                    }
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(tag.isAnnotated ? tr("附注标签", "Annotated tag") : tr("轻量标签", "Lightweight tag"))
        .contextMenu {
            Button(tr("与当前对比", "Compare with Current")) { vm.compareTag(tag) }
            Button(tr("推送到 origin", "Push to origin")) { vm.pushTag(tag) }
            Button(tr("复制标签名", "Copy Tag Name")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(tag.name, forType: .string)
            }
            Divider()
            Button(tr("删除标签…", "Delete Tag…"), role: .destructive) {
                vm.promptDeleteTag(tag)
            }
        }
    }
}

/// 标签行悬停操作的小图标按钮（List 行内必须用 .borderless，否则点击被选中吞掉）。
private struct TagRowIcon: View {
    let systemName: String
    let help: String
    let action: () -> Void
    init(_ systemName: String, help: String, action: @escaping () -> Void) {
        self.systemName = systemName
        self.help = help
        self.action = action
    }
    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

/// 新建标签表单：标签名 + 可选说明（填写则为附注标签），创建在当前 HEAD。
struct CreateTagSheet: View {
    @EnvironmentObject var vm: RepoViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var message = ""

    private var canCreate: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("新建标签", "New Tag"))
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text(tr("标签名", "Tag name"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(tr("如 v1.0.0", "e.g. v1.0.0"), text: $name)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("说明（可选，填写则创建附注标签）", "Message (optional; creates an annotated tag)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(tr("标签说明", "Tag message"), text: $message)
                    .textFieldStyle(.roundedBorder)
            }
            Text(tr("将在当前 HEAD（\(vm.currentBranch)）上创建。",
                    "Created at current HEAD (\(vm.currentBranch))."))
                .font(.caption2)
                .foregroundStyle(.tertiary)

            HStack {
                Spacer()
                Button(tr("取消", "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(tr("创建", "Create")) {
                    vm.createTag(name: name, message: message)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
