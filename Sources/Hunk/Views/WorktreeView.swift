import SwiftUI
import AppKit
import HunkCore

/// 侧边栏「工作树」区块里的一行：图标 + 名称 + 分支 + 主/当前标记 + 悬停操作 + 右键菜单。
/// 不参与 List 选中（无 tag），交互全走悬停按钮与右键菜单——与贮藏行一致。
struct WorktreeRow: View {
    @EnvironmentObject var vm: RepoViewModel
    let worktree: Worktree
    private var canRemove: Bool { !worktree.isMain && !worktree.isCurrent }

    var body: some View {
        // 整行即按钮：左键当前窗口切换（当前工作树内部 guard 不动作）；操作全在右键菜单
        Button {
            vm.switchToWorktree(worktree)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .foregroundStyle(worktree.isCurrent ? Color.accentColor : .secondary)
                    .font(.system(size: 11))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(worktree.name)
                            .lineLimit(1)
                            .font(.callout)
                            .fontWeight(worktree.isCurrent ? .semibold : .regular)
                            .foregroundStyle(.primary)
                        if worktree.isCurrent {
                            TagLabel(tr("当前", "current"))
                        } else if worktree.isMain {
                            TagLabel(tr("主", "main"))
                        }
                        if worktree.isLocked {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(.tertiary)
                                .help(tr("已锁定", "Locked"))
                        }
                        if worktree.isPrunable {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(.orange)
                                .help(tr("孤立的工作树（目录已不存在）", "Orphaned worktree (directory missing)"))
                        }
                    }
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                        Text(worktree.refName)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
            }
            .padding(.vertical, 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(worktree.isCurrent
              ? worktree.path
              : tr("点击切换到此工作树 · \(worktree.path)", "Click to switch · \(worktree.path)"))
        .contextMenu {
            if !worktree.isCurrent {
                Button(tr("在新窗口打开", "Open in New Window")) { vm.openWorktree(worktree) }
                Button(tr("与当前对比", "Compare with Current")) { vm.compareWorktree(worktree) }
                Divider()
            }
            Button(tr("在 Finder 中显示", "Reveal in Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: worktree.path)])
            }
            Button(tr("复制路径", "Copy Path")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(worktree.path, forType: .string)
            }
            if canRemove {
                Divider()
                Button(tr("移除工作树…", "Remove Worktree…"), role: .destructive) {
                    vm.promptRemoveWorktree(worktree)
                }
            }
        }
    }
}

/// 小号胶囊标签（如「主」）。
private struct TagLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 0.5)
            .background(Capsule().fill(.quaternary.opacity(0.7)))
    }
}

// MARK: - 新建工作树

/// 新建工作树表单：现有分支 / 新建分支 + 目标位置。
struct CreateWorktreeSheet: View {
    @EnvironmentObject var vm: RepoViewModel
    @Environment(\.dismiss) private var dismiss

    private enum Mode: Hashable { case newBranch, existing }
    @State private var mode: Mode = .newBranch
    @State private var newBranchName = ""
    @State private var selectedBranch = ""
    @State private var path = ""
    @State private var lastAutoPath = ""

    /// 可供检出的现有分支：排除当前分支与已被其他工作树占用的分支。
    private var availableBranches: [Branch] {
        vm.branches.filter { !$0.isCurrent && !vm.branchesInUse.contains($0.name) }
    }

    private var effectiveBranch: String {
        mode == .newBranch ? newBranchName : selectedBranch
    }

    private var canCreate: Bool {
        !effectiveBranch.trimmingCharacters(in: .whitespaces).isEmpty
            && !path.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("新建工作树", "New Worktree"))
                .font(.headline)

            Picker("", selection: $mode) {
                Text(tr("新建分支", "New Branch")).tag(Mode.newBranch)
                Text(tr("现有分支", "Existing Branch")).tag(Mode.existing)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            // 分支选择
            Group {
                if mode == .newBranch {
                    LabeledField(tr("分支名", "Branch name")) {
                        TextField(tr("如 feature/login", "e.g. feature/login"), text: $newBranchName)
                            .textFieldStyle(.roundedBorder)
                    }
                } else {
                    LabeledField(tr("分支", "Branch")) {
                        if availableBranches.isEmpty {
                            Text(tr("没有可用的分支（其他分支均已被占用或为当前分支）",
                                    "No available branches (all are in use or current)"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Picker("", selection: $selectedBranch) {
                                Text(tr("请选择…", "Choose…")).tag("")
                                ForEach(availableBranches) { branch in
                                    Text(branch.name).tag(branch.name)
                                }
                            }
                            .labelsHidden()
                        }
                    }
                }
            }

            // 目标位置
            LabeledField(tr("位置", "Location")) {
                HStack(spacing: 6) {
                    TextField(tr("工作树目录路径", "Worktree directory path"), text: $path)
                        .textFieldStyle(.roundedBorder)
                    Button(tr("选择…", "Choose…")) { chooseLocation() }
                }
            }

            HStack {
                Spacer()
                Button(tr("取消", "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(tr("创建", "Create")) {
                    vm.createWorktree(path: path, branch: effectiveBranch, createBranch: mode == .newBranch)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { syncDefaultPath() }
        .onChange(of: newBranchName) { _, _ in syncDefaultPath() }
        .onChange(of: selectedBranch) { _, _ in syncDefaultPath() }
        .onChange(of: mode) { _, _ in syncDefaultPath() }
    }

    /// 用户未手动改过路径时，按当前分支名自动填入「仓库父目录/<仓库名>-<分支>」。
    /// 以「path 是否仍等于上次自动填入的值」判断是否被手动编辑过，避免代码自身赋值被误判为手动。
    private func syncDefaultPath() {
        guard let root = vm.repoRoot else { return }
        if !lastAutoPath.isEmpty, path != lastAutoPath { return }
        let branch = effectiveBranch.trimmingCharacters(in: .whitespaces)
        let suffix = branch.isEmpty ? "worktree" : branch.replacingOccurrences(of: "/", with: "-")
        let target = root.deletingLastPathComponent()
            .appendingPathComponent("\(root.lastPathComponent)-\(suffix)")
        path = target.path
        lastAutoPath = target.path
    }

    private func chooseLocation() {
        guard let root = vm.repoRoot else { return }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.directoryURL = root.deletingLastPathComponent()
        let branch = effectiveBranch.trimmingCharacters(in: .whitespaces)
        let suffix = branch.isEmpty ? "worktree" : branch.replacingOccurrences(of: "/", with: "-")
        panel.nameFieldStringValue = "\(root.lastPathComponent)-\(suffix)"
        panel.prompt = tr("选择", "Choose")
        panel.message = tr("选择新工作树的位置", "Choose the location for the new worktree")
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path  // 视为手动指定：lastAutoPath 不更新，后续不再自动覆盖
        }
    }
}

/// 表单里的「标签 + 控件」纵向一组。
private struct LabeledField<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content
    init(_ label: String, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.content = content
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
    }
}
