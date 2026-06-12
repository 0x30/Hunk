import SwiftUI

/// 编辑器顶部的多文件标签栏。
struct EditorTabBar: View {
    @EnvironmentObject var vm: RepoViewModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(vm.openTabs, id: \.self) { path in
                    EditorTabItem(path: path, isActive: path == vm.editorPath)
                }
            }
        }
        .frame(height: 32)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct EditorTabItem: View {
    @EnvironmentObject var vm: RepoViewModel
    let path: String
    let isActive: Bool
    @State private var hovering = false

    private var fileName: String { (path as NSString).lastPathComponent }
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
            Divider()
            Button(tr("在 Finder 中显示", "Reveal in Finder")) { vm.revealInFinder(path) }
            Button(tr("复制路径", "Copy Path")) { vm.copyPath(path) }
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
            if !vm.openTabs.isEmpty {
                EditorTabBar()
                Divider()
            }
            if FileIcon.isImage(activePath) {
                ImagePreviewView(path: activePath)
            } else {
                EditorView(path: activePath, showConflictBar: showConflictBar)
            }
        }
        .confirmationDialog(
            tr("「\((vm.pendingCloseTab as NSString?)?.lastPathComponent ?? "")」有未保存的修改",
               "“\((vm.pendingCloseTab as NSString?)?.lastPathComponent ?? "")” has unsaved changes"),
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
