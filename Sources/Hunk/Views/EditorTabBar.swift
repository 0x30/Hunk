import SwiftUI

/// 统一标签栏：文件标签 + 工作区 diff 标签 + 提交详情标签 + 搜索标签。
/// 高亮按 vm.activeDetail 决定;点击激活、× 关闭。提到 DetailView 顶部,详情区一切皆标签。
struct EditorTabBar: View {
    @EnvironmentObject var vm: RepoViewModel

    private var activeFilePath: String? {
        if case .file(let p) = vm.activeDetail { return p }
        return nil
    }
    private var blameActive: Bool {
        vm.blameViewPath != nil && vm.blameViewPath == vm.editorPath
    }

    var body: some View {
        HStack(spacing: 0) {
            // blame 视图开关：仅在编辑文件标签激活时有意义
            if vm.isGitRepo, activeFilePath != nil {
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
                    ForEach(vm.openTabs, id: \.self) { path in
                        EditorTabItem(path: path, isActive: vm.activeDetail == .file(path))
                    }
                    // diff / 提交 / 比较 / 搜索:各自独立，可同时多个
                    ForEach(vm.openViewTabs) { tab in
                        ViewTabItem(tab: tab, isActive: vm.activeDetail == .view(tab))
                    }
                }
            }
        }
        .frame(height: 32)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// 标签外观（选中态顶部高亮条 + 右分隔线 + 悬停出 ×）的公共包装。
private struct TabChrome<Trailing: View>: ViewModifier {
    let isActive: Bool
    let onTap: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    func body(content: Content) -> some View {
        HStack(spacing: 5) {
            content
            trailing()
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
        .onTapGesture(perform: onTap)
    }
}

/// 统一的视图标签项:diff / 提交 / 比较 / 搜索,按 ViewTab 类型给图标与标题。
private struct ViewTabItem: View {
    @EnvironmentObject var vm: RepoViewModel
    let tab: ViewTab
    let isActive: Bool
    @State private var hovering = false

    private var icon: String {
        switch tab {
        case .diff: return "plus.forwardslash.minus"
        case .commit: return "circle.dotted"
        case .compare: return "arrow.left.arrow.right"
        case .search: return vm.globalSearchReplace ? "arrow.triangle.2.circlepath" : "magnifyingglass"
        case .rebase: return "line.3.horizontal"
        }
    }
    private var title: String {
        switch tab {
        case .diff(let p, _): return vm.displayName(for: p)
        case .commit(let c): return "\(c.shortHash) · \(c.subject)"
        case .compare(let b, let t): return "\(shortRef(b)) ↔ \(shortRef(t))"
        case .search:
            let kw = vm.globalSearchQuery.trimmingCharacters(in: .whitespaces)
            let label = vm.globalSearchReplace ? tr("替换", "Replace") : tr("查找", "Find")
            return kw.isEmpty ? label : "\(label): \(kw)"
        case .rebase:
            return vm.rebaseSteps.isEmpty
                ? tr("整理提交", "Reorganize")
                : tr("整理提交（\(vm.rebaseSteps.count)）", "Reorganize (\(vm.rebaseSteps.count))")
        }
    }
    private func shortRef(_ r: String) -> String {
        r.count > 12 && r.allSatisfy(\.isHexDigit) ? String(r.prefix(8)) : r
    }

    /// 前导图标:diff 标签用「文件类型图标 + 小 ∓ 角标」(认得出是哪个文件、又一眼是 diff);
    /// 提交/比较/搜索用各自 SF Symbol。
    @ViewBuilder private var leadingIcon: some View {
        if case .diff(let p, _) = tab {
            FileIconView(fileName: vm.displayName(for: p))
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "plus.forwardslash.minus")
                        .font(.system(size: 6, weight: .black))
                        .foregroundStyle(.white)
                        .padding(1.5)
                        .background(Circle().fill(Color.orange))
                        .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
                        .offset(x: 3, y: 2)
                }
        } else {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(isActive ? Color.accentColor : .secondary)
                .frame(width: 16)
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            leadingIcon
            Text(title)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 180, alignment: .leading)
                .foregroundStyle(isActive ? .primary : .secondary)
            closeButton(hovering: hovering) { vm.closeViewTab(tab) }
        }
        .modifier(TabChrome(isActive: isActive, onTap: { vm.activateViewTab(tab) }) { EmptyView() })
        .onHover { hovering = $0 }
        .help(title)
        .contextMenu {
            Button(tr("关闭", "Close")) { vm.closeViewTab(tab) }
            Button(tr("关闭其他", "Close Others")) { vm.closeOtherTabs(keepingViewTab: tab) }
            if vm.openViewTabs.last != tab {
                Button(tr("关闭右侧", "Close to the Right")) { vm.closeViewTabsToTheRight(of: tab) }
            }
            Divider()
            Button(tr("关闭全部", "Close All")) { vm.closeAllTabs() }
            // diff 标签:可在文件列表中定位对应文件
            if case .diff(let path, _) = tab, !vm.workspaceTree.isEmpty {
                Divider()
                Button(tr("在文件列表中显示", "Reveal in Files")) { vm.revealInFiles(path) }
            }
        }
    }
}

/// 悬停才出现的关闭按钮（diff/提交/搜索标签共用）。
private func closeButton(hovering: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: "xmark")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.secondary)
            .opacity(hovering ? 1 : 0)
    }
    .buttonStyle(.plain)
    .frame(width: 14, height: 14)
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
                .truncationMode(.middle)
                .frame(maxWidth: 160, alignment: .leading)
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
            Button(tr("关闭全部", "Close All")) { vm.closeAllTabs() }
            if !vm.isUntitled(path) {
                Divider()
                if !vm.workspaceTree.isEmpty {
                    Button(tr("在文件列表中显示", "Reveal in Files")) { vm.revealInFiles(path) }
                }
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

/// 文件内容区：图片预览 / blame / 编辑器 + 底部状态栏。标签栏与关闭确认在 DetailView 层。
struct EditorArea: View {
    @EnvironmentObject var vm: RepoViewModel
    let activePath: String
    var showConflictBar = false

    var body: some View {
        VStack(spacing: 0) {
            if FileIcon.isImage(activePath) {
                ImagePreviewView(path: activePath)
            } else if vm.blameViewPath == activePath {
                FileBlameView(path: activePath)
            } else {
                EditorView(path: activePath, showConflictBar: showConflictBar)
            }
            Divider()
            EditorStatusBar()
        }
    }
}
