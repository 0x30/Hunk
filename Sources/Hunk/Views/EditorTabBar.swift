import SwiftUI

/// 编辑器顶部的多文件标签栏。
struct EditorTabBar: View {
    @EnvironmentObject var vm: RepoViewModel

    private var blameActive: Bool {
        vm.blameViewPath != nil && vm.blameViewPath == vm.editorPath
    }

    var body: some View {
        HStack(spacing: 0) {
            // blame 视图开关（仅 git 仓库）：查看当前文件的逐块归属与提交
            if vm.isGitRepo {
                Button {
                    vm.toggleBlameView()
                } label: {
                    Image(systemName: "person.text.rectangle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(blameActive ? Color.accentColor : Color.secondary)
                        .frame(width: 30, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tr("Blame 视图：查看每一块代码的作者与提交", "Blame view: who wrote each block"))

                Rectangle()
                    .fill(Color(nsColor: .separatorColor).opacity(0.5))
                    .frame(width: 1, height: 16)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 0) {
                    // 搜索标签排最前；激活时（showGlobalSearch）文件标签都不高亮
                    if vm.searchTabOpen {
                        SearchTabItem(isActive: vm.showGlobalSearch)
                    }
                    ForEach(vm.openTabs, id: \.self) { path in
                        EditorTabItem(path: path, isActive: !vm.showGlobalSearch && path == vm.editorPath)
                    }
                }
            }
        }
        .frame(height: 32)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// 搜索作为编辑器里的一个标签：标题随模式与关键字变化（查找/替换: kw）。
private struct SearchTabItem: View {
    @EnvironmentObject var vm: RepoViewModel
    let isActive: Bool
    @State private var hovering = false

    private var title: String {
        let kw = vm.globalSearchQuery.trimmingCharacters(in: .whitespaces)
        let label = vm.globalSearchReplace ? tr("替换", "Replace") : tr("查找", "Find")
        return kw.isEmpty ? label : "\(label): \(kw)"
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: vm.globalSearchReplace ? "arrow.triangle.2.circlepath" : "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(isActive ? Color.accentColor : .secondary)
            Text(title)
                .font(.system(size: 12))
                .lineLimit(1)
                .foregroundStyle(isActive ? .primary : .secondary)
            Button {
                vm.closeSearchTab()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .opacity(hovering ? 1 : 0)
            }
            .buttonStyle(.plain)
            .frame(width: 14, height: 14)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(isActive ? Color(nsColor: .textBackgroundColor) : .clear)
        .overlay(alignment: .top) {
            if isActive { Rectangle().fill(Color.accentColor).frame(height: 2) }
        }
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.5)).frame(width: 1, height: 16)
        }
        .contentShape(Rectangle())
        .onTapGesture { vm.activateSearchTab() }
        .onHover { hovering = $0 }
    }
}

private struct EditorTabItem: View {
    @EnvironmentObject var vm: RepoViewModel
    let path: String
    let isActive: Bool
    @State private var hovering = false

    private var fileName: String { vm.displayName(for: path) }
    private var isDirty: Bool { vm.isTabDirty(path) }

    var body: some View {
        HStack(spacing: 5) {
            FileIconView(fileName: fileName)

            Text(fileName)
                .font(.system(size: 12))
                .lineLimit(1)
                .foregroundStyle(isActive ? .primary : .secondary)

            // 关闭按钮与未保存圆点共用同一块区域
            ZStack {
                if hovering {
                    Button {
                        vm.closeTab(path)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(tr("关闭 (⌘W)", "Close (⌘W)"))
                } else if isDirty {
                    Circle()
                        .fill(.orange)
                        .frame(width: 7, height: 7)
                }
            }
            .frame(width: 14, height: 14)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(isActive ? Color(nsColor: .textBackgroundColor) : .clear)
        .overlay(alignment: .top) {
            if isActive {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 2)
            }
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.5))
                .frame(width: 1, height: 16)
        }
        .contentShape(Rectangle())
        .onTapGesture { vm.selectTab(path) }
        .onHover { hovering = $0 }
        .help(path)
        .contextMenu {
            Button(tr("关闭", "Close")) { vm.closeTab(path) }
            Button(tr("关闭其他", "Close Others")) { vm.closeOtherTabs(keeping: path) }
            Button(tr("关闭已保存", "Close Saved")) { vm.closeSavedTabs() }
            Button(tr("关闭右侧", "Close to the Right")) { vm.closeTabsToTheRight(of: path) }
            if !vm.isUntitled(path) {
                Divider()
                // 有文件树时才有「在文件列表中显示」（单文件模式无树）
                if !vm.workspaceTree.isEmpty {
                    Button(tr("在文件列表中显示", "Reveal in Files")) { vm.revealInFiles(path) }
                }
                // 文件历史需要 git
                if vm.isGitRepo {
                    Button(tr("查看文件历史", "View File History")) { vm.showFileHistory(path) }
                }
                Divider()
                Button(tr("在 Finder 中显示", "Reveal in Finder")) { vm.revealInFinder(path) }
                Button(tr("复制路径", "Copy Path")) { vm.copyPath(path) }
            }
        }
    }
}

/// 编辑区容器：标签栏 + 编辑器 / 图片预览 + 关闭未保存确认。
struct EditorArea: View {
    @EnvironmentObject var vm: RepoViewModel
    let activePath: String
    var showConflictBar = false

    var body: some View {
        VStack(spacing: 0) {
            if !vm.openTabs.isEmpty || vm.searchTabOpen {
                EditorTabBar()
                Divider()
            }
            if vm.showGlobalSearch {
                SearchPanelView()
            } else if FileIcon.isImage(activePath) {
                ImagePreviewView(path: activePath)
            } else if vm.blameViewPath == activePath {
                FileBlameView(path: activePath)
            } else {
                EditorView(path: activePath, showConflictBar: showConflictBar)
            }
            // 搜索激活时不显示编辑器底部状态栏（光标行列对搜索无意义）
            if !vm.showGlobalSearch {
                Divider()
                EditorStatusBar()
            }
        }
        .confirmationDialog(
            tr("「\(vm.pendingCloseTab.map { vm.displayName(for: $0) } ?? "")」有未保存的修改",
               "“\(vm.pendingCloseTab.map { vm.displayName(for: $0) } ?? "")” has unsaved changes"),
            isPresented: Binding(
                get: { vm.pendingCloseTab != nil },
                set: { if !$0 { vm.pendingCloseTab = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(tr("保存并关闭", "Save & Close")) {
                if let path = vm.pendingCloseTab {
                    vm.pendingCloseTab = nil
                    vm.saveAndCloseTab(path)
                }
            }
            Button(tr("放弃更改", "Discard Changes"), role: .destructive) {
                if let path = vm.pendingCloseTab {
                    vm.pendingCloseTab = nil
                    vm.performCloseTab(path)
                }
            }
            Button(tr("取消", "Cancel"), role: .cancel) {
                vm.pendingCloseTab = nil
            }
        }
    }
}
